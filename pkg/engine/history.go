package engine

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"testing"
	"time"
)

// File names of the structured history, next to the cleanup log in the state folder.
const (
	HistoryFile = "history.jsonl"
	SamplesFile = "free.jsonl"
)

// HistorySchema is the version of the lines in both files.
const HistorySchema = 1

const (
	// A sample is taken when the last one is at least sampleEvery old, or when free space moved by sampleDelta or
	// more since then: about 48 a day at most, and a sudden fall or a cleanup is never missed.
	sampleEvery = 30 * time.Minute
	sampleDelta = 256 << 20

	// Reads are bounded: a file is read from its last maxHistoryRead bytes, and a line longer than maxHistoryLine
	// is not a line cmm wrote. A run is cut down to fit before it is written, so cmm never writes one.
	maxHistoryRead = 8 << 20
	maxHistoryLine = 2 << 20
	// lastSampleRead is how much of the end of the samples file is looked at to find the latest sample.
	lastSampleRead = 64 << 10
)

// utcSeconds is the one form of time in these files: UTC, whole seconds ("2026-10-15T14:09:07Z"), which every
// JSON reader parses without special options.
func utcSeconds(t time.Time) time.Time { return t.UTC().Truncate(time.Second) }

// encodeLine renders a value as one line of JSON without a newline. Paths are data, not HTML, so & < > stay as
// they are and the files stay easy to grep.
func encodeLine(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// RunItem is one item of a run that was deleted (or run as a command) or that failed. Skipped items changed
// nothing and are only counted.
type RunItem struct {
	Rule       string `json:"rule"`
	Group      string `json:"group"`
	Path       string `json:"path"`
	Status     Status `json:"status"`
	Bytes      int64  `json:"bytes"`
	FreedBytes int64  `json:"freed_bytes"`
	// FreesInside is where the space went when it was not the volume ("Docker's disk image"); empty otherwise.
	FreesInside string `json:"frees_inside,omitempty"`
	Reason      string `json:"reason,omitempty"`
}

// Run is the record of one real apply that deleted or failed something: what happened, in numbers a person can
// still read a year later. It holds paths and sizes the plan already showed and never file contents.
type Run struct {
	SchemaVersion int       `json:"schema_version"`
	StartedAt     time.Time `json:"started_at"`
	FinishedAt    time.Time `json:"finished_at"`
	Deleted       int       `json:"deleted"`
	Skipped       int       `json:"skipped"`
	Failed        int       `json:"failed"`
	FreedBytes    int64     `json:"freed_bytes"` // what the volume got back
	// FreedInsideBytes is what was freed inside another program's storage (Docker's disk image) and so is not in FreedBytes.
	FreedInsideBytes int64     `json:"freed_inside_bytes,omitempty"`
	FreeBefore       int64     `json:"free_before"`
	FreeAfter        int64     `json:"free_after"`
	CapacityBytes    int64     `json:"capacity_bytes,omitempty"` // how big the volume was; left out when unknown
	Stopped          bool      `json:"stopped"`                  // the run was ended early (Stop, or the program was told to quit)
	Items            []RunItem `json:"items"`
	// ItemsOmitted is how many items did not fit in a line of the file and are only counted in the totals.
	ItemsOmitted int `json:"items_omitted,omitempty"`
}

// Sample is the free space of the volume at one moment.
type Sample struct {
	T             time.Time `json:"t"`
	FreeBytes     int64     `json:"free_bytes"`
	CapacityBytes int64     `json:"capacity_bytes,omitempty"`
}

// RunLog keeps the record of real runs. The engine calls it once at the end of a real apply that deleted or
// failed something (never for a dry run). Like the Journal it may fail: the engine turns that into a warning.
type RunLog interface {
	Append(Run) error
}

// FileHistory keeps the runs and the free-space samples in two append-only files under Dir. Nothing that decides
// what may be deleted ever reads them: they only feed what a person is shown.
type FileHistory struct {
	Dir string
	Now func() time.Time
}

// NewFileHistory returns a history that writes to StateDir(home). A nil clock means time.Now.
func NewFileHistory(home string, now func() time.Time) *FileHistory {
	if now == nil {
		now = time.Now
	}
	return &FileHistory{Dir: StateDir(home), Now: now}
}

// HistoryPath is the file with one line per run.
func (h *FileHistory) HistoryPath() string { return filepath.Join(h.Dir, HistoryFile) }

// SamplesPath is the file with one line per free-space sample.
func (h *FileHistory) SamplesPath() string { return filepath.Join(h.Dir, SamplesFile) }

// appendLine adds one line to a private file in the state folder, in a single write, never through a symlink.
func (h *FileHistory) appendLine(path string, line []byte) error {
	if testing.Testing() {
		mustBeTempPath(h.Dir)
	}
	if err := os.MkdirAll(h.Dir, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	_, err = f.Write(append(line, '\n'))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// Append adds one run. A run too big for one line keeps its totals and loses the tail of its item list (and
// says how many items that was), so a line that no reader would accept is never written.
func (h *FileHistory) Append(run Run) error {
	run.SchemaVersion = HistorySchema
	run.StartedAt, run.FinishedAt = utcSeconds(run.StartedAt), utcSeconds(run.FinishedAt) // one simple form for every reader
	if run.Items == nil {
		run.Items = []RunItem{}
	}
	line, err := encodeLine(run)
	if err != nil {
		return err
	}
	for len(line) > maxHistoryLine && len(run.Items) > 0 {
		keep := len(run.Items) / 2
		run.ItemsOmitted += len(run.Items) - keep
		run.Items = run.Items[:keep]
		if line, err = encodeLine(run); err != nil {
			return err
		}
	}
	return h.appendLine(h.HistoryPath(), line)
}

// readTail returns the last max bytes of a regular file (all of it when it is smaller), whether the start was
// cut off, and nothing at all when the file does not exist. Anything that is not a plain file is refused: a link
// or a pipe in its place is not cmm's history.
func readTail(path string, max int64) (data []byte, cut bool, err error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, false, err
	}
	if !fi.Mode().IsRegular() {
		return nil, false, fmt.Errorf("%s is not a regular file", path)
	}
	if fi.Size() > max {
		if _, err := f.Seek(fi.Size()-max, io.SeekStart); err != nil {
			return nil, false, err
		}
		cut = true
	}
	data, err = io.ReadAll(io.LimitReader(f, max))
	return data, cut, err
}

// eachLine calls fn for every complete line of data (a line longer than maxLine is reported as too long instead).
// When the start of data was cut off from a longer file, the first, partial line is dropped without comment.
func eachLine(data []byte, cut bool, maxLine int, fn func(line []byte, tooLong bool)) {
	if cut {
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			data = data[i+1:]
		} else {
			return
		}
	}
	for len(data) > 0 {
		line := data
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			line, data = data[:i], data[i+1:]
		} else {
			data = nil
		}
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		fn(line, len(line) > maxLine)
	}
}

// valid says whether a run read from the file is one cmm could have written.
func (r Run) valid() bool {
	return r.SchemaVersion == HistorySchema && !r.StartedAt.IsZero() && !r.FinishedAt.IsZero() &&
		r.Deleted >= 0 && r.Skipped >= 0 && r.Failed >= 0 &&
		r.FreedBytes >= 0 && r.FreedInsideBytes >= 0 && r.FreeBefore >= 0 && r.FreeAfter >= 0 && r.CapacityBytes >= 0 && r.ItemsOmitted >= 0
}

// Runs returns the newest limit runs (all of them when limit is 0), newest first, and how many lines could not
// be read. A line that cannot be read is skipped, never fatal; a file that is not there is an empty history.
func (h *FileHistory) Runs(limit int) ([]Run, int, error) {
	data, cut, err := readTail(h.HistoryPath(), maxHistoryRead)
	if err != nil {
		return nil, 0, err
	}
	var runs []Run
	bad := 0
	eachLine(data, cut, maxHistoryLine, func(line []byte, tooLong bool) {
		var r Run
		if tooLong || json.Unmarshal(line, &r) != nil || !r.valid() {
			bad++
			return
		}
		runs = append(runs, r)
	})
	// newest first
	for i, j := 0, len(runs)-1; i < j; i, j = i+1, j-1 {
		runs[i], runs[j] = runs[j], runs[i]
	}
	if limit > 0 && len(runs) > limit {
		runs = runs[:limit]
	}
	return runs, bad, nil
}

func (s Sample) valid() bool { return !s.T.IsZero() && s.FreeBytes >= 0 && s.CapacityBytes >= 0 }

// readSamples reads the samples on file in the order they were written, and counts the lines it could not read.
func (h *FileHistory) readSamples(max int64) ([]Sample, int, error) {
	data, cut, err := readTail(h.SamplesPath(), max)
	if err != nil {
		return nil, 0, err
	}
	var out []Sample
	bad := 0
	eachLine(data, cut, 4096, func(line []byte, tooLong bool) {
		var s Sample
		if tooLong || json.Unmarshal(line, &s) != nil || !s.valid() {
			bad++
			return
		}
		out = append(out, s)
	})
	return out, bad, nil
}

// Samples returns the samples taken at or after since, oldest first, and how many lines could not be read.
func (h *FileHistory) Samples(since time.Time) ([]Sample, int, error) {
	all, bad, err := h.readSamples(maxHistoryRead)
	if err != nil {
		return nil, 0, err
	}
	out := all[:0:0]
	for _, s := range all {
		if !s.T.Before(since) {
			out = append(out, s)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].T.Before(out[j].T) })
	return out, bad, nil
}

// Sample records the free space now if a sample is due (see sampleEvery and sampleDelta) and says whether it did.
// Due is measured from the last sample written, so a clock that jumps back cannot make every call count.
func (h *FileHistory) Sample(free, capacity int64) (bool, error) {
	now := h.Now()
	last, _, err := h.readSamples(lastSampleRead)
	if err != nil {
		return false, err
	}
	if n := len(last); n > 0 {
		prev := last[n-1]
		delta := free - prev.FreeBytes
		if delta < 0 {
			delta = -delta
		}
		if now.Sub(prev.T) < sampleEvery && delta < sampleDelta {
			return false, nil
		}
	}
	s := Sample{T: utcSeconds(now), FreeBytes: free, CapacityBytes: capacity}
	line, err := encodeLine(s)
	if err != nil {
		return false, err
	}
	if err := h.appendLine(h.SamplesPath(), line); err != nil {
		return false, err
	}
	return true, nil
}

// HistoryReport is what `cmm history --json` prints (schema 1, see testdata/history_v1.golden.json): the newest
// runs, newest first, and the free-space timeline, oldest first.
type HistoryReport struct {
	SchemaVersion int       `json:"schema_version"`
	GeneratedAt   time.Time `json:"generated_at"`
	Host          Host      `json:"host"`
	Runs          []Run     `json:"runs"`
	Samples       []Sample  `json:"samples"`
	// UnreadableLines counts lines of either file that were skipped because they could not be read.
	UnreadableLines int `json:"unreadable_lines"`
}

// Report reads the newest limit runs (0 means all) and the timeline of the last days days (0 means all). The
// timeline holds the samples taken on their own and the two ends of every run in that period (free space before
// and after), sorted by time; the same moment is listed once.
func (h *FileHistory) Report(host Host, limit, days int) (*HistoryReport, error) {
	now := h.Now()
	all, badRuns, err := h.Runs(0)
	if err != nil {
		return nil, err
	}
	var since time.Time
	if days > 0 {
		since = now.AddDate(0, 0, -days)
	}
	samples, badSamples, err := h.Samples(since)
	if err != nil {
		return nil, err
	}
	for _, r := range all {
		if !r.StartedAt.Before(since) {
			samples = append(samples, Sample{T: utcSeconds(r.StartedAt), FreeBytes: r.FreeBefore, CapacityBytes: r.CapacityBytes})
		}
		if !r.FinishedAt.Before(since) {
			samples = append(samples, Sample{T: utcSeconds(r.FinishedAt), FreeBytes: r.FreeAfter, CapacityBytes: r.CapacityBytes})
		}
	}
	sort.SliceStable(samples, func(i, j int) bool { return samples[i].T.Before(samples[j].T) })
	timeline := make([]Sample, 0, len(samples))
	for _, s := range samples {
		if n := len(timeline); n > 0 && timeline[n-1].T.Equal(s.T) && timeline[n-1].FreeBytes == s.FreeBytes {
			continue
		}
		timeline = append(timeline, s)
	}
	runs := all
	if limit > 0 && len(runs) > limit {
		runs = runs[:limit]
	}
	if runs == nil {
		runs = []Run{}
	}
	return &HistoryReport{
		SchemaVersion: HistorySchema, GeneratedAt: utcSeconds(now), Host: host,
		Runs: runs, Samples: timeline, UnreadableLines: badRuns + badSamples,
	}, nil
}

// JSON renders the report like a plan: two-space indented, one trailing newline, empty lists as [] never null.
func (r *HistoryReport) JSON() ([]byte, error) {
	out := *r
	if out.Runs == nil {
		out.Runs = []Run{}
	}
	if out.Samples == nil {
		out.Samples = []Sample{}
	}
	for i := range out.Runs {
		if out.Runs[i].Items == nil {
			out.Runs[i].Items = []RunItem{}
		}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(&out); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
