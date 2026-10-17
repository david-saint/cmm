package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/sys/systest"
)

// ---- the structured history of runs and free-space samples ----

var t0 = time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)

func newHistory(t *testing.T) (*FileHistory, *systest.Sandbox) {
	t.Helper()
	sb := systest.NewSandbox(t)
	h := NewFileHistory(sb.Env.Home, sb.Env.Clock)
	return h, sb
}

// at makes the history's clock say that it is t0 plus d.
func at(h *FileHistory, d time.Duration) { h.Now = func() time.Time { return t0.Add(d) } }

func sampleRun(freed int64) Run {
	return Run{
		StartedAt: t0, FinishedAt: t0.Add(42 * time.Second),
		Deleted: 2, Skipped: 1, Failed: 1, FreedBytes: freed,
		FreeBefore: 19_800_000_000, FreeAfter: 19_800_000_000 + freed, CapacityBytes: 245_107_195_904,
		Items: []RunItem{
			{Rule: "go-build", Group: "Go build cache", Path: "/Users/x/Library/Caches/go-build", Status: StatusDeleted, Bytes: freed, FreedBytes: freed},
			{Rule: "uv-cache", Group: "uv cache", Path: "/Users/x/.cache/uv", Status: StatusFailed, Bytes: 5, Reason: "permission denied"},
		},
	}
}

func TestStateDir_HoldsTheHistoryFilesToo(t *testing.T) {
	if HistoryFile != "history.jsonl" || SamplesFile != "free.jsonl" {
		t.Errorf("the file names are part of the contract with readers: %q %q", HistoryFile, SamplesFile)
	}
}

func TestFileHistory_AppendWritesOneJSONLinePerRunAndKeepsTheFilesPrivate(t *testing.T) {
	h, _ := newHistory(t)
	for _, freed := range []int64{100, 200} {
		if err := h.Append(sampleRun(freed)); err != nil {
			t.Fatal(err)
		}
	}
	lines := strings.Split(strings.TrimSuffix(readText(t, h.HistoryPath()), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("one line per run, got %d:\n%v", len(lines), lines)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &doc); err != nil {
		t.Fatalf("a line is a JSON object: %v\n%s", err, lines[0])
	}
	if doc["schema_version"] != float64(1) {
		t.Errorf("every line says which schema it is: %v", doc["schema_version"])
	}
	for _, key := range []string{"started_at", "finished_at", "deleted", "skipped", "failed", "freed_bytes", "free_before", "free_after", "capacity_bytes", "stopped", "items"} {
		if _, ok := doc[key]; !ok {
			t.Errorf("a run line should carry %q: %s", key, lines[0])
		}
	}
	if fi, err := os.Stat(h.HistoryPath()); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("the history is private to the user: %v %v", fi, err)
	}
	if fi, err := os.Stat(h.Dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("so is the folder: %v %v", fi, err)
	}
}

func TestFileHistory_TimesAreWrittenAsUTCWholeSeconds(t *testing.T) {
	h, _ := newHistory(t)
	zone := time.FixedZone("CEST", 2*3600)
	run := sampleRun(1)
	run.StartedAt = time.Date(2026, 10, 15, 16, 9, 7, 741748000, zone)
	run.FinishedAt = time.Date(2026, 10, 15, 16, 9, 8, 778279000, zone)
	if err := h.Append(run); err != nil {
		t.Fatal(err)
	}
	line := readText(t, h.HistoryPath())
	if !strings.Contains(line, `"started_at":"2026-10-15T14:09:07Z"`) || !strings.Contains(line, `"finished_at":"2026-10-15T14:09:08Z"`) {
		t.Errorf("one simple form of time for every reader (UTC, no fraction):\n%s", line)
	}
	rep, _ := h.Report(hostNow(), 5, 0)
	if !strings.Contains(string(mustJSON(t, rep)), `"generated_at": "2026-10-14T12:00:00Z"`) {
		t.Errorf("the report is stamped the same way:\n%s", mustJSON(t, rep))
	}
}

func mustJSON(t *testing.T, r *HistoryReport) []byte {
	t.Helper()
	b, err := r.JSON()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestFileHistory_APathWithOddCharactersStaysOnOneLine(t *testing.T) {
	h, _ := newHistory(t)
	run := sampleRun(1)
	run.Items[0].Path = "/Users/x/a\nb\u2028c"
	if err := h.Append(run); err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(readText(t, h.HistoryPath()), "\n"); got != 1 {
		t.Errorf("one run is one line, whatever the names contain: %d newlines", got)
	}
	runs, bad, err := h.Runs(10)
	if err != nil || bad != 0 || len(runs) != 1 || runs[0].Items[0].Path != run.Items[0].Path {
		t.Errorf("the path comes back exactly: %v bad=%d err=%v", runs, bad, err)
	}
}

func TestFileHistory_RunsComeBackNewestFirstWithEveryNumber(t *testing.T) {
	h, _ := newHistory(t)
	for _, freed := range []int64{100, 200, 300} {
		if err := h.Append(sampleRun(freed)); err != nil {
			t.Fatal(err)
		}
	}
	runs, bad, err := h.Runs(2)
	if err != nil || bad != 0 {
		t.Fatalf("Runs: %v bad=%d", err, bad)
	}
	if len(runs) != 2 || runs[0].FreedBytes != 300 || runs[1].FreedBytes != 200 {
		t.Fatalf("the newest two, newest first: %+v", runs)
	}
	got := runs[0]
	want := sampleRun(300)
	want.SchemaVersion = 1
	if got.SchemaVersion != 1 || !got.StartedAt.Equal(want.StartedAt) || !got.FinishedAt.Equal(want.FinishedAt) ||
		got.Deleted != 2 || got.Skipped != 1 || got.Failed != 1 || got.FreeBefore != want.FreeBefore || got.FreeAfter != want.FreeAfter ||
		got.CapacityBytes != want.CapacityBytes || len(got.Items) != 2 || got.Items[1].Reason != "permission denied" || got.Items[1].Status != StatusFailed {
		t.Errorf("a run should come back as it went in:\n got %+v\nwant %+v", got, want)
	}
	if all, _, _ := h.Runs(0); len(all) != 3 {
		t.Errorf("a limit of 0 means no limit: %d", len(all))
	}
}

func TestFileHistory_ARunTooBigForALineKeepsItsTotalsAndSaysWhatItDropped(t *testing.T) {
	h, _ := newHistory(t)
	run := sampleRun(1234)
	run.Items = nil
	long := strings.Repeat("p", 3000)
	for i := 0; i < 2000; i++ { // about 6 MB of paths: more than one line may hold
		run.Items = append(run.Items, RunItem{Rule: "r", Group: "g", Path: "/x/" + long + string(rune('a'+i%26)), Status: StatusDeleted, Bytes: 1, FreedBytes: 1})
	}
	if err := h.Append(run); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(h.HistoryPath()); err != nil || fi.Size() > maxHistoryLine+1 {
		t.Errorf("no line longer than a reader accepts is written: %v %v", fi, err)
	}
	runs, bad, err := h.Runs(1)
	if err != nil || bad != 0 || len(runs) != 1 {
		t.Fatalf("the run must still be readable: %v bad=%d err=%v", runs, bad, err)
	}
	got := runs[0]
	if got.Deleted != 2 || got.FreedBytes != 1234 || got.FreeBefore != run.FreeBefore {
		t.Errorf("the totals are kept: %+v", got)
	}
	if got.ItemsOmitted == 0 || len(got.Items)+got.ItemsOmitted != 2000 || got.Items[0].Path != run.Items[0].Path {
		t.Errorf("the head of the list is kept and the rest is counted: kept %d, omitted %d", len(got.Items), got.ItemsOmitted)
	}
}

func TestFileHistory_NothingYetIsEmptyNotAnError(t *testing.T) {
	h, _ := newHistory(t)
	runs, bad, err := h.Runs(10)
	if err != nil || bad != 0 || len(runs) != 0 {
		t.Errorf("no history file: %v %d %v", runs, bad, err)
	}
	samples, bad, err := h.Samples(t0.Add(-24 * time.Hour))
	if err != nil || bad != 0 || len(samples) != 0 {
		t.Errorf("no samples file: %v %d %v", samples, bad, err)
	}
}

func TestFileHistory_UnreadableLinesAreSkippedAndCounted(t *testing.T) {
	h, _ := newHistory(t)
	if err := h.Append(sampleRun(100)); err != nil {
		t.Fatal(err)
	}
	good := readText(t, h.HistoryPath())
	elsewhere := sampleRun(5)
	elsewhere.SchemaVersion = 2
	other, _ := json.Marshal(elsewhere) // complete and valid in every way but the schema it claims
	negativeInside := sampleRun(5)
	negativeInside.FreedInsideBytes = -5
	negative, _ := json.Marshal(struct {
		SchemaVersion int `json:"schema_version"`
		Run
	}{1, negativeInside}) // complete and valid in every way but one figure
	junk := strings.Join([]string{
		"this is not json",
		`{"schema_version":1,"deleted":"many"}`, // right schema, wrong shape
		string(other),                           // another schema: not ours to read
		"",                                      // a blank line is nothing, not damage
		`{"schema_version":1,"freed_bytes":-5,"started_at":"2026-10-14T12:00:00Z","finished_at":"2026-10-14T12:00:01Z"}`, // negative sizes are not honest
		strings.Repeat("x", maxHistoryLine+1), // longer than any line cmm writes
		string(negative),                      // a negative amount freed inside another program is not honest
	}, "\n") + "\n"
	if err := os.WriteFile(h.HistoryPath(), []byte(junk+good), 0o600); err != nil {
		t.Fatal(err)
	}
	runs, bad, err := h.Runs(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 || runs[0].FreedBytes != 100 {
		t.Errorf("only the good line is a run: %+v", runs)
	}
	if bad != 6 {
		t.Errorf("six damaged lines should be counted (the blank one is not), got %d", bad)
	}
}

func TestFileHistory_NeverWritesThroughASymlink(t *testing.T) {
	h, sb := newHistory(t)
	victim := sb.Tmp("victim.txt")
	sb.WriteFile(t, victim, 10, 0)
	if err := os.MkdirAll(h.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, h.HistoryPath()); err != nil {
		t.Fatal(err)
	}
	before := readText(t, victim)
	if err := h.Append(sampleRun(1)); err == nil {
		t.Error("a link in the place of the history must be refused")
	}
	if readText(t, victim) != before {
		t.Error("nothing may be written through the link")
	}
	if err := os.Remove(h.HistoryPath()); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, h.SamplesPath()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Sample(1000, 5000); err == nil {
		t.Error("the same goes for the samples file")
	}
	if readText(t, victim) != before {
		t.Error("nothing may be written through the link, samples either")
	}
}

func TestFileHistory_NeverReadsThroughASymlinkEither(t *testing.T) {
	h, sb := newHistory(t)
	other := sb.Tmp("elsewhere")
	other2 := NewFileHistory(other, sb.Env.Clock)
	if err := other2.Append(sampleRun(1)); err != nil {
		t.Fatal(err)
	}
	at(other2, 0)
	if ok, err := other2.Sample(1000, 0); err != nil || !ok {
		t.Fatal(ok, err)
	}
	if err := os.MkdirAll(h.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other2.HistoryPath(), h.HistoryPath()); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other2.SamplesPath(), h.SamplesPath()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.Runs(5); err == nil {
		t.Error("a link in the place of the history is not cmm's history, even if what it points to is perfect")
	}
	if _, _, err := h.Samples(t0.Add(-time.Hour)); err == nil {
		t.Error("nor is a link in the place of the samples")
	}
}

func TestFileHistory_APipeInThePlaceOfTheHistoryIsRefusedNotWaitedFor(t *testing.T) {
	h, _ := newHistory(t)
	if err := os.MkdirAll(h.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(h.HistoryPath(), 0o600); err != nil {
		t.Skipf("cannot make a pipe here: %v", err)
	}
	done := make(chan error, 1)
	go func() { _, _, err := h.Runs(5); done <- err }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Errorf("a pipe is not a history: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("reading must never wait on a pipe")
	}
}

func TestFileHistory_OnlyTheTailOfAHugeFileIsRead(t *testing.T) {
	h, _ := newHistory(t)
	if err := h.Append(sampleRun(7)); err != nil {
		t.Fatal(err)
	}
	line := readText(t, h.HistoryPath())
	var b strings.Builder
	for b.Len() < maxHistoryRead+len(line)*3 {
		b.WriteString(line)
	}
	if err := os.WriteFile(h.HistoryPath(), []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	runs, bad, err := h.Runs(0)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) == 0 || len(runs)*len(line) > maxHistoryRead+len(line) {
		t.Errorf("reading is bounded: %d runs of %d bytes read from a %d-byte file", len(runs), len(line), b.Len())
	}
	if bad != 0 {
		t.Errorf("the cut at the start of the tail is not damage: %d", bad)
	}
}

// ---- samples ----

func TestSample_TheFirstOneIsAlwaysTaken(t *testing.T) {
	h, _ := newHistory(t)
	at(h, 0)
	ok, err := h.Sample(19_600_000_000, 245_107_195_904)
	if err != nil || !ok {
		t.Fatalf("the first sample is due: %v %v", ok, err)
	}
	got, bad, err := h.Samples(t0.Add(-time.Hour))
	if err != nil || bad != 0 || len(got) != 1 || got[0].FreeBytes != 19_600_000_000 || got[0].CapacityBytes != 245_107_195_904 || !got[0].T.Equal(t0) {
		t.Errorf("samples: %+v bad=%d err=%v", got, bad, err)
	}
	if fi, err := os.Stat(h.SamplesPath()); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("private: %v %v", fi, err)
	}
}

func TestSample_OnlyWhenDue(t *testing.T) {
	const gb = 1_000_000_000
	cases := []struct {
		name  string
		after time.Duration
		free  int64
		want  bool
	}{
		{"a minute later, nothing moved", time.Minute, 20 * gb, false},
		{"29 minutes later, a little moved", 29 * time.Minute, 20*gb - 100<<20, false},
		{"29 minutes later, 256 MiB less", 29 * time.Minute, 20*gb - 256<<20, true},
		{"29 minutes later, 256 MiB more", 29 * time.Minute, 20*gb + 256<<20, true},
		{"29 minutes later, just under 256 MiB", 29 * time.Minute, 20*gb - 256<<20 + 1, false},
		{"exactly 30 minutes later", 30 * time.Minute, 20 * gb, true},
		{"a day later", 24 * time.Hour, 20 * gb, true},
		{"the clock went back, nothing moved", -time.Hour, 20 * gb, false},
		{"the clock went back, a lot moved", -time.Hour, 20*gb - 1*gb, true},
	}
	for _, c := range cases {
		h, _ := newHistory(t)
		at(h, 0)
		if ok, err := h.Sample(20*gb, 245*gb); err != nil || !ok {
			t.Fatalf("%s: first sample: %v %v", c.name, ok, err)
		}
		at(h, c.after)
		ok, err := h.Sample(c.free, 245*gb)
		if err != nil || ok != c.want {
			t.Errorf("%s: recorded=%v err=%v, want %v", c.name, ok, err, c.want)
		}
		samples, _, _ := h.Samples(t0.Add(-48 * time.Hour))
		wantN := 1
		if c.want {
			wantN = 2
		}
		if len(samples) != wantN {
			t.Errorf("%s: %d samples on file, want %d", c.name, len(samples), wantN)
		}
	}
}

func TestSample_IsComparedWithTheLatestSampleNotTheFirst(t *testing.T) {
	h, _ := newHistory(t)
	at(h, 0)
	h.Sample(20_000_000_000, 0)
	at(h, 40*time.Minute)
	h.Sample(19_000_000_000, 0)
	at(h, 50*time.Minute) // ten minutes after the last, equal to it: not due, though far from the first
	if ok, _ := h.Sample(19_000_000_000, 0); ok {
		t.Error("due is measured from the last sample on file")
	}
}

func TestSamples_AreSortedOldestFirstFilteredBySinceAndLeaveOutUnknownCapacity(t *testing.T) {
	h, _ := newHistory(t)
	for i, d := range []time.Duration{0, 2 * time.Hour, 4 * time.Hour, 6 * time.Hour} {
		at(h, d)
		if ok, err := h.Sample(int64(10+i)*1_000_000_000, 0); err != nil || !ok {
			t.Fatal(ok, err)
		}
	}
	if strings.Contains(readText(t, h.SamplesPath()), "capacity_bytes") {
		t.Error("an unknown capacity is left out, not written as 0")
	}
	got, _, err := h.Samples(t0.Add(3 * time.Hour))
	if err != nil || len(got) != 2 || got[0].FreeBytes != 12_000_000_000 || got[1].FreeBytes != 13_000_000_000 {
		t.Errorf("only samples since then, oldest first: %+v %v", got, err)
	}

	// a file written out of order (a clock that jumped) still reads back sorted
	lines := strings.Split(strings.TrimSpace(readText(t, h.SamplesPath())), "\n")
	reversed := []string{lines[3], lines[0], lines[2], lines[1]}
	if err := os.WriteFile(h.SamplesPath(), []byte(strings.Join(reversed, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	all, _, _ := h.Samples(t0.Add(-time.Hour))
	for i := 1; i < len(all); i++ {
		if all[i].T.Before(all[i-1].T) {
			t.Errorf("samples must come back sorted by time: %+v", all)
		}
	}
}

func TestSamples_UnreadableLinesAreSkippedAndCounted(t *testing.T) {
	h, _ := newHistory(t)
	at(h, 0)
	h.Sample(20_000_000_000, 0)
	good := readText(t, h.SamplesPath())
	junk := "oops\n" + `{"t":"yesterday","free_bytes":1}` + "\n" + `{"t":"2026-10-14T12:00:00Z","free_bytes":-1}` + "\n" + `{"free_bytes":3}` + "\n"
	if err := os.WriteFile(h.SamplesPath(), []byte(junk+good), 0o600); err != nil {
		t.Fatal(err)
	}
	got, bad, err := h.Samples(t0.Add(-time.Hour))
	if err != nil || len(got) != 1 || bad != 4 {
		t.Errorf("one good sample, four damaged lines: %+v bad=%d err=%v", got, bad, err)
	}
	// and a damaged tail does not stop new samples from being taken
	at(h, 2*time.Hour)
	if ok, err := h.Sample(20_000_000_000, 0); err != nil || !ok {
		t.Errorf("a sample is still taken: %v %v", ok, err)
	}
}

func TestHistoryDirectory_IsTheSameStateFolderAsTheJournal(t *testing.T) {
	sb := systest.NewSandbox(t)
	h := NewFileHistory(sb.Env.Home, nil)
	if h.Dir != StateDir(sb.Env.Home) || filepath.Base(h.HistoryPath()) != "history.jsonl" || filepath.Dir(h.SamplesPath()) != h.Dir {
		t.Errorf("history belongs next to the cleanup log: %q %q %q", h.Dir, h.HistoryPath(), h.SamplesPath())
	}
	if h.Now == nil {
		t.Error("a nil clock means time.Now")
	}
}

func TestRun_PlannedIsWrittenOnlyWhenKnown(t *testing.T) {
	without, _ := json.Marshal(Run{SchemaVersion: 1, Items: []RunItem{}})
	if strings.Contains(string(without), "planned") {
		t.Errorf("a run that does not know how many items it planned leaves the key out: %s", without)
	}
	with, _ := json.Marshal(Run{SchemaVersion: 1, Planned: 9, Items: []RunItem{}})
	if !strings.Contains(string(with), `"planned":9`) {
		t.Errorf("a known count is written: %s", with)
	}
	var old Run
	if err := json.Unmarshal([]byte(`{"schema_version":1,"deleted":2,"stopped":true,"items":[]}`), &old); err != nil || old.Planned != 0 {
		t.Errorf("a line written before the field existed reads back as unknown (0): %+v %v", old, err)
	}
}
