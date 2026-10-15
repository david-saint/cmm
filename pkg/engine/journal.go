package engine

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/david-saint/cmm/pkg/rules"
)

// File names inside the state folder.
const (
	LogFile   = "cleanup.log"
	StampFile = "last-run"
)

// StateDir is where cmm keeps its cleanup log and last-run stamp. It is cmm's own folder: the files of the
// dev-cleanup script (~/.local/state/dev-cleanup) are never read or written here.
func StateDir(home string) string { return filepath.Join(home, ".local", "state", "cmm") }

// Journal is the audit trail of a real apply. The engine calls it after each item that was deleted or failed
// (never for a dry run) and once at the end of a run that cleaned something. A journal that cannot write must
// say so by returning an error; the engine turns that into a warning and carries on, so a full disk can never
// stop a cleanup or hide its result.
type Journal interface {
	Record(Result) error
	Stamp() error
}

// FileJournal keeps the trail in two small files under Dir: an append-only log with one line per item
// ("2026-10-14 21:04:18 deleted /path") and the epoch seconds of the last run that cleaned something.
type FileJournal struct {
	Dir string
	Now func() time.Time
}

// NewFileJournal returns a journal that writes to StateDir(home). A nil clock means time.Now.
func NewFileJournal(home string, now func() time.Time) *FileJournal {
	if now == nil {
		now = time.Now
	}
	return &FileJournal{Dir: StateDir(home), Now: now}
}

// LogPath is the cleanup log.
func (j *FileJournal) LogPath() string { return filepath.Join(j.Dir, LogFile) }

func (j *FileJournal) stampPath() string { return filepath.Join(j.Dir, StampFile) }

// ensureDir creates the state folder, private to the user. While a test binary runs, a folder outside a
// temporary directory is a bug in the test and panics before anything is written (like the delete safety net).
func (j *FileJournal) ensureDir() error {
	if testing.Testing() {
		mustBeTempPath(j.Dir)
	}
	return os.MkdirAll(j.Dir, 0o700)
}

// Record appends one line for an item that was deleted ("deleted <path>"), run as a command ("ran <rule>
// <path>") or failed ("FAILED <path>: <reason>"). Skipped items and dry runs changed nothing and leave no line.
// The log is never written through a symlink.
func (j *FileJournal) Record(r Result) error {
	var what string
	switch r.Status {
	case StatusDeleted:
		if r.Item.Action == rules.ActionCommand {
			what = "ran " + logText(r.Item.Rule) + " " + logText(r.Item.Path)
		} else {
			what = "deleted " + logText(r.Item.Path)
		}
	case StatusFailed:
		what = "FAILED " + logText(r.Item.Path) + ": " + logText(r.Reason)
	default:
		return nil
	}
	if err := j.ensureDir(); err != nil {
		return err
	}
	f, err := os.OpenFile(j.LogPath(), os.O_WRONLY|os.O_APPEND|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(f, "%s %s\n", j.Now().Format("2006-01-02 15:04:05"), what)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// Stamp records the time of this run as epoch seconds. The file is replaced atomically (a link in its place
// is replaced, never followed), so readers never see half a number.
func (j *FileJournal) Stamp() error {
	if err := j.ensureDir(); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(j.Dir, StampFile+".")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(tmp, "%d\n", j.Now().Unix())
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), j.stampPath())
	}
	if err != nil {
		_ = os.Remove(tmp.Name()) // our own temporary file in cmm's state folder, not user data
	}
	return err
}

// LastRun reads the stamp of the last run that cleaned something. It answers only for a stamp that is plain
// epoch seconds; a missing, empty, negative or garbled file is "no answer", never an error.
func LastRun(home string) (time.Time, bool) {
	f, err := os.Open(filepath.Join(StateDir(home), StampFile))
	if err != nil {
		return time.Time{}, false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 64))
	if err != nil {
		return time.Time{}, false
	}
	s := strings.TrimSpace(string(b))
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return time.Time{}, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		return time.Time{}, false
	}
	return time.Unix(n, 0), true
}

// logText keeps one record on one line: a name or reason with a control character, a line separator or bytes
// that are not UTF-8 is quoted, so it cannot start a line of its own.
func logText(s string) string {
	// 0x2028 and 0x2029 are the Unicode line and paragraph separators: not control characters, but many
	// readers (editors, log viewers) break the line there.
	odd := func(r rune) bool { return unicode.IsControl(r) || r == 0x2028 || r == 0x2029 }
	if !utf8.ValidString(s) || strings.IndexFunc(s, odd) >= 0 {
		return strconv.Quote(s)
	}
	return s
}
