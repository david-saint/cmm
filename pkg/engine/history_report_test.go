package engine

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---- the report that `cmm history --json` prints ----

func hostNow() Host {
	return Host{Volume: "/System/Volumes/Data", FreeBytes: 19_600_000_000, CapacityBytes: 245_107_195_904}
}

func TestReport_RunsNewestFirstAndLimited(t *testing.T) {
	h, _ := newHistory(t)
	for _, freed := range []int64{100, 200, 300} {
		if err := h.Append(sampleRun(freed)); err != nil {
			t.Fatal(err)
		}
	}
	at(h, time.Hour)
	rep, err := h.Report(hostNow(), 2, 90)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Runs) != 2 || rep.Runs[0].FreedBytes != 300 || rep.Runs[1].FreedBytes != 200 {
		t.Errorf("the newest two, newest first: %+v", rep.Runs)
	}
	if rep.SchemaVersion != 1 || !rep.GeneratedAt.Equal(t0.Add(time.Hour)) || rep.Host != hostNow() {
		t.Errorf("header: %+v", rep)
	}
	if all, _ := h.Report(hostNow(), 0, 90); len(all.Runs) != 3 {
		t.Errorf("a limit of 0 means every run: %d", len(all.Runs))
	}
}

func TestReport_TheTimelineHoldsSamplesAndBothEndsOfEveryRunInOrder(t *testing.T) {
	h, _ := newHistory(t)
	at(h, -2*time.Hour)
	h.Sample(30_000_000_000, 245_000_000_000)
	run := sampleRun(5_000_000_000) // started t0, finished t0+42s, 19.8 GB before, 24.8 GB after
	if err := h.Append(run); err != nil {
		t.Fatal(err)
	}
	at(h, 3*time.Hour)
	h.Sample(24_000_000_000, 245_000_000_000)

	rep, err := h.Report(hostNow(), 20, 90)
	if err != nil {
		t.Fatal(err)
	}
	want := []Sample{
		{T: t0.Add(-2 * time.Hour), FreeBytes: 30_000_000_000, CapacityBytes: 245_000_000_000},
		{T: t0, FreeBytes: 19_800_000_000, CapacityBytes: run.CapacityBytes},
		{T: t0.Add(42 * time.Second), FreeBytes: 24_800_000_000, CapacityBytes: run.CapacityBytes},
		{T: t0.Add(3 * time.Hour), FreeBytes: 24_000_000_000, CapacityBytes: 245_000_000_000},
	}
	if len(rep.Samples) != len(want) {
		t.Fatalf("timeline = %+v, want %+v", rep.Samples, want)
	}
	for i := range want {
		if !rep.Samples[i].T.Equal(want[i].T) || rep.Samples[i].FreeBytes != want[i].FreeBytes || rep.Samples[i].CapacityBytes != want[i].CapacityBytes {
			t.Errorf("point %d = %+v, want %+v", i, rep.Samples[i], want[i])
		}
	}
}

func TestReport_AMomentIsListedOnce(t *testing.T) {
	h, _ := newHistory(t)
	at(h, 0)
	h.Sample(19_800_000_000, 0) // the same instant and number as the run's start
	if err := h.Append(sampleRun(1)); err != nil {
		t.Fatal(err)
	}
	rep, _ := h.Report(hostNow(), 20, 90)
	n := 0
	for _, s := range rep.Samples {
		if s.T.Equal(t0) && s.FreeBytes == 19_800_000_000 {
			n++
		}
	}
	if n != 1 {
		t.Errorf("the same moment and number twice is one point, got %d in %+v", n, rep.Samples)
	}
}

func TestReport_TheSameMomentWithADifferentNumberIsKept(t *testing.T) {
	h, _ := newHistory(t)
	run := sampleRun(5_000_000_000)
	run.FinishedAt = run.StartedAt // a cleanup so quick that both ends fall in the same second
	if err := h.Append(run); err != nil {
		t.Fatal(err)
	}
	rep, _ := h.Report(hostNow(), 20, 90)
	if len(rep.Samples) != 2 || rep.Samples[0].FreeBytes == rep.Samples[1].FreeBytes {
		t.Errorf("before and after are two different facts, even in the same second: %+v", rep.Samples)
	}
}

func TestReport_IsStampedInUTCWholeSeconds(t *testing.T) {
	h, _ := newHistory(t)
	h.Now = func() time.Time { return time.Date(2026, 10, 15, 16, 9, 7, 741748000, time.FixedZone("CEST", 2*3600)) }
	rep, err := h.Report(hostNow(), 5, 0)
	if err != nil || !strings.Contains(string(mustJSON(t, rep)), `"generated_at": "2026-10-15T14:09:07Z"`) {
		t.Errorf("one simple form of time for every reader:\n%s %v", mustJSON(t, rep), err)
	}
}

func TestReport_DaysLimitsTheTimelineButNotTheRunList(t *testing.T) {
	h, _ := newHistory(t)
	old := sampleRun(7)
	old.StartedAt, old.FinishedAt = t0.AddDate(0, 0, -40), t0.AddDate(0, 0, -40).Add(time.Minute)
	if err := h.Append(old); err != nil {
		t.Fatal(err)
	}
	at(h, -45*24*time.Hour)
	h.Sample(40_000_000_000, 0)
	at(h, -10*24*time.Hour)
	h.Sample(25_000_000_000, 0)
	if err := h.Append(sampleRun(9)); err != nil { // today
		t.Fatal(err)
	}
	at(h, 0)

	rep, err := h.Report(hostNow(), 20, 30)
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Runs) != 2 {
		t.Errorf("--days is about the timeline; both runs are still listed: %+v", rep.Runs)
	}
	for _, s := range rep.Samples {
		if s.T.Before(t0.AddDate(0, 0, -30)) {
			t.Errorf("a point older than 30 days is in the timeline: %+v", s)
		}
	}
	if len(rep.Samples) != 3 { // the sample from 10 days ago and both ends of today's run
		t.Errorf("timeline = %+v", rep.Samples)
	}
	if everything, _ := h.Report(hostNow(), 20, 0); len(everything.Samples) != 6 {
		t.Errorf("days 0 means all time: %+v", everything.Samples)
	}
}

func TestReport_NothingYetIsEmptyListsAndNoDamage(t *testing.T) {
	h, _ := newHistory(t)
	rep, err := h.Report(hostNow(), 20, 90)
	if err != nil || len(rep.Runs) != 0 || len(rep.Samples) != 0 || rep.UnreadableLines != 0 {
		t.Fatalf("%+v %v", rep, err)
	}
	raw, err := rep.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"runs", "samples"} {
		if string(doc[k]) != "[]" {
			t.Errorf("%s must be [] when empty, got %s", k, doc[k])
		}
	}
}

func TestReport_DamageInEitherFileIsCountedNotFatal(t *testing.T) {
	h, _ := newHistory(t)
	h.Append(sampleRun(1))
	os.WriteFile(h.SamplesPath(), []byte("junk\nmore junk\n"), 0o600)
	f, _ := os.OpenFile(h.HistoryPath(), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("not a run\n")
	f.Close()
	rep, err := h.Report(hostNow(), 20, 90)
	if err != nil || rep.UnreadableLines != 3 || len(rep.Runs) != 1 {
		t.Errorf("unreadable = %d (want 3), runs = %d, err = %v", rep.UnreadableLines, len(rep.Runs), err)
	}
}

func TestReport_AFileThatIsNotAFileIsAnError(t *testing.T) {
	h, _ := newHistory(t)
	if err := os.MkdirAll(h.HistoryPath(), 0o700); err != nil { // a folder where the history should be
		t.Fatal(err)
	}
	if _, err := h.Report(hostNow(), 20, 90); err == nil {
		t.Error("a history that is a folder cannot be read, and that is said instead of pretending it is empty")
	}
}

// samplesHistory is deterministic: fixed times and numbers.
func sampleReport() *HistoryReport {
	run := Run{
		SchemaVersion: 1,
		StartedAt:     time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC), FinishedAt: time.Date(2026, 10, 14, 12, 0, 42, 0, time.UTC),
		Deleted: 3, Skipped: 1, Failed: 1, FreedBytes: 4_642_000_000, FreedInsideBytes: 6_200_000_000,
		FreeBefore: 19_800_000_000, FreeAfter: 24_442_000_000, CapacityBytes: 245_107_195_904,
		Items: []RunItem{
			{Rule: "go-build", Group: "Go build cache", Path: "/Users/test/Library/Caches/go-build", Status: StatusDeleted, Bytes: 3_715_000_000, FreedBytes: 3_715_000_000},
			{Rule: "docker", Group: "Docker", Path: "docker: unused images", Status: StatusDeleted, Bytes: 6_200_000_000, FreedBytes: 6_200_000_000, FreesInside: "Docker's disk image"},
			{Rule: "uv-cache", Group: "uv cache", Path: "/Users/test/.cache/uv", Status: StatusFailed, Bytes: 2_500_000_000, Reason: "permission denied"},
		},
	}
	return &HistoryReport{
		SchemaVersion: 1, GeneratedAt: time.Date(2026, 10, 15, 9, 0, 0, 0, time.UTC),
		Host: Host{Volume: "/System/Volumes/Data", FreeBytes: 24_000_000_000, CapacityBytes: 245_107_195_904},
		Runs: []Run{run},
		Samples: []Sample{
			{T: time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC), FreeBytes: 21_000_000_000, CapacityBytes: 245_107_195_904},
			{T: run.StartedAt, FreeBytes: 19_800_000_000, CapacityBytes: 245_107_195_904},
			{T: run.FinishedAt, FreeBytes: 24_442_000_000, CapacityBytes: 245_107_195_904},
		},
		UnreadableLines: 0,
	}
}

// The golden file is the contract with the app's history screen and the menu bar. Changing it is a deliberate
// edit of testdata/history_v1.golden.json, and a schema version bump if it breaks readers.
func TestHistoryReportJSON_MatchesGolden(t *testing.T) {
	got, err := sampleReport().JSON()
	if err != nil {
		t.Fatal(err)
	}
	golden := filepath.Join("testdata", "history_v1.golden.json")
	if *update {
		if err := os.WriteFile(golden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("cannot read the golden file (run `go test ./pkg/engine -run Golden -update`): %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("history JSON differs from %s\n--- got ---\n%s\n--- want ---\n%s", golden, got, want)
	}
}

func TestHistoryReportJSON_KeysAreExactlyTheSchema(t *testing.T) {
	raw, err := sampleReport().JSON()
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	assertKeys(t, "top level", doc, "schema_version", "generated_at", "host", "runs", "samples", "unreadable_lines")
	assertKeys(t, "host", doc["host"].(map[string]any), "volume", "free_bytes", "capacity_bytes")
	run := doc["runs"].([]any)[0].(map[string]any)
	assertKeys(t, "run", run, "schema_version", "started_at", "finished_at", "deleted", "skipped", "failed", "freed_bytes",
		"freed_inside_bytes", "free_before", "free_after", "capacity_bytes", "stopped", "items")
	assertKeys(t, "deleted item", run["items"].([]any)[0].(map[string]any), "rule", "group", "path", "status", "bytes", "freed_bytes")
	assertKeys(t, "item freed inside another program", run["items"].([]any)[1].(map[string]any), "rule", "group", "path", "status", "bytes", "freed_bytes", "frees_inside")
	assertKeys(t, "failed item", run["items"].([]any)[2].(map[string]any), "rule", "group", "path", "status", "bytes", "freed_bytes", "reason")
	assertKeys(t, "sample", doc["samples"].([]any)[0].(map[string]any), "t", "free_bytes", "capacity_bytes")
	if strings.Contains(string(raw), "items_omitted") {
		t.Error("items_omitted appears only when items were dropped")
	}
}

func TestHistoryReportJSON_RoundTrips(t *testing.T) {
	raw, _ := sampleReport().JSON()
	var back HistoryReport
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	again, _ := back.JSON()
	if !bytes.Equal(raw, again) {
		t.Errorf("a report must read back to the same document:\n%s\n%s", raw, again)
	}
}

// ---- Engine.Host ----

func TestEngineHost_SaysHowBigAndHowFullTheVolumeIs(t *testing.T) {
	f := newFixture(t)
	f.eng.Capacity = func() int64 { return 9000 }
	h, err := f.eng.Host()
	if err != nil || h != (Host{Volume: "/sandbox", FreeBytes: 1000, CapacityBytes: 9000}) {
		t.Errorf("Host = %+v, %v", h, err)
	}
	f.eng.Free = func() (string, int64, error) { return "", 0, errors.New("no statfs") }
	if _, err := f.eng.Host(); err == nil {
		t.Error("a free space that cannot be read must be an error, not an empty disk")
	}
}
