package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/engine"
)

// withHistory gives the sandboxed app the history that the real wiring gives the real engine.
func (a *app) withHistory() *engine.FileHistory {
	h := engine.NewFileHistory(a.sb.Env.Home, a.sb.Env.Clock)
	a.eng.History = h
	return h
}

func lines(t *testing.T, path string) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
}

// ---- cmm sample ----

func TestSample_RecordsTheFreeSpaceAndSaysSo(t *testing.T) {
	a := newApp(t)
	o := a.run("", "sample")
	if o.err != nil {
		t.Fatalf("sample failed: %v\n%s%s", o.err, o.stdout, o.stderr)
	}
	if !strings.Contains(o.stdout, "Recorded: 5.0 GB free") {
		t.Errorf("it says what it noted:\n%s", o.stdout)
	}
	h := engine.NewFileHistory(a.sb.Env.Home, a.sb.Env.Clock)
	got := lines(t, h.SamplesPath())
	if len(got) != 1 || !strings.Contains(got[0], `"free_bytes":5368709120`) || !strings.Contains(got[0], `"t":"2026-10-14T12:00:00Z"`) {
		t.Errorf("one line with the time and the free bytes: %v", got)
	}
}

func TestSample_AgainStraightAwayIsNotDue(t *testing.T) {
	a := newApp(t)
	a.run("", "sample")
	o := a.run("", "sample")
	if o.err != nil || !strings.Contains(o.stdout, "Not due") || strings.Contains(o.stdout, "Recorded") {
		t.Errorf("a second reading a moment later is not kept:\n%v\n%s", o.err, o.stdout)
	}
	h := engine.NewFileHistory(a.sb.Env.Home, a.sb.Env.Clock)
	if got := lines(t, h.SamplesPath()); len(got) != 1 {
		t.Errorf("still one sample: %v", got)
	}
	a.sb.Advance(31 * time.Minute)
	if o := a.run("", "sample"); !strings.Contains(o.stdout, "Recorded") {
		t.Errorf("half an hour later it is due again:\n%s", o.stdout)
	}
}

func TestSample_JSON(t *testing.T) {
	a := newApp(t)
	a.eng.Capacity = func() int64 { return 245_107_195_904 }
	o := a.run("", "sample", "--json")
	if o.err != nil {
		t.Fatal(o.err)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(o.stdout), &doc); err != nil {
		t.Fatalf("stdout is one JSON document: %v\n%s", err, o.stdout)
	}
	if doc["recorded"] != true || doc["free_bytes"] != float64(5<<30) || doc["capacity_bytes"] != float64(245_107_195_904) || doc["t"] != "2026-10-14T12:00:00Z" {
		t.Errorf("sample JSON = %v", doc)
	}
	var again map[string]any
	if o := a.run("", "sample", "--json"); json.Unmarshal([]byte(o.stdout), &again) != nil || again["recorded"] != false {
		t.Errorf("a sample that is not due says recorded=false: %s", o.stdout)
	}
}

func TestSample_ChangesNothingButItsOwnFile(t *testing.T) {
	a := newApp(t)
	if o := a.run("", "sample"); o.err != nil {
		t.Fatal(o.err)
	}
	entries, _ := os.ReadDir(engine.StateDir(a.sb.Env.Home))
	if len(entries) != 1 || entries[0].Name() != engine.SamplesFile {
		t.Errorf("only the samples file may appear in the state folder: %v", entries)
	}
	if !a.cachesIntact() {
		t.Error("sample never deletes anything")
	}
}

func TestSample_FreeSpaceThatCannotBeReadIsAnErrorAndWritesNothing(t *testing.T) {
	a := newApp(t)
	a.eng.Free = func() (string, int64, error) { return "", 0, errors.New("statfs failed") }
	o := a.run("", "sample")
	if o.err == nil || !strings.Contains(o.err.Error(), "statfs failed") {
		t.Errorf("a failed reading must not be recorded as an empty disk: %v\n%s", o.err, o.stdout)
	}
	if present(engine.StateDir(a.sb.Env.Home)) {
		t.Error("nothing is written")
	}
}

func TestSample_AFileThatCannotBeWrittenIsAnError(t *testing.T) {
	a := newApp(t)
	h := engine.NewFileHistory(a.sb.Env.Home, a.sb.Env.Clock)
	a.sb.WriteFile(t, h.Dir, 1, 0) // a file where the state folder should be
	if o := a.run("", "sample"); o.err == nil {
		t.Errorf("recording is this command's only job, so failing to record is an error:\n%s", o.stdout)
	}
}

// ---- cmm history ----

func TestHistory_NothingYetSaysSoAndLeavesNoTrace(t *testing.T) {
	a := newApp(t)
	o := a.run("", "history")
	if o.err != nil {
		t.Fatalf("history failed: %v", o.err)
	}
	for _, want := range []string{"Free now: 5.0 GB", "No cleanups recorded yet", "No free-space samples yet"} {
		if !strings.Contains(o.stdout, want) {
			t.Errorf("history should say %q:\n%s", want, o.stdout)
		}
	}
	if present(engine.StateDir(a.sb.Env.Home)) {
		t.Error("reading the history must not create the state folder")
	}
}

func TestHistory_ShowsEachCleanupAndHowFreeSpaceMoved(t *testing.T) {
	a := newApp(t)
	a.withHistory()
	a.run("", "sample")
	a.sb.Advance(time.Hour)
	if o := a.run("\n", "apply"); o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	a.sb.Advance(time.Hour)
	o := a.run("", "history")
	if o.err != nil {
		t.Fatal(o.err)
	}
	for _, want := range []string{"Cleanups, newest first", "2026-10-14 13:00", "2 deleted, 0 skipped, 0 failed", "Free space, last 90 days"} {
		if !strings.Contains(o.stdout, want) {
			t.Errorf("history should say %q:\n%s", want, o.stdout)
		}
	}
}

func TestHistory_JSONIsPureOnStdoutAndMatchesTheSchema(t *testing.T) {
	a := newApp(t)
	a.withHistory()
	a.eng.Capacity = func() int64 { return 100 << 30 }
	cleaned := false
	a.eng.Free = func() (string, int64, error) {
		if cleaned {
			return "/sandbox", 6 << 30, nil
		}
		return "/sandbox", 5 << 30, nil
	}
	a.eng.Remove = func(p string) error { cleaned = true; return os.RemoveAll(p) }
	a.run("", "sample")
	a.sb.Advance(time.Hour)
	a.run("\n", "apply")

	o := a.run("", "history", "--json")
	if o.err != nil {
		t.Fatal(o.err)
	}
	if o.stderr != "" {
		t.Errorf("--json keeps the banner and the chatter off both streams: %q", o.stderr)
	}
	var rep engine.HistoryReport
	if err := json.Unmarshal([]byte(o.stdout), &rep); err != nil {
		t.Fatalf("stdout must be one JSON document: %v\n%s", err, o.stdout)
	}
	if rep.SchemaVersion != 1 || rep.Host.Volume != "/sandbox" || rep.Host.FreeBytes != 6<<30 || rep.Host.CapacityBytes != 100<<30 {
		t.Errorf("header: %+v", rep)
	}
	if len(rep.Runs) != 1 || rep.Runs[0].Deleted != 2 || len(rep.Runs[0].Items) != 2 || rep.Runs[0].CapacityBytes != 100<<30 {
		t.Errorf("runs: %+v", rep.Runs)
	}
	if len(rep.Samples) != 3 { // the sample, and both ends of the run
		t.Errorf("samples: %+v", rep.Samples)
	}
}

func TestHistory_LimitAndDays(t *testing.T) {
	a := newApp(t)
	a.withHistory()
	for i := 0; i < 3; i++ {
		a.sb.WriteFile(t, a.goCache+"/data", 40_000, 0)
		a.sb.WriteFile(t, a.npmCache+"/data", 90_000, 0)
		if o := a.run("", "apply", "--yes"); o.err != nil {
			t.Fatal(o.err)
		}
		a.sb.Advance(24 * time.Hour)
	}
	var rep engine.HistoryReport
	o := a.run("", "history", "--json", "--limit", "2", "--days", "1")
	if err := json.Unmarshal([]byte(o.stdout), &rep); err != nil || len(rep.Runs) != 2 {
		t.Fatalf("--limit 2: %v\n%s", err, o.stdout)
	}
	for _, s := range rep.Samples {
		if s.T.Before(a.sb.Env.Clock().AddDate(0, 0, -1)) {
			t.Errorf("--days 1 keeps the timeline to the last day: %+v", s)
		}
	}
}

func TestHistory_RefusesNonsenseNumbers(t *testing.T) {
	a := newApp(t)
	for _, args := range [][]string{{"history", "--limit", "-1"}, {"history", "--days", "-3"}, {"history", "--limit", "abc"}, {"history", "extra"}} {
		if o := a.run("", args...); o.err == nil {
			t.Errorf("%v should be refused", args)
		}
	}
}

func TestHistory_DamagedLinesAreMentionedNotFatal(t *testing.T) {
	a := newApp(t)
	h := engine.NewFileHistory(a.sb.Env.Home, a.sb.Env.Clock)
	if err := os.MkdirAll(h.Dir, 0o700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(h.HistoryPath(), []byte("garbage\n"), 0o600)
	o := a.run("", "history")
	if o.err != nil || !strings.Contains(o.stdout, "1 line") {
		t.Errorf("the damage is mentioned and nothing stops:\n%v\n%s", o.err, o.stdout)
	}
}

// ---- the wiring ----

func TestProductionEngine_KeepsAHistoryInTheUsersStateFolder(t *testing.T) {
	a := newApp(t)
	eng := newProductionEngine(a.sb.Env)
	h, ok := eng.History.(*engine.FileHistory)
	if !ok {
		t.Fatalf("the engine built for real use must keep a history, got %T", eng.History)
	}
	if h.Dir != engine.StateDir(a.sb.Env.Home) {
		t.Errorf("history dir = %q", h.Dir)
	}
}

func TestApply_ARealRunIsAddedToTheHistoryAndADryRunIsNot(t *testing.T) {
	a := newApp(t)
	h := a.withHistory()
	if o := a.run("", "apply", "--dry-run"); o.err != nil {
		t.Fatal(o.err)
	}
	if present(h.HistoryPath()) {
		t.Fatal("a dry run leaves no record")
	}
	if o := a.run("\n", "apply"); o.err != nil {
		t.Fatal(o.err)
	}
	runs, bad, err := h.Runs(5)
	if err != nil || bad != 0 || len(runs) != 1 || runs[0].Deleted != 2 {
		t.Errorf("a real run is recorded once: %+v bad=%d err=%v", runs, bad, err)
	}
}

func TestApply_JSONRunsAreRecordedToo(t *testing.T) {
	a := newApp(t)
	h := a.withHistory()
	if o := a.run("", "apply", "--yes", "--json"); o.err != nil {
		t.Fatal(o.err)
	}
	if runs, _, _ := h.Runs(5); len(runs) != 1 {
		t.Errorf("the app's way of cleaning is recorded like the terminal's: %+v", runs)
	}
}

func TestApply_AHistoryThatCannotBeWrittenIsAWarning(t *testing.T) {
	a := newApp(t)
	h := a.withHistory()
	a.sb.WriteFile(t, h.Dir, 1, 0) // a file where the state folder should be
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("the cleanup itself worked: %v\n%s", o.err, o.stdout)
	}
	if !strings.Contains(o.stderr, "warning: history:") || a.cachesIntact() {
		t.Errorf("the history problem is a warning and the caches are gone:\n%s", o.stderr)
	}
}

func TestApply_JSONAHistoryProblemIsInTheDoneEvent(t *testing.T) {
	a := newApp(t)
	h := a.withHistory()
	a.sb.WriteFile(t, h.Dir, 1, 0)
	o := a.run("", "apply", "--yes", "--json")
	if o.err != nil {
		t.Fatalf("the cleanup itself worked: %v", o.err)
	}
	evs := events(t, o.stdout)
	done := evs[len(evs)-1]
	warnings, _ := done["warnings"].([]any)
	if done["deleted"] != float64(2) || len(warnings) != 1 || !strings.Contains(warnings[0].(string), "history:") {
		t.Errorf("done = %v", done)
	}
}
