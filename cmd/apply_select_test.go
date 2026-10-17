package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
)

// selFile writes a selection file (a JSON array of paths) and returns its path.
func selFile(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "selection.json")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func selection(t *testing.T, paths ...string) string {
	t.Helper()
	b, err := json.Marshal(paths)
	if err != nil {
		t.Fatal(err)
	}
	return selFile(t, string(b))
}

// events parses stdout as NDJSON: every line must be one JSON object.
func events(t *testing.T, stdout string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for i, line := range strings.Split(strings.TrimSuffix(stdout, "\n"), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("stdout line %d is not a JSON object: %q (%v)", i+1, line, err)
		}
		out = append(out, ev)
	}
	return out
}

func kinds(evs []map[string]any) string {
	var k []string
	for _, e := range evs {
		k = append(k, e["event"].(string))
	}
	return strings.Join(k, ",")
}

func itemFor(evs []map[string]any, path string) map[string]any {
	for _, e := range evs {
		if e["event"] == "item" && e["path"] == path {
			return e
		}
	}
	return nil
}

// ---- --select-file in the human flow ----

func TestApply_ASelectionLimitsWhatIsCleaned(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--select-file", selection(t, a.goCache))
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	if present(a.goCache) || !present(a.npmCache) {
		t.Errorf("only the selected item may go: go=%v npm=%v", present(a.goCache), present(a.npmCache))
	}
	if strings.Contains(o.stdout, "npm download cache") {
		t.Errorf("the plan shown is the narrowed plan:\n%s", o.stdout)
	}
}

func TestApply_ASelectionCanNeverAddAnything(t *testing.T) {
	a := newApp(t)
	precious := a.sb.Home("Documents/important.txt")
	a.sb.WriteFile(t, precious, 100, 0)
	notPlanned := a.sb.Home(".npm/_cacache") // a rule claims it, but --only keeps that rule out of the plan

	o := a.run("", "apply", "--yes", "--only", "go-build", "--select-file", selection(t, a.goCache, precious, notPlanned, a.sb.Env.Home, "/"))
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	if present(a.goCache) {
		t.Error("the planned, selected item should go")
	}
	if !present(precious) || !present(a.npmCache) || !present(a.sb.Env.Home) {
		t.Fatal("a selected path that is not in the plan must never be deleted")
	}
	for _, p := range []string{precious, notPlanned} {
		if !strings.Contains(o.stderr, "skipped: "+shortPath(p, a.sb.Env.Home)+": not in the current plan") {
			t.Errorf("the refusal for %s should be told:\n%s", p, o.stderr)
		}
	}
}

func TestApply_AnEmptySelectionCleansNothing(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--select-file", selFile(t, "[]"))
	if o.err != nil || !strings.Contains(o.stdout, "Nothing to clean right now") {
		t.Errorf("an empty selection is nothing, not everything: %v\n%s", o.err, o.stdout)
	}
	if !a.cachesIntact() {
		t.Fatal("nothing may be deleted")
	}
}

func TestApply_ABadSelectionFileStopsBeforeAnythingIsPlanned(t *testing.T) {
	for name, content := range map[string]string{
		"not json":       "{",
		"an object":      `{"paths":["/x"]}`,
		"numbers":        `[1,2]`,
		"mixed":          `["/x", 2]`,
		"null":           `null`,
		"trailing text":  `["/x"] trailing`,
		"a bare string":  `"/x"`,
		"empty file":     ``,
		"nested arrays":  `[["/x"]]`,
		"a long number":  `[99999999999999999999]`,
		"a boolean list": `[true]`,
	} {
		a := newApp(t)
		planned := 0
		inner := a.d.newEngine
		a.d.newEngine = func() (*engine.Engine, error) { planned++; return inner() }
		o := a.run("", "apply", "--yes", "--select-file", selFile(t, content))
		if o.err == nil || !strings.Contains(o.err.Error(), "selection file") {
			t.Errorf("%s: want a selection-file error, got %v", name, o.err)
		}
		if !a.cachesIntact() || strings.Contains(o.stdout, "=== PLAN ===") || planned != 0 {
			t.Errorf("%s: nothing may be planned or deleted with a bad selection (engines built: %d)", name, planned)
		}
	}
	a := newApp(t)
	huge := selFile(t, "["+strings.Repeat(" ", maxSelectionBytes)+"]") // valid JSON, one byte too many
	if o := a.run("", "apply", "--yes", "--select-file", huge); o.err == nil || !strings.Contains(o.err.Error(), "larger than") || !a.cachesIntact() {
		t.Errorf("an oversized selection file is refused: %v", o.err)
	}
	a = newApp(t)
	if o := a.run("", "apply", "--yes", "--select-file", filepath.Join(t.TempDir(), "missing.json")); o.err == nil || !strings.Contains(o.err.Error(), "selection file") || !a.cachesIntact() {
		t.Errorf("a missing file is an error and deletes nothing: %v", o.err)
	}
}

func TestApply_ASelectionStillNeedsTheHumanGate(t *testing.T) {
	a := newApp(t)
	a.tty = false
	o := a.run("\n", "apply", "--select-file", selection(t, a.goCache))
	if !errors.Is(o.err, errNoTerminal) || !a.cachesIntact() {
		t.Errorf("a selection is not a confirmation: %v", o.err)
	}
}

// ---- --json ----

func TestApply_JSONNeedsYesOrDryRun(t *testing.T) {
	for _, tty := range []bool{true, false} {
		a := newApp(t)
		a.tty = tty
		planned := 0
		inner := a.d.newEngine
		a.d.newEngine = func() (*engine.Engine, error) { planned++; return inner() }

		o := a.run("\n", "apply", "--json", "--select-file", selection(t, a.goCache))
		if !errors.Is(o.err, errJSONNeedsYes) {
			t.Fatalf("tty=%v: want errJSONNeedsYes, got %v", tty, o.err)
		}
		if o.stdout != "" || planned != 0 || !a.cachesIntact() {
			t.Errorf("tty=%v: nothing may be printed, planned or deleted: stdout=%q planned=%d", tty, o.stdout, planned)
		}
	}
}

func TestApply_JSONReportsEachItemAndTheEnd(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	if err := j.Stamp(); err != nil { // an earlier cleanup: the text mode would announce it on stderr
		t.Fatal(err)
	}
	a.tty = false // the caller is the human; no terminal is needed with --yes
	o := a.run("", "apply", "--yes", "--json", "--select-file", selection(t, a.goCache))
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	evs := events(t, o.stdout)
	if kinds(evs) != "start,item,done" {
		t.Fatalf("events = %s\n%s", kinds(evs), o.stdout)
	}
	start, item, done := evs[0], evs[1], evs[2]
	if start["schema_version"] != float64(1) || start["selected"] != float64(1) || start["matched"] != float64(1) || start["bytes"].(float64) <= 0 || start["free_bytes"].(float64) <= 0 {
		t.Errorf("start = %v", start)
	}
	if item["rule"] != "go-build" || item["group"] != "Go build cache" || item["path"] != a.goCache || item["status"] != "deleted" || item["reason"] != "" ||
		item["bytes"].(float64) <= 0 || item["freed_bytes"].(float64) != item["bytes"].(float64) {
		t.Errorf("item = %v", item)
	}
	if done["deleted"] != float64(1) || done["skipped"] != float64(0) || done["failed"] != float64(0) || done["stopped"] != false ||
		done["freed_bytes"].(float64) <= 0 || done["free_before"].(float64) <= 0 || done["free_after"].(float64) <= 0 {
		t.Errorf("done = %v", done)
	}
	if w, ok := done["warnings"].([]any); !ok || len(w) != 0 {
		t.Errorf("warnings must be an empty list, never null: %#v", done["warnings"])
	}
	if done["log"] != j.LogPath() {
		t.Errorf("done.log = %v, want %s", done["log"], j.LogPath())
	}
	if present(a.goCache) || !present(a.npmCache) {
		t.Error("only the selected item may go")
	}
	if strings.TrimSpace(o.stderr) != "" {
		t.Errorf("--json prints nothing else on stderr:\n%s", o.stderr)
	}
	if log, err := os.ReadFile(j.LogPath()); err != nil || !strings.Contains(string(log), " deleted "+a.goCache+"\n") {
		t.Errorf("a real apply through --json is logged like any other: %v %s", err, log)
	}
}

func TestApply_JSONStdoutIsNothingButEvents(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--json") // no selection: everything in the plan
	if o.err != nil {
		t.Fatalf("apply failed: %v", o.err)
	}
	evs := events(t, o.stdout) // fails on any line that is not JSON
	if kinds(evs) != "start,item,item,done" || evs[0]["selected"] != float64(2) || evs[0]["matched"] != float64(2) {
		t.Errorf("no selection means the whole plan: %s %v", kinds(evs), evs[0])
	}
	if present(a.goCache) || present(a.npmCache) {
		t.Error("both items were in the plan and should be gone")
	}
}

func TestApply_JSONNeverDeletesWhatThePlanDoesNotHold(t *testing.T) {
	a := newApp(t)
	precious := a.sb.Home("Documents/important.txt")
	a.sb.WriteFile(t, precious, 100, 0)
	o := a.run("", "apply", "--yes", "--json", "--select-file", selection(t, precious, a.goCache, precious, a.sb.Env.Home))
	if o.err != nil {
		t.Fatalf("apply failed: %v", o.err)
	}
	evs := events(t, o.stdout)
	if kinds(evs) != "start,item,item,item,done" {
		t.Fatalf("events = %s", kinds(evs))
	}
	if evs[0]["selected"] != float64(3) || evs[0]["matched"] != float64(1) {
		t.Errorf("duplicates count once: %v", evs[0])
	}
	for _, p := range []string{precious, a.sb.Env.Home} {
		it := itemFor(evs, p)
		if it == nil || it["status"] != "skipped" || it["reason"] != "not in the current plan" || it["rule"] != "" || it["group"] != "" || it["bytes"] != float64(0) || it["freed_bytes"] != float64(0) {
			t.Errorf("%s should be reported as skipped, not in the plan: %v", p, it)
		}
	}
	done := evs[len(evs)-1]
	if done["deleted"] != float64(1) || done["skipped"] != float64(2) {
		t.Errorf("the refusals count as skipped: %v", done)
	}
	if !present(precious) || !present(a.sb.Env.Home) || !present(a.npmCache) || present(a.goCache) {
		t.Fatal("exactly the planned, selected item may go")
	}
}

func TestApply_JSONDryRunChangesAndWritesNothing(t *testing.T) {
	a := newApp(t)
	a.withJournal()
	a.tty = false
	o := a.run("", "apply", "--dry-run", "--json", "--select-file", selection(t, a.goCache, a.npmCache))
	if o.err != nil {
		t.Fatalf("apply failed: %v", o.err)
	}
	evs := events(t, o.stdout)
	if kinds(evs) != "start,item,item,done" {
		t.Fatalf("events = %s", kinds(evs))
	}
	for _, it := range evs[1:3] {
		if it["status"] != "dry-run" || it["freed_bytes"] != float64(0) {
			t.Errorf("item = %v", it)
		}
	}
	if evs[3]["deleted"] != float64(0) {
		t.Errorf("done = %v", evs[3])
	}
	if !a.cachesIntact() || present(engine.StateDir(a.sb.Env.Home)) {
		t.Error("a dry run deletes nothing and writes nothing")
	}
	if _, has := evs[3]["log"]; has {
		t.Errorf("nothing was logged, so there is no log path: %v", evs[3])
	}
}

func TestApply_JSONAnItemThatFailsIsReportedAndFailsTheRun(t *testing.T) {
	a := newApp(t)
	a.eng.Remove = func(p string) error {
		if p == a.goCache {
			return errors.New("permission denied")
		}
		return os.RemoveAll(p)
	}
	o := a.run("", "apply", "--yes", "--json")
	if !errors.Is(o.err, errItemsFailed) {
		t.Fatalf("want errItemsFailed, got %v", o.err)
	}
	evs := events(t, o.stdout)
	it := itemFor(evs, a.goCache)
	if it == nil || it["status"] != "failed" || !strings.Contains(it["reason"].(string), "permission denied") {
		t.Errorf("item = %v", it)
	}
	if itemFor(evs, a.npmCache)["status"] != "deleted" {
		t.Error("one failure must not stop the others")
	}
	if done := evs[len(evs)-1]; done["failed"] != float64(1) || done["deleted"] != float64(1) {
		t.Errorf("done = %v", done)
	}
}

// busyRule plans one real file whose guard no longer holds when it is checked again.
type busyRule struct{ path string }

func (busyRule) ID() string    { return "busy" }
func (busyRule) Group() string { return "Busy things" }
func (r busyRule) Plan(context.Context, rules.Deps) ([]rules.Candidate, []rules.Skip, error) {
	return []rules.Candidate{{Path: r.path, Bytes: 5, Tier: rules.TierSafe, Action: rules.ActionDelete}}, nil, nil
}
func (r busyRule) Allows(_ rules.Deps, p string) bool { return p == r.path }
func (busyRule) Recheck(context.Context, rules.Deps, rules.Candidate) error {
	return errors.New("in use now")
}

func TestApply_JSONAGuardThatNoLongerHoldsSkipsTheItem(t *testing.T) {
	a := newApp(t)
	busy := a.sb.Home("Library/Caches/busy-thing")
	a.sb.WriteFile(t, busy, 5, 0)
	a.eng.Rules = []rules.Rule{busyRule{path: busy}}

	o := a.run("", "apply", "--yes", "--json")
	if o.err != nil {
		t.Fatalf("a skip is not a failure: %v", o.err)
	}
	evs := events(t, o.stdout)
	it := itemFor(evs, busy)
	if it == nil || it["status"] != "skipped" || it["reason"] != "in use now" || it["freed_bytes"] != float64(0) {
		t.Errorf("item = %v", it)
	}
	if !present(busy) {
		t.Error("a skipped item stays")
	}
	if done := evs[len(evs)-1]; done["skipped"] != float64(1) || done["deleted"] != float64(0) {
		t.Errorf("done = %v", done)
	}
}

func TestApply_JSONStoppedMidRunSaysSoAndFails(t *testing.T) {
	a := newApp(t)
	ctx, cancel := context.WithCancel(context.Background())
	a.eng.Remove = func(p string) error {
		err := os.RemoveAll(p)
		cancel() // an interrupt arrives while the first item is being removed
		return err
	}
	cmd := newRootCmd(a.d)
	var out, errOut bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&errOut)
	cmd.SetArgs([]string{"apply", "--yes", "--json"})
	err := cmd.ExecuteContext(ctx)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
	evs := events(t, out.String())
	done := evs[len(evs)-1]
	if done["event"] != "done" || done["stopped"] != true || done["deleted"] != float64(1) {
		t.Errorf("a stopped run still ends with a done event: %v", done)
	}
	if present(a.goCache) == present(a.npmCache) {
		t.Error("exactly one of the two items was done when the run was stopped")
	}
}

func TestApply_JSONWithNothingSelectedIsAnEmptySuccess(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--json", "--select-file", selFile(t, "[]"))
	if o.err != nil {
		t.Fatal(o.err)
	}
	evs := events(t, o.stdout)
	if kinds(evs) != "start,done" || evs[0]["selected"] != float64(0) || evs[0]["matched"] != float64(0) || evs[1]["deleted"] != float64(0) {
		t.Errorf("events = %s %v", kinds(evs), evs)
	}
	if !a.cachesIntact() {
		t.Error("nothing may be deleted")
	}
}

func TestApply_JSONAJournalProblemIsAWarningAndHidesTheLogPath(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	a.sb.WriteFile(t, j.Dir, 1, 0) // a file where the state folder should be
	o := a.run("", "apply", "--yes", "--json", "--select-file", selection(t, a.goCache))
	if o.err != nil {
		t.Fatalf("the cleanup itself worked: %v", o.err)
	}
	evs := events(t, o.stdout)
	done := evs[len(evs)-1]
	w, _ := done["warnings"].([]any)
	if len(w) != 2 || !strings.Contains(w[0].(string), "cleanup log") || !strings.Contains(w[1].(string), "last-run stamp") {
		t.Errorf("warnings = %v", done["warnings"])
	}
	if _, has := done["log"]; has {
		t.Errorf("no log path for a log that was not written: %v", done)
	}
	if present(a.goCache) {
		t.Error("the item must still be deleted")
	}
}

func TestApply_JSONUnknownRuleIsAnErrorBeforeAnyEvent(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--json", "--only", "no-such-rule")
	if o.err == nil || o.stdout != "" || !a.cachesIntact() {
		t.Errorf("want an error with no events and nothing deleted: %v %q", o.err, o.stdout)
	}
}

func TestApply_SelectionAndOnlyCombine(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--json", "--only", "go-build", "--select-file", selection(t, a.goCache, a.npmCache))
	if o.err != nil {
		t.Fatal(o.err)
	}
	evs := events(t, o.stdout)
	if evs[0]["selected"] != float64(2) || evs[0]["matched"] != float64(1) {
		t.Errorf("start = %v", evs[0])
	}
	if itemFor(evs, a.npmCache)["status"] != "skipped" || present(a.goCache) || !present(a.npmCache) {
		t.Errorf("the rule filter and the selection both apply: %v", evs)
	}
}

func TestApply_JSONAReaderThatWentAwayDoesNotStopTheCleaning(t *testing.T) {
	a := newApp(t)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	r.Close() // the reader (the app) is gone before cmm writes its first event

	cmd := newRootCmd(a.d)
	cmd.SetOut(w)
	cmd.SetErr(io.Discard)
	cmd.SetArgs([]string{"apply", "--yes", "--json"})
	err = cmd.Execute()
	w.Close()

	if !errors.Is(err, syscall.EPIPE) {
		t.Fatalf("a lost reader is reported at the end, not by dying half way: %v", err)
	}
	if present(a.goCache) || present(a.npmCache) {
		t.Error("a confirmed cleaning is not abandoned because nobody is listening any more")
	}
}
