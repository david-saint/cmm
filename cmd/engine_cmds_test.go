package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"

	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
	"github.com/david-saint/cmm/pkg/ui"
)

// app is a whole cmm in a sandbox: two real caches to clean, a fake runner, a pretend terminal.
type app struct {
	sb       *systest.Sandbox
	eng      *engine.Engine
	d        *deps
	tty      bool
	goCache  string
	npmCache string

	tm     *fakeTM   // stands in for the Time Machine module: no test may call the real tmutil
	model  *ui.Model // the interactive screen, as handed to the runner by `cmm run`
	uiRuns int
}

func newApp(t *testing.T) *app {
	t.Helper()
	sb := systest.NewSandbox(t)
	a := &app{sb: sb, tty: true}
	a.goCache = sb.Home("Library/Caches/go-build")
	a.npmCache = sb.Home(".npm/_cacache")
	sb.WriteFile(t, filepath.Join(a.goCache, "data"), 40_000, 0)
	sb.WriteFile(t, filepath.Join(a.npmCache, "data"), 90_000, 0)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep")                                      // nothing is running
	sb.Runner.StubPrefix(sys.Result{}, &exec.Error{Name: "docker", Err: exec.ErrNotFound}, "docker") // no Docker here

	a.eng = engine.New(rules.Deps{Env: sb.Env, Guard: guard.New(sb.Env), Policy: policy.New(sb.Env)}, rules.BuiltinWithMin(1, 1))
	a.eng.Free = func() (string, int64, error) { return "/sandbox", 5 << 30, nil }
	a.tm = &fakeTM{}
	a.d = &deps{
		newEngine:   func() (*engine.Engine, error) { return a.eng, nil },
		isTerminal:  func() bool { return a.tty },
		timeMachine: func() cmm.Module { return a.tm },
		runUI: func(_ *cobra.Command, m ui.Model) error {
			a.uiRuns++
			a.model = &m
			return nil
		},
	}
	return a
}

type outcome struct {
	stdout, stderr string
	err            error
}

func (a *app) run(input string, args ...string) outcome {
	cmd := newRootCmd(a.d)
	var out, errOut bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&errOut)
	cmd.SetIn(strings.NewReader(input))
	cmd.SetArgs(args)
	err := cmd.Execute()
	return outcome{stdout: out.String(), stderr: errOut.String(), err: err}
}

func present(p string) bool { _, err := os.Lstat(p); return err == nil }

// ---- plan ----

func TestPlan_HumanOutputListsGroupsTotalsAndNeverDeletes(t *testing.T) {
	a := newApp(t)
	o := a.run("", "plan")
	if o.err != nil {
		t.Fatalf("plan failed: %v", o.err)
	}
	for _, want := range []string{"Go build cache", "npm download cache", "TOTAL"} {
		if !strings.Contains(o.stdout, want) {
			t.Errorf("plan output should mention %q:\n%s", want, o.stdout)
		}
	}
	if !present(a.goCache) || !present(a.npmCache) {
		t.Fatal("plan must never delete anything")
	}
}

func TestPlan_JSONIsPureOnStdout(t *testing.T) {
	a := newApp(t)
	o := a.run("", "plan", "--json")
	if o.err != nil {
		t.Fatalf("plan --json failed: %v", o.err)
	}
	var plan engine.Plan
	if err := json.Unmarshal([]byte(o.stdout), &plan); err != nil {
		t.Fatalf("stdout must be exactly one JSON document: %v\n%s", err, o.stdout)
	}
	if plan.SchemaVersion != engine.SchemaVersion || len(plan.Items) != 2 || plan.TotalBytes <= 0 {
		t.Errorf("unexpected plan: %+v", plan)
	}
}

func TestPlan_ShowsSkippedGuardsAndWorksWithoutATerminal(t *testing.T) {
	a := newApp(t)
	a.tty = false
	a.sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-x", "go") // go is running
	o := a.run("", "plan")
	if o.err != nil {
		t.Fatalf("plan needs no terminal: %v", o.err)
	}
	if !strings.Contains(o.stdout, "SKIPPED") || !strings.Contains(o.stdout, "a go command is running") {
		t.Errorf("the skipped section should explain the guard:\n%s", o.stdout)
	}
	if strings.Contains(o.stdout, "Go build cache  ") && strings.Contains(o.stdout, a.goCache) {
		t.Errorf("a skipped cache must not appear in the plan:\n%s", o.stdout)
	}
}

func TestPlan_ShortensTheHomeDirectoryInPaths(t *testing.T) {
	a := newApp(t)
	o := a.run("", "plan", "-v")
	if strings.Contains(o.stdout, a.sb.Env.Home) || !strings.Contains(o.stdout, "~/Library/Caches/go-build") {
		t.Errorf("paths should be shown as ~/...:\n%s", o.stdout)
	}
}

func TestPlan_EngineFailureIsReported(t *testing.T) {
	a := newApp(t)
	a.d.newEngine = func() (*engine.Engine, error) { return nil, errors.New("no home directory") }
	if o := a.run("", "plan"); o.err == nil || !strings.Contains(o.err.Error(), "no home directory") {
		t.Errorf("an engine setup failure must surface, got %v", o.err)
	}
}

// ---- apply: nothing is deleted without a human ----

func TestApply_DryRunNeverDeletesAndNeedsNoTerminal(t *testing.T) {
	a := newApp(t)
	a.tty = false
	o := a.run("", "apply", "--dry-run")
	if o.err != nil {
		t.Fatalf("apply --dry-run failed: %v", o.err)
	}
	if !present(a.goCache) || !present(a.npmCache) {
		t.Fatal("--dry-run deleted something")
	}
	if !strings.Contains(o.stdout, "Dry run") || strings.Contains(o.stdout, "Press Return") {
		t.Errorf("dry run should say so and never prompt:\n%s", o.stdout)
	}
}

func TestApply_WithoutATerminalRefusesAndDeletesNothing(t *testing.T) {
	a := newApp(t)
	a.tty = false
	o := a.run("\n", "apply") // even if a newline is sitting on stdin
	if o.err == nil || !errors.Is(o.err, errNoTerminal) {
		t.Fatalf("want errNoTerminal, got %v", o.err)
	}
	if !present(a.goCache) || !present(a.npmCache) {
		t.Fatal("nothing may be deleted without a terminal")
	}
	if strings.Contains(o.stdout, "Press Return") {
		t.Error("it must not even show the prompt")
	}
}

func TestApply_EndOfInputAtThePromptCancels(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply") // terminal, but Ctrl-D / EOF right away
	if o.err == nil || !errors.Is(o.err, errCancelled) {
		t.Fatalf("want errCancelled, got %v", o.err)
	}
	if !present(a.goCache) || !present(a.npmCache) {
		t.Fatal("EOF at the prompt must cancel")
	}
}

func TestApply_AnythingButReturnCancels(t *testing.T) {
	for _, input := range []string{"n\n", "no\n", "y\n", "yes\n", "delete\n", " x \n"} {
		a := newApp(t)
		o := a.run(input, "apply")
		if !errors.Is(o.err, errCancelled) {
			t.Errorf("input %q: want errCancelled, got %v", input, o.err)
		}
		if !present(a.goCache) {
			t.Errorf("input %q deleted something", input)
		}
	}
}

func TestApply_ReturnAtTheTerminalDeletes(t *testing.T) {
	a := newApp(t)
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	if present(a.goCache) || present(a.npmCache) {
		t.Error("both caches should have been deleted")
	}
	for _, want := range []string{"Press Return", "deleted 2", "Free space"} {
		if !strings.Contains(o.stdout, want) {
			t.Errorf("output should contain %q:\n%s", want, o.stdout)
		}
	}
}

func TestApply_YesSkipsThePromptEvenWithoutATerminal(t *testing.T) {
	a := newApp(t)
	a.tty = false
	o := a.run("", "apply", "--yes")
	if o.err != nil {
		t.Fatalf("apply --yes failed: %v", o.err)
	}
	if present(a.goCache) || present(a.npmCache) {
		t.Error("--yes should delete")
	}
	if strings.Contains(o.stdout, "Press Return") {
		t.Error("--yes must not prompt")
	}
}

func TestApply_YesWithDryRunStillNeverDeletes(t *testing.T) {
	a := newApp(t)
	if o := a.run("", "apply", "--yes", "--dry-run"); o.err != nil {
		t.Fatal(o.err)
	}
	if !present(a.goCache) {
		t.Fatal("--dry-run wins over --yes")
	}
}

func TestApply_OnlyLimitsTheRules(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--only", "go-build")
	if o.err != nil {
		t.Fatal(o.err)
	}
	if present(a.goCache) || !present(a.npmCache) {
		t.Errorf("only go-build should be deleted (go=%v npm=%v)", present(a.goCache), present(a.npmCache))
	}
}

func TestApply_UnknownOnlyRuleIsAnErrorAndDeletesNothing(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--only", "go-bulid")
	if o.err == nil || !strings.Contains(o.err.Error(), "go-bulid") || !strings.Contains(o.err.Error(), "go-build") {
		t.Errorf("a typo should be rejected and the known ids listed, got %v", o.err)
	}
	if !present(a.goCache) {
		t.Fatal("nothing may be deleted when the arguments are wrong")
	}
}

func TestApply_NothingToCleanNeedsNoTerminalAndNoPrompt(t *testing.T) {
	a := newApp(t)
	a.tty = false
	if err := os.RemoveAll(a.goCache); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(a.npmCache); err != nil {
		t.Fatal(err)
	}
	o := a.run("", "apply")
	if o.err != nil || !strings.Contains(o.stdout, "Nothing to clean") {
		t.Errorf("nothing to do is a success: err=%v\n%s", o.err, o.stdout)
	}
}

func TestApply_AFailedItemMakesTheCommandFail(t *testing.T) {
	a := newApp(t)
	a.eng.Remove = func(path string) error {
		if path == a.goCache {
			return errors.New("operation not permitted")
		}
		return os.RemoveAll(path)
	}
	o := a.run("\n", "apply")
	if o.err == nil || !errors.Is(o.err, errItemsFailed) {
		t.Fatalf("a failed item must give a non-zero exit, got %v", o.err)
	}
	if !present(a.goCache) || present(a.npmCache) {
		t.Error("the failed item stays and the other one is still deleted")
	}
	if !strings.Contains(o.stdout, "FAILED") || !strings.Contains(o.stdout, "operation not permitted") {
		t.Errorf("the failure and its reason must be printed:\n%s", o.stdout)
	}
}

func TestApply_ReportsSkippedItems(t *testing.T) {
	a := newApp(t)
	// go starts running after planning: the re-check at apply time must catch it
	calls := 0
	a.eng.Rules = wrapRecheck(a.eng.Rules, "go-build", func() error {
		calls++
		return errors.New("Go build cache: a go command is running")
	})
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("a skipped item is not a failure: %v", o.err)
	}
	if !present(a.goCache) || present(a.npmCache) || calls != 1 {
		t.Errorf("go-build must be skipped at re-check (go=%v npm=%v calls=%d)", present(a.goCache), present(a.npmCache), calls)
	}
	if !strings.Contains(o.stdout, "skipped 1") {
		t.Errorf("the summary should count the skip:\n%s", o.stdout)
	}
}

// recheckRule wraps a rule so a test can make its Recheck fail.
type recheckRule struct {
	rules.Rule
	fail func() error
}

func (r recheckRule) Recheck(ctx context.Context, d rules.Deps, c rules.Candidate) error {
	if err := r.fail(); err != nil {
		return err
	}
	return r.Rule.Recheck(ctx, d, c)
}

func wrapRecheck(rs []rules.Rule, id string, fail func() error) []rules.Rule {
	out := make([]rules.Rule, len(rs))
	for i, r := range rs {
		out[i] = r
		if r.ID() == id {
			out[i] = recheckRule{Rule: r, fail: fail}
		}
	}
	return out
}

// ---- flags ----

func TestEngineCommands_Flags(t *testing.T) {
	root := newRootCmd(newApp(t).d)
	plan, _, err := root.Find([]string{"plan"})
	if err != nil || plan.Flags().Lookup("json") == nil || plan.Flags().Lookup("verbose") == nil {
		t.Errorf("plan needs --json and --verbose: %v", err)
	}
	apply, _, err := root.Find([]string{"apply"})
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"dry-run", "yes", "only"} {
		if apply.Flags().Lookup(f) == nil {
			t.Errorf("apply needs --%s", f)
		}
	}
	if v, _ := apply.Flags().GetBool("yes"); v {
		t.Error("--yes must default to false")
	}
	if v, _ := apply.Flags().GetBool("dry-run"); v {
		t.Error("--dry-run defaults to false because apply already asks for Return; it never deletes silently")
	}
}
