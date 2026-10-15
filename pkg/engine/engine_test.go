package engine

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

// ---- a configurable fake rule ----

type fakeRule struct {
	id, group  string
	items      []rules.Candidate
	skips      []rules.Skip
	planErr    error
	allow      func(path string) bool
	recheckErr map[string]error // by path
	executeErr error
	executed   []string
	execFreed  int64
}

func (f *fakeRule) ID() string    { return f.id }
func (f *fakeRule) Group() string { return f.group }
func (f *fakeRule) Plan(context.Context, rules.Deps) ([]rules.Candidate, []rules.Skip, error) {
	return f.items, f.skips, f.planErr
}
func (f *fakeRule) Allows(_ rules.Deps, path string) bool {
	if f.allow == nil {
		return true
	}
	return f.allow(path)
}
func (f *fakeRule) Recheck(_ context.Context, _ rules.Deps, c rules.Candidate) error {
	return f.recheckErr[c.Path]
}

// commandRule additionally implements rules.Executor.
type commandRule struct{ *fakeRule }

func (c commandRule) Execute(_ context.Context, _ rules.Deps, cand rules.Candidate) (int64, error) {
	c.fakeRule.executed = append(c.fakeRule.executed, cand.Path)
	return c.execFreed, c.executeErr
}

// ---- helpers ----

type fixture struct {
	sb  *systest.Sandbox
	eng *Engine
}

func newFixture(t *testing.T, rs ...rules.Rule) *fixture {
	t.Helper()
	sb := systest.NewSandbox(t)
	eng := New(rules.Deps{Env: sb.Env, Guard: guard.New(sb.Env), Policy: policy.New(sb.Env)}, rs)
	eng.Free = func() (string, int64, error) { return "/sandbox", 1000, nil }
	return &fixture{sb: sb, eng: eng}
}

func (f *fixture) laneFile(t *testing.T, lane, rel string, size int) string {
	t.Helper()
	p := f.sb.Home("lane-builds", lane, rel)
	f.sb.WriteFile(t, p, size, 0)
	return p
}

func cand(rule, group, path string, bytes int64) rules.Candidate {
	return rules.Candidate{Rule: rule, Group: group, Path: path, Bytes: bytes, Tier: rules.TierSafe, Action: rules.ActionDelete}
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

var ctx = context.Background()

// ---- Plan ----

func TestPlan_CollectsItemsGroupsAndTotals(t *testing.T) {
	f := newFixture(t)
	a := f.laneFile(t, "a", "node_modules/x", 10)
	b := f.laneFile(t, "b", "node_modules/y", 10)
	c := f.laneFile(t, "c", "ios/Pods/z", 10)
	f.eng.Rules = []rules.Rule{
		&fakeRule{id: "deps", group: "Dependencies", items: []rules.Candidate{
			cand("", "Dependencies", filepath.Dir(a), 100),
			cand("", "Dependencies", filepath.Dir(b), 300),
		}, skips: []rules.Skip{{Reason: "lane x is busy"}}},
		&fakeRule{id: "pods", group: "Pods", items: []rules.Candidate{cand("", "Pods", filepath.Dir(filepath.Dir(c)), 50)}},
	}

	plan, err := f.eng.Plan(ctx)
	if err != nil {
		t.Fatalf("Plan() failed: %v", err)
	}
	if plan.SchemaVersion != SchemaVersion {
		t.Errorf("schema version = %d", plan.SchemaVersion)
	}
	if len(plan.Items) != 3 || plan.TotalBytes != 450 {
		t.Fatalf("items=%d total=%d, want 3 and 450", len(plan.Items), plan.TotalBytes)
	}
	if plan.Items[0].Rule != "deps" || plan.Items[2].Rule != "pods" {
		t.Errorf("the engine must stamp each item with its rule id: %+v", plan.Items)
	}
	if len(plan.Groups) != 2 || plan.Groups[0].Group != "Dependencies" || plan.Groups[0].Bytes != 400 || plan.Groups[0].Count != 2 || plan.Groups[1].Group != "Pods" {
		t.Errorf("groups wrong or out of order: %+v", plan.Groups)
	}
	if len(plan.Skipped) != 1 || plan.Skipped[0].Rule != "deps" || plan.Skipped[0].Reason != "lane x is busy" {
		t.Errorf("skips must carry the rule id: %+v", plan.Skipped)
	}
	if plan.Host.FreeBytes != 1000 || plan.Host.Volume != "/sandbox" {
		t.Errorf("host info wrong: %+v", plan.Host)
	}
	if !plan.GeneratedAt.Equal(f.sb.Env.Clock()) {
		t.Errorf("generated_at should come from the injected clock")
	}
}

func TestPlan_EmptyListsAreNotNull(t *testing.T) {
	f := newFixture(t, &fakeRule{id: "none", group: "None"})
	plan, err := f.eng.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Items == nil || plan.Groups == nil || plan.Skipped == nil {
		t.Errorf("empty lists must be empty slices so the JSON shows [] and not null: %+v", plan)
	}
}

func TestPlan_RuleFailureBecomesASkipAndOthersContinue(t *testing.T) {
	f := newFixture(t)
	p := f.laneFile(t, "a", "node_modules/x", 10)
	f.eng.Rules = []rules.Rule{
		&fakeRule{id: "broken", group: "Broken", planErr: errors.New("simctl exploded")},
		&fakeRule{id: "ok", group: "OK", items: []rules.Candidate{cand("", "OK", filepath.Dir(p), 5)}},
	}
	plan, err := f.eng.Plan(ctx)
	if err != nil {
		t.Fatalf("one failing rule must not fail the whole plan: %v", err)
	}
	if len(plan.Items) != 1 || len(plan.Skipped) != 1 || plan.Skipped[0].Rule != "broken" || !strings.Contains(plan.Skipped[0].Reason, "simctl exploded") {
		t.Errorf("unexpected plan: %+v", plan)
	}
}

func TestPlan_RefusesAPathThePolicyForbids(t *testing.T) {
	f := newFixture(t)
	docs := f.sb.Home("Documents", "project", "x")
	f.eng.Rules = []rules.Rule{&fakeRule{id: "bad", group: "Bad", items: []rules.Candidate{cand("", "Bad", docs, 1)}}}

	_, err := f.eng.Plan(ctx)
	if !errors.Is(err, ErrRuleBug) || !errors.Is(err, policy.ErrRefused) {
		t.Fatalf("a rule planning a protected path is a bug and must fail the plan, got %v", err)
	}
}

func TestPlan_RefusesAPathTheRuleDoesNotAllow(t *testing.T) {
	f := newFixture(t)
	p := f.laneFile(t, "a", "node_modules/x", 10)
	f.eng.Rules = []rules.Rule{&fakeRule{id: "narrow", group: "Narrow", allow: func(string) bool { return false },
		items: []rules.Candidate{cand("", "Narrow", filepath.Dir(p), 1)}}}

	if _, err := f.eng.Plan(ctx); !errors.Is(err, ErrRuleBug) {
		t.Fatalf("a rule must Allow what it plans, got %v", err)
	}
}

func TestPlan_RefusesTheSamePathFromTwoRules(t *testing.T) {
	f := newFixture(t)
	p := f.laneFile(t, "a", "node_modules/x", 10)
	dir := filepath.Dir(p)
	f.eng.Rules = []rules.Rule{
		&fakeRule{id: "one", group: "One", items: []rules.Candidate{cand("", "One", dir, 1)}},
		&fakeRule{id: "two", group: "Two", items: []rules.Candidate{cand("", "Two", dir, 1)}},
	}
	if _, err := f.eng.Plan(ctx); !errors.Is(err, ErrRuleBug) {
		t.Fatalf("two rules claiming one path is a bug, got %v", err)
	}
}

func TestPlan_RefusesASymlinkTarget(t *testing.T) {
	f := newFixture(t)
	real := f.laneFile(t, "a", "node_modules/x", 10)
	link := f.sb.Home("lane-builds", "a", "link")
	if err := os.Symlink(filepath.Dir(real), link); err != nil {
		t.Fatal(err)
	}
	f.eng.Rules = []rules.Rule{&fakeRule{id: "l", group: "L", items: []rules.Candidate{cand("", "L", link, 1)}}}

	if _, err := f.eng.Plan(ctx); !errors.Is(err, ErrRuleBug) {
		t.Fatalf("a symlink must never be planned, got %v", err)
	}
}

func TestPlan_RejectsUnknownTierOrAction(t *testing.T) {
	f := newFixture(t)
	p := f.laneFile(t, "a", "node_modules/x", 10)
	bad := cand("", "G", filepath.Dir(p), 1)
	bad.Tier = "yolo"
	f.eng.Rules = []rules.Rule{&fakeRule{id: "t", group: "G", items: []rules.Candidate{bad}}}
	if _, err := f.eng.Plan(ctx); !errors.Is(err, ErrRuleBug) {
		t.Fatalf("an unknown tier is a bug, got %v", err)
	}
}

func TestPlan_StopsWhenTheContextIsCancelled(t *testing.T) {
	f := newFixture(t, &fakeRule{id: "a", group: "A"})
	cctx, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := f.eng.Plan(cctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
}

// ---- Apply ----

func twoItemPlan(t *testing.T) (*fixture, *fakeRule, string, string) {
	t.Helper()
	f := newFixture(t)
	a := filepath.Dir(f.laneFile(t, "a", "node_modules/x", 10))
	b := filepath.Dir(f.laneFile(t, "b", "node_modules/y", 10))
	r := &fakeRule{id: "deps", group: "Deps", items: []rules.Candidate{cand("", "Deps", a, 100), cand("", "Deps", b, 200)}}
	f.eng.Rules = []rules.Rule{r}
	return f, r, a, b
}

func TestApply_DeletesPlannedItemsAndReportsThem(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, err := f.eng.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil {
		t.Fatalf("Apply() failed: %v", err)
	}
	if exists(a) || exists(b) {
		t.Error("both planned directories should be gone")
	}
	if rep.Deleted != 2 || rep.Failed != 0 || rep.Skipped != 0 || !rep.OK() || rep.FreedBytes != 300 {
		t.Errorf("unexpected report: %+v", rep)
	}
}

func TestApply_DryRunNeverDeletes(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if !exists(a) || !exists(b) {
		t.Fatal("a dry run must not delete anything")
	}
	if !rep.DryRun || rep.Deleted != 0 || rep.FreedBytes != 0 || len(rep.Results) != 2 || rep.Results[0].Status != StatusDryRun {
		t.Errorf("unexpected dry-run report: %+v", rep)
	}
}

func TestApply_RecheckBlockSkipsTheItem(t *testing.T) {
	f, r, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	r.recheckErr = map[string]error{a: errors.New("a process started using it")}

	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if !exists(a) {
		t.Error("an item blocked at re-check time must stay")
	}
	if exists(b) {
		t.Error("the other item should still be deleted")
	}
	if rep.Skipped != 1 || rep.Deleted != 1 || rep.Results[0].Status != StatusSkipped || !strings.Contains(rep.Results[0].Reason, "a process started") {
		t.Errorf("unexpected report: %+v", rep)
	}
}

// The directory was planned, then replaced by a symlink to something precious before apply ran.
func TestApply_SymlinkSwappedInAfterPlanningIsNeverFollowed(t *testing.T) {
	f, _, a, _ := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)

	precious := f.sb.Home("precious", "keep.txt")
	f.sb.WriteFile(t, precious, 5, 0)
	if err := os.RemoveAll(a); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(precious), a); err != nil {
		t.Fatal(err)
	}

	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if !exists(precious) {
		t.Fatal("the symlink target was deleted")
	}
	if rep.Results[0].Status != StatusSkipped {
		t.Errorf("the swapped item must be skipped, got %+v", rep.Results[0])
	}
}

func TestApply_PolicyIsReCheckedAtApplyTime(t *testing.T) {
	f, _, _, _ := twoItemPlan(t)
	docs := f.sb.Home("Documents", "thesis")
	f.sb.WriteFile(t, filepath.Join(docs, "chapter.txt"), 5, 0)
	// a hand-made plan (for example loaded from elsewhere) that points at private data
	plan := &Plan{Items: []rules.Candidate{cand("deps", "Deps", docs, 5)}}

	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if !exists(filepath.Join(docs, "chapter.txt")) {
		t.Fatal("Apply must refuse paths the policy forbids even if they are in the plan")
	}
	if rep.Results[0].Status != StatusSkipped {
		t.Errorf("got %+v", rep.Results[0])
	}
}

func TestApply_ContinuesPastErrors(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	f.eng.Remove = func(path string) error {
		if path == a {
			return errors.New("permission denied")
		}
		return os.RemoveAll(path)
	}

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil {
		t.Fatalf("an item failure must not abort the run: %v", err)
	}
	if !exists(a) || exists(b) {
		t.Error("a must remain (failed) and b must be deleted")
	}
	if rep.Failed != 1 || rep.Deleted != 1 || rep.OK() {
		t.Errorf("unexpected report: %+v", rep)
	}
	if rep.Results[0].Status != StatusFailed || !strings.Contains(rep.Results[0].Reason, "permission denied") {
		t.Errorf("failure reason missing: %+v", rep.Results[0])
	}
}

func TestApply_SuccessfulRemoveThatLeavesThePathIsAFailure(t *testing.T) {
	f, _, a, _ := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	f.eng.Remove = func(path string) error { return nil } // claims success, deletes nothing

	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if !exists(a) || rep.Failed != 2 {
		t.Errorf("deletion must be verified: failed=%d", rep.Failed)
	}
}

func TestApply_AlreadyGoneIsSkipped(t *testing.T) {
	f, _, a, _ := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	if err := os.RemoveAll(a); err != nil {
		t.Fatal(err)
	}
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if rep.Results[0].Status != StatusSkipped || !strings.Contains(rep.Results[0].Reason, "already gone") {
		t.Errorf("got %+v", rep.Results[0])
	}
}

func TestApply_UnknownRuleFails(t *testing.T) {
	f, _, a, _ := twoItemPlan(t)
	plan := &Plan{Items: []rules.Candidate{cand("ghost", "G", a, 1)}}
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if !exists(a) || rep.Failed != 1 {
		t.Errorf("an item from an unknown rule must fail and delete nothing: %+v", rep)
	}
}

func TestApply_OnlyLimitsTheRules(t *testing.T) {
	f := newFixture(t)
	a := filepath.Dir(f.laneFile(t, "a", "node_modules/x", 10))
	b := filepath.Dir(f.laneFile(t, "b", "node_modules/y", 10))
	f.eng.Rules = []rules.Rule{
		&fakeRule{id: "one", group: "One", items: []rules.Candidate{cand("", "One", a, 1)}},
		&fakeRule{id: "two", group: "Two", items: []rules.Candidate{cand("", "Two", b, 1)}},
	}
	plan, _ := f.eng.Plan(ctx)
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{Only: []string{"two"}})
	if !exists(a) || exists(b) || len(rep.Results) != 1 {
		t.Errorf("only rule two should run: %+v", rep)
	}
}

// An executor reports the bytes it freed; a negative number means it cannot tell, and only then is the planned
// size used. "Freed nothing" is an answer and is believed.
func TestApply_AnExecutorThatCannotTellGetsThePlannedSizeButOneThatFreedNothingIsBelieved(t *testing.T) {
	for _, c := range []struct {
		name   string
		freed  int64
		wantFr int64
	}{{"cannot tell", -1, 7}, {"freed nothing", 0, 0}, {"freed something", 3, 3}} {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			item := rules.Candidate{Group: "Cmd", Path: "cmd: x", Bytes: 7, Tier: rules.TierSafe, Action: rules.ActionCommand}
			cr := commandRule{&fakeRule{id: "cmd", group: "Cmd", items: []rules.Candidate{item}}}
			cr.execFreed = c.freed
			f.eng.Rules = []rules.Rule{cr}
			plan, err := f.eng.Plan(ctx)
			if err != nil {
				t.Fatal(err)
			}
			rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
			if rep.Deleted != 1 || rep.FreedBytes != c.wantFr || rep.Results[0].FreedBytes != c.wantFr {
				t.Errorf("freed = %d (result %d), want %d: %+v", rep.FreedBytes, rep.Results[0].FreedBytes, c.wantFr, rep)
			}
		})
	}
}

func TestApply_CommandActionsGoThroughTheExecutor(t *testing.T) {
	f := newFixture(t)
	dev := f.sb.Home("Library", "Developer", "CoreSimulator", "Devices", "SOME-UDID")
	f.sb.WriteFile(t, filepath.Join(dev, "device.plist"), 1, 0)
	item := rules.Candidate{Group: "Sims", Path: dev, Bytes: 7, Tier: rules.TierSafe, Action: rules.ActionCommand}
	cr := commandRule{&fakeRule{id: "sims", group: "Sims", items: []rules.Candidate{item}}}
	cr.execFreed = 7
	f.eng.Rules = []rules.Rule{cr}

	plan, err := f.eng.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if len(cr.fakeRule.executed) != 1 || cr.fakeRule.executed[0] != dev {
		t.Errorf("the executor should have run once: %v", cr.fakeRule.executed)
	}
	if !exists(dev) {
		t.Error("the engine itself must not delete a command item; the executor does")
	}
	if rep.Deleted != 1 || rep.FreedBytes != 7 {
		t.Errorf("unexpected report: %+v", rep)
	}
}

func TestApply_CommandErrorIsAFailureAndRuleWithoutExecutorFails(t *testing.T) {
	f := newFixture(t)
	dev := f.sb.Home("Library", "Developer", "CoreSimulator", "Devices", "U")
	f.sb.WriteFile(t, filepath.Join(dev, "device.plist"), 1, 0)
	item := rules.Candidate{Group: "Sims", Path: dev, Tier: rules.TierSafe, Action: rules.ActionCommand}
	cr := commandRule{&fakeRule{id: "sims", group: "Sims", items: []rules.Candidate{item}, executeErr: errors.New("simctl: boom")}}
	f.eng.Rules = []rules.Rule{cr}
	plan, _ := f.eng.Plan(ctx)
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if rep.Failed != 1 || !strings.Contains(rep.Results[0].Reason, "boom") {
		t.Errorf("executor error should be a failure: %+v", rep)
	}

	plain := &fakeRule{id: "plain", group: "Plain", items: []rules.Candidate{item}}
	f.eng.Rules = []rules.Rule{plain}
	// a plain rule cannot plan a command item at all: that is a bug caught at planning time
	if _, err := f.eng.Plan(ctx); !errors.Is(err, ErrRuleBug) {
		t.Errorf("a command item from a rule without an Executor must be rejected, got %v", err)
	}
}

func TestApply_StopsOnContextCancellationWithAPartialReport(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	cctx, cancel := context.WithCancel(ctx)
	f.eng.Remove = func(path string) error {
		err := os.RemoveAll(path)
		cancel() // cancelled while the first item is being removed
		return err
	}
	rep, err := f.eng.Apply(cctx, plan, ApplyOptions{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
	if exists(a) || !exists(b) || rep.Deleted != 1 {
		t.Errorf("the first item is done and the second untouched: a=%v b=%v %+v", exists(a), exists(b), rep)
	}
}

func TestApply_ReportsFreeSpaceAndProgress(t *testing.T) {
	f, _, _, _ := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	calls := 0
	f.eng.Free = func() (string, int64, error) {
		calls++
		if calls == 1 {
			return "/v", 1000, nil
		}
		return "/v", 1500, nil
	}
	var seen []Status
	var mu sync.Mutex
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{OnResult: func(r Result) { mu.Lock(); seen = append(seen, r.Status); mu.Unlock() }})
	if rep.FreeBefore != 1000 || rep.FreeAfter != 1500 {
		t.Errorf("free space before/after = %d/%d", rep.FreeBefore, rep.FreeAfter)
	}
	if len(seen) != 2 || seen[0] != StatusDeleted {
		t.Errorf("progress callback should see every result: %v", seen)
	}
}

// ---- the test-time safety net ----

func TestDefaultRemove_RefusesNonTempPathsWhileTesting(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("removing a path outside a temp dir during a test must panic")
		}
	}()
	_ = defaultRemove("/Users/someone/Library/Caches/definitely-not-a-test-path")
}

func TestDefaultRemove_DeletesInsideTempDirs(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "victim")
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := defaultRemove(dir); err != nil || exists(dir) {
		t.Fatalf("a temp dir path should be removable: err=%v exists=%v", err, exists(dir))
	}
}

func TestRemove_SafetyNetAlsoCoversInjectedRemoveFunctions(t *testing.T) {
	f := newFixture(t)
	called := false
	f.eng.Remove = func(path string) error { called = true; return os.RemoveAll(path) }

	func() {
		defer func() {
			if recover() == nil {
				t.Error("an injected remove function must not run for a path outside a temp dir while testing")
			}
		}()
		_ = f.eng.remove("/Users/someone/Library/Caches/not-a-real-test-path")
	}()
	if called {
		t.Error("the injected function was called before the safety net stopped it")
	}

	// inside a temp dir the injected function is used
	dir := filepath.Join(t.TempDir(), "victim")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := f.eng.remove(dir); err != nil || !called || exists(dir) {
		t.Errorf("inside a temp dir the injected function should run: err=%v called=%v exists=%v", err, called, exists(dir))
	}
}

// ---- symlinks anywhere below the root ----

func TestPlan_RefusesATargetBelowASymlinkedFolder(t *testing.T) {
	f := newFixture(t)
	ssd := filepath.Join(f.sb.Root, "ssd", "x")
	f.sb.WriteFile(t, filepath.Join(ssd, "node_modules", "pkg"), 10, 0)
	if err := os.MkdirAll(f.sb.Home("lane-builds"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(ssd, f.sb.Home("lane-builds", "x")); err != nil {
		t.Fatal(err)
	}
	target := f.sb.Home("lane-builds", "x", "node_modules")
	f.eng.Rules = []rules.Rule{&fakeRule{id: "deps", group: "Deps", items: []rules.Candidate{cand("", "Deps", target, 1)}}}

	_, err := f.eng.Plan(ctx)
	if !errors.Is(err, ErrRuleBug) || !errors.Is(err, policy.ErrRefused) {
		t.Fatalf("a rule must never plan below a symlinked folder, got %v", err)
	}
}

// The lane was a real folder when planned; before apply ran it became a link to a real project.
func TestApply_ParentReplacedByASymlinkAfterPlanningIsNeverFollowed(t *testing.T) {
	f := newFixture(t)
	nm := filepath.Dir(f.laneFile(t, "x", "node_modules/pkg", 10))
	f.eng.Rules = []rules.Rule{&fakeRule{id: "deps", group: "Deps", items: []rules.Candidate{cand("", "Deps", nm, 10)}}}
	plan, err := f.eng.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}

	precious := f.sb.Home("precious", "x")
	f.sb.WriteFile(t, filepath.Join(precious, "node_modules", "keep.txt"), 5, 0)
	lane := f.sb.Home("lane-builds", "x")
	if err := os.RemoveAll(lane); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(precious, lane); err != nil {
		t.Fatal(err)
	}

	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if !exists(filepath.Join(precious, "node_modules", "keep.txt")) {
		t.Fatal("the real project behind the symlink was deleted")
	}
	if rep.Results[0].Status != StatusSkipped || !strings.Contains(rep.Results[0].Reason, "symbolic link") {
		t.Errorf("the item must be skipped because of the link: %+v", rep.Results[0])
	}
}
