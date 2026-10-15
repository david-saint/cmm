package cmd

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/ui"
)

// fakeTM stands in for the Time Machine module.
type fakeTM struct{ scanned, deleted int }

func (f *fakeTM) Name() string        { return "Time Machine Snapshots" }
func (f *fakeTM) Description() string { return "fake" }
func (f *fakeTM) Category() string    { return "Harsh" }
func (f *fakeTM) Scan() ([]cmm.FileItem, error) {
	f.scanned++
	return nil, nil
}
func (f *fakeTM) Delete([]cmm.FileItem) (cmm.DeleteResult, error) {
	f.deleted++
	return cmm.DeleteResult{}, nil
}

var (
	keyEnter = tea.KeyMsg{Type: tea.KeyEnter}
	keySpace = tea.KeyMsg{Type: tea.KeySpace}
	keyY     = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}}
	keyN     = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}}
)

// drive feeds keys to the interactive screen the way Bubble Tea would: every command the screen returns (the
// scan, the deletion) is run and its message handed back. It reports whether the screen asked to quit.
func drive(t *testing.T, m ui.Model, keys ...tea.Msg) (ui.Model, bool) {
	t.Helper()
	for _, k := range keys {
		next, cmd := m.Update(k)
		m = next.(ui.Model)
		for cmd != nil {
			msg := cmd()
			if _, quit := msg.(tea.QuitMsg); quit {
				return m, true
			}
			next, cmd = m.Update(msg)
			m = next.(ui.Model)
		}
	}
	return m, false
}

// screen is the interactive screen `cmm run` started; the test fails if it never started.
func (a *app) screen(t *testing.T) ui.Model {
	t.Helper()
	if a.model == nil {
		t.Fatal("the interactive screen was never started")
	}
	return *a.model
}

func (a *app) cachesIntact() bool { return present(a.goCache) && present(a.npmCache) }

// ---- the command ----

func TestRunCommand(t *testing.T) {
	runCmd := NewRunCmd(&deps{})
	if runCmd.Use != "run" {
		t.Errorf("expected Use 'run', got %q", runCmd.Use)
	}
	if runCmd.Short == "" || !strings.Contains(runCmd.Long, "--apply") {
		t.Errorf("the help must explain --apply: %q / %q", runCmd.Short, runCmd.Long)
	}
}

func TestRunFlags(t *testing.T) {
	runCmd := NewRunCmd(&deps{})
	for _, f := range []string{"apply", "dry-run"} {
		flag := runCmd.Flags().Lookup(f)
		if flag == nil {
			t.Fatalf("run needs --%s", f)
		}
		if flag.DefValue != "false" {
			t.Errorf("--%s must default to false, got %s", f, flag.DefValue)
		}
	}
	for _, gone := range []string{"force", "test-mode"} {
		if runCmd.Flags().Lookup(gone) != nil {
			t.Errorf("--%s must no longer exist: it fed or confirmed nothing", gone)
		}
	}
}

func TestRun_RemovedFlagsAreErrorsNotSilentNoOps(t *testing.T) {
	for _, flag := range []string{"--force", "--test-mode"} {
		a := newApp(t)
		o := a.run("", "run", flag)
		if o.err == nil || !strings.Contains(o.err.Error(), "unknown flag") {
			t.Errorf("%s: want an unknown-flag error, got %v", flag, o.err)
		}
		if a.uiRuns != 0 || !a.cachesIntact() {
			t.Errorf("%s: nothing may start or be deleted", flag)
		}
	}
}

// ---- preview is the default ----

func TestRun_IsAPreviewAndNeverDeletesUnlessApplied(t *testing.T) {
	a := newApp(t)
	if o := a.run("", "run"); o.err != nil {
		t.Fatalf("run failed: %v", o.err)
	}
	m := a.screen(t)
	view := m.View()
	for _, want := range []string{"PREVIEW ONLY", "Go build cache", "npm download cache", "Time Machine Snapshots"} {
		if !strings.Contains(view, want) {
			t.Errorf("the screen should show %q:\n%s", want, view)
		}
	}

	// the whole way through: pick the first module, scan it, look at the result, press Return
	_, quit := drive(t, m, keySpace, keyEnter, keyEnter)
	if !quit {
		t.Error("Return on the results ends a preview")
	}
	if !a.cachesIntact() {
		t.Fatal("a preview must delete nothing")
	}
	if a.tm.deleted != 0 || a.tm.scanned != 0 {
		t.Errorf("Time Machine was not picked: scanned=%d deleted=%d", a.tm.scanned, a.tm.deleted)
	}
}

func TestRun_DryRunWinsOverApply(t *testing.T) {
	a := newApp(t)
	a.tty = false // it cannot delete, so it needs no terminal for the question it will never ask
	if o := a.run("", "run", "--apply", "--dry-run"); o.err != nil {
		t.Fatalf("run failed: %v", o.err)
	}
	m := a.screen(t)
	if !strings.Contains(m.View(), "PREVIEW ONLY") {
		t.Error("--dry-run must make it a preview even with --apply")
	}
	if _, quit := drive(t, m, keySpace, keyEnter, keyEnter); !quit || !a.cachesIntact() {
		t.Errorf("a preview ends at the results and deletes nothing: quit=%v intact=%v", quit, a.cachesIntact())
	}
}

// ---- --apply: a human, and a deliberate answer ----

func TestRun_ApplyNeedsATerminalBeforeAnythingElseHappens(t *testing.T) {
	a := newApp(t)
	a.tty = false
	planned := 0
	inner := a.d.newEngine
	a.d.newEngine = func() (*engine.Engine, error) { planned++; return inner() }

	o := a.run("\n", "run", "--apply")
	if !errors.Is(o.err, errRunNeedsTerminal) {
		t.Fatalf("want errRunNeedsTerminal, got %v", o.err)
	}
	if a.uiRuns != 0 || planned != 0 || !a.cachesIntact() {
		t.Errorf("no plan, no screen, no deletion: screens=%d engines=%d intact=%v", a.uiRuns, planned, a.cachesIntact())
	}
}

func TestRun_ApplyDeletesOnlyWhatWasPickedAndConfirmed(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	if o := a.run("", "run", "--apply"); o.err != nil {
		t.Fatalf("run failed: %v", o.err)
	}
	m := a.screen(t)
	if strings.Contains(m.View(), "PREVIEW") {
		t.Error("with --apply the screen is not a preview")
	}

	m, quit := drive(t, m, keySpace, keyEnter, keyEnter) // pick the Go build cache, scan, go on
	if quit || !a.cachesIntact() {
		t.Fatalf("the question comes before any deletion: quit=%v intact=%v", quit, a.cachesIntact())
	}
	if view := m.View(); !strings.Contains(view, "CONFIRMATION REQUIRED") || !strings.Contains(view, "'y'") {
		t.Errorf("the screen must ask:\n%s", view)
	}

	m, _ = drive(t, m, keyY)
	if present(a.goCache) {
		t.Error("the Go build cache was picked and confirmed, so it should be gone")
	}
	if !present(a.npmCache) || a.tm.deleted != 0 {
		t.Error("only what was picked may be deleted")
	}
	view := m.View()
	for _, want := range []string{"Go build cache: freed", "Reclaimed"} {
		if !strings.Contains(view, want) {
			t.Errorf("the finished screen should contain %q:\n%s", want, view)
		}
	}
	log, err := os.ReadFile(j.LogPath())
	if err != nil || !strings.Contains(string(log), " deleted "+a.goCache+"\n") {
		t.Errorf("a real run through the screen is logged like any other apply: %v\n%s", err, log)
	}
}

func TestRun_ReturnNeverConfirmsADeletion(t *testing.T) {
	a := newApp(t)
	a.run("", "run", "--apply")
	m, quit := drive(t, a.screen(t), keySpace, keyEnter, keyEnter, keyEnter, keyEnter, keyEnter, keyEnter)
	if quit || !a.cachesIntact() {
		t.Fatalf("holding Return down must delete nothing: quit=%v intact=%v", quit, a.cachesIntact())
	}
	if !strings.Contains(m.View(), "CONFIRMATION REQUIRED") {
		t.Error("it should still be waiting for an answer")
	}
}

func TestRun_NoGoesBackWithoutDeleting(t *testing.T) {
	a := newApp(t)
	a.run("", "run", "--apply")
	m, _ := drive(t, a.screen(t), keySpace, keyEnter, keyEnter, keyN)
	if !a.cachesIntact() {
		t.Fatal("n must cancel")
	}
	if !strings.Contains(m.View(), "Scan Results") {
		t.Errorf("n goes back to the results:\n%s", m.View())
	}
}

// ---- what the screen offers ----

func TestRun_OffersThePlansGroupsThenTimeMachine(t *testing.T) {
	a := newApp(t)
	a.run("", "run")
	view := a.screen(t).View()
	i, j, k := strings.Index(view, "Go build cache"), strings.Index(view, "npm download cache"), strings.Index(view, "Time Machine Snapshots")
	if i < 0 || i >= j || j >= k {
		t.Errorf("the plan's groups come in plan order, Time Machine last:\n%s", view)
	}
	if strings.Contains(view, "Homebrew") || strings.Contains(view, "Simulators") {
		t.Errorf("a group the plan has nothing for is not offered:\n%s", view)
	}
	if !strings.Contains(view, "(Harsh)") {
		t.Errorf("Time Machine is flagged as harsh:\n%s", view)
	}
}

func TestRun_WithNothingPlannedOnlyTimeMachineIsOffered(t *testing.T) {
	a := newApp(t)
	for _, p := range []string{a.goCache, a.npmCache} {
		if err := os.RemoveAll(p); err != nil { // the sandbox's own folders
			t.Fatal(err)
		}
	}
	o := a.run("", "run")
	if o.err != nil || !strings.Contains(o.stderr, "Nothing to clean right now") {
		t.Errorf("it should say so: %v\n%s", o.err, o.stderr)
	}
	view := a.screen(t).View()
	if !strings.Contains(view, "Time Machine Snapshots") || strings.Contains(view, "Go build cache") {
		t.Errorf("only Time Machine remains:\n%s", view)
	}
}

func TestRun_ReportsEngineProblemsWithoutStartingTheScreen(t *testing.T) {
	a := newApp(t)
	a.d.newEngine = func() (*engine.Engine, error) { return nil, errors.New("no home directory") }
	if o := a.run("", "run"); o.err == nil || !strings.Contains(o.err.Error(), "no home directory") {
		t.Errorf("the engine problem must surface, got %v", o.err)
	}
	if a.uiRuns != 0 {
		t.Error("the screen must not start without an engine")
	}
}

func TestRun_SaysWhenTheLastCleanupWas(t *testing.T) {
	a := newApp(t)
	if err := a.withJournal().Stamp(); err != nil {
		t.Fatal(err)
	}
	a.sb.Advance(2 * 24 * time.Hour)
	if o := a.run("", "run"); !strings.Contains(o.stderr, "Last cleanup: 2026-10-14 (2 days ago)") {
		t.Errorf("run should say when the last cleanup was:\n%s", o.stderr)
	}
}

// ---- the adapter between the engine's plan and the screen ----

func planOf(t *testing.T, a *app) *engine.Plan {
	t.Helper()
	plan, err := a.eng.Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return plan
}

func TestEngineModules_OneModulePerRuleThatHasItems(t *testing.T) {
	a := newApp(t)
	mods := engineModules(context.Background(), a.eng, planOf(t, a))
	if len(mods) != 2 || mods[0].Name() != "Go build cache" || mods[1].Name() != "npm download cache" {
		t.Fatalf("modules = %v", mods)
	}
	if mods[0].Category() != "Recommended" {
		t.Errorf("safe items are 'Recommended', got %q", mods[0].Category())
	}
	items, err := mods[0].Scan()
	if err != nil || len(items) != 1 || items[0].Path != a.goCache || items[0].Size <= 0 {
		t.Errorf("Scan must list what the plan holds, with its size: %+v %v", items, err)
	}
}

func TestEngineModule_DeleteGoesThroughTheEngine(t *testing.T) {
	a := newApp(t)
	mods := engineModules(context.Background(), a.eng, planOf(t, a))
	items, _ := mods[0].Scan()

	res, err := mods[0].Delete(items)
	if err != nil || res.Freed <= 0 || res.Failed != 0 || res.Skipped != 0 {
		t.Fatalf("Delete() = %+v, %v", res, err)
	}
	if present(a.goCache) || !present(a.npmCache) {
		t.Errorf("only the Go build cache may go: go=%v npm=%v", present(a.goCache), present(a.npmCache))
	}
}

func TestEngineModule_RefusesAnythingThePlanDidNotContain(t *testing.T) {
	a := newApp(t)
	goMod := engineModules(context.Background(), a.eng, planOf(t, a))[0]
	home := a.sb.Env.Home

	for _, p := range []string{a.npmCache, home, a.sb.Home("Documents"), "/", a.goCache + "/data", ""} {
		if _, err := goMod.Delete([]cmm.FileItem{{Path: p}}); err == nil {
			t.Errorf("%q is not in this module's plan and must be refused", p)
		}
	}
	// one good item next to one bad one: nothing at all is deleted
	if _, err := goMod.Delete([]cmm.FileItem{{Path: a.goCache}, {Path: a.sb.Home("Documents")}}); err == nil {
		t.Error("a list with an unknown item must be refused as a whole")
	}
	if !a.cachesIntact() {
		t.Fatal("a refusal must leave everything where it was")
	}
}

func TestEngineModule_AnItemThatIsNoLongerSafeIsSkippedAndNotCountedAsFreed(t *testing.T) {
	a := newApp(t)
	goMod := engineModules(context.Background(), a.eng, planOf(t, a))[0]
	items, _ := goMod.Scan()
	a.sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-x", "go") // a go command started after the plan

	res, err := goMod.Delete(items)
	if err != nil {
		t.Fatalf("a skipped item is reported in the result, not as an error: %v", err)
	}
	if res.Skipped != 1 || res.Freed != 0 || res.Failed != 0 {
		t.Errorf("result = %+v", res)
	}
	if len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "skipped: ~/Library/Caches/go-build") {
		t.Errorf("the note should name the item (as ~/...) and say it was skipped: %q", res.Notes)
	}
	if !present(a.goCache) {
		t.Error("a skipped item stays")
	}
}

func TestEngineModule_AFailureIsReportedWithItsReason(t *testing.T) {
	a := newApp(t)
	a.eng.Remove = func(string) error { return errors.New("permission denied") }
	goMod := engineModules(context.Background(), a.eng, planOf(t, a))[0]
	items, _ := goMod.Scan()

	res, err := goMod.Delete(items)
	if err != nil || res.Failed != 1 || res.Freed != 0 {
		t.Fatalf("Delete() = %+v, %v", res, err)
	}
	if len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "FAILED: ~/Library/Caches/go-build") || !strings.Contains(res.Notes[0], "permission denied") {
		t.Errorf("notes = %q", res.Notes)
	}
}

func TestEngineModule_ProblemsWithTheCleanupLogAreNotesToo(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	a.sb.WriteFile(t, j.Dir, 1, 0) // a file where the state folder should be
	goMod := engineModules(context.Background(), a.eng, planOf(t, a))[0]
	items, _ := goMod.Scan()

	res, err := goMod.Delete(items)
	if err != nil || res.Freed <= 0 {
		t.Fatalf("the cleanup itself still works: %+v, %v", res, err)
	}
	joined := strings.Join(res.Notes, "\n")
	if !strings.Contains(joined, "warning: cleanup log:") {
		t.Errorf("the screen must hear about a log that could not be written:\n%s", joined)
	}
}

func TestEngineModule_OnlySafeItemsAreRecommended(t *testing.T) {
	safe := &engineModule{items: []rules.Candidate{{Tier: rules.TierSafe}}}
	mixed := &engineModule{items: []rules.Candidate{{Tier: rules.TierSafe}, {Tier: rules.TierReview}}}
	if safe.Category() != "Recommended" || mixed.Category() != "Harsh" {
		t.Errorf("categories = %q and %q", safe.Category(), mixed.Category())
	}
}

func TestEngineModule_CommandsAreListedAsSummaries(t *testing.T) {
	m := &engineModule{items: []rules.Candidate{
		{Path: "homebrew: cleanup", Bytes: 5, Action: rules.ActionCommand},
		{Path: "/x", Bytes: 1, Action: rules.ActionDelete},
	}}
	items, err := m.Scan()
	if err != nil || len(items) != 2 || items[0].Type != "summary" || items[1].Type != "dir" {
		t.Errorf("items = %+v, %v", items, err)
	}
}

// badRule plans something no rule may plan, so the engine refuses the whole plan.
type badRule struct{}

func (badRule) ID() string    { return "bad" }
func (badRule) Group() string { return "Bad" }
func (badRule) Plan(context.Context, rules.Deps) ([]rules.Candidate, []rules.Skip, error) {
	return []rules.Candidate{{Path: "/etc", Bytes: 1, Tier: rules.TierSafe, Action: rules.ActionDelete}}, nil, nil
}
func (badRule) Allows(rules.Deps, string) bool                             { return true }
func (badRule) Recheck(context.Context, rules.Deps, rules.Candidate) error { return nil }

func TestRun_AnEnginePlanThatIsRefusedStopsBeforeTheScreen(t *testing.T) {
	a := newApp(t)
	a.eng.Rules = []rules.Rule{badRule{}}
	o := a.run("", "run")
	if o.err == nil || !errors.Is(o.err, engine.ErrRuleBug) {
		t.Fatalf("a refused plan must surface as an error, got %v", o.err)
	}
	if a.uiRuns != 0 {
		t.Error("the screen must not start without a plan")
	}
}

func TestEngineModules_ItemsOfOneRuleShareAModule(t *testing.T) {
	plan := &engine.Plan{Items: []rules.Candidate{
		{Rule: "deps", Group: "Dependencies", Path: "/h/a/node_modules", Bytes: 3},
		{Rule: "go", Group: "Go build cache", Path: "/h/go-build", Bytes: 2},
		{Rule: "deps", Group: "Dependencies", Path: "/h/b/node_modules", Bytes: 1},
	}}
	mods := engineModules(context.Background(), nil, plan)
	if len(mods) != 2 || mods[0].Name() != "Dependencies" || mods[1].Name() != "Go build cache" {
		t.Fatalf("one module per rule, in the order the rules first appear: %v", mods)
	}
	if items, _ := mods[0].Scan(); len(items) != 2 || items[0].Path != "/h/a/node_modules" || items[1].Path != "/h/b/node_modules" {
		t.Errorf("both of the rule's items belong to its module, in plan order: %+v", items)
	}
}
