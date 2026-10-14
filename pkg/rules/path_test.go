package rules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

var ctx = context.Background()

func depsFor(sb *systest.Sandbox) Deps {
	return Deps{Env: sb.Env, Guard: guard.New(sb.Env), Policy: policy.New(sb.Env)}
}

// a rule with a tiny threshold so tests do not need huge files
func testRule(block ...guard.ProcSpec) *PathRule {
	return &PathRule{
		RuleID:     "go-build",
		Label:      "Go build cache",
		Targets:    []string{"~/Library/Caches/go-build"},
		MinBytes:   1,
		Block:      block,
		BlockedMsg: "a go command is running",
	}
}

func writeTarget(t *testing.T, sb *systest.Sandbox, rel string, size int) string {
	t.Helper()
	p := sb.Home(rel)
	sb.WriteFile(t, filepath.Join(p, "data"), size, 0)
	return p
}

func pgrepNone(sb *systest.Sandbox)    { sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep") }
func pgrepRunning(sb *systest.Sandbox) { sb.Runner.StubPrefix(sys.Result{ExitCode: 0}, nil, "pgrep") }

func TestPathRule_PlansAnExistingTarget(t *testing.T) {
	sb := systest.NewSandbox(t)
	target := writeTarget(t, sb, "Library/Caches/go-build", 200_000)
	pgrepNone(sb)

	items, skips, err := testRule(guard.ProcSpec{Exact: "go"}).Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 || len(items) != 1 {
		t.Fatalf("Plan() = %v items, %v skips, %v", items, skips, err)
	}
	c := items[0]
	if c.Path != target || c.Group != "Go build cache" || c.Tier != TierSafe || c.Action != ActionDelete || c.Bytes < 200_000 {
		t.Errorf("unexpected candidate %+v", c)
	}
}

func TestPathRule_ExpandsTmpTemplates(t *testing.T) {
	sb := systest.NewSandbox(t)
	sb.WriteFile(t, sb.Tmp("jest_dx", "cache"), 10_000, 0)
	r := &PathRule{RuleID: "jest-temp", Label: "Jest temp cache", Targets: []string{"{tmp}/jest_dx"}, MinBytes: 1}

	items, _, err := r.Plan(ctx, depsFor(sb))
	if err != nil || len(items) != 1 || items[0].Path != sb.Tmp("jest_dx") {
		t.Fatalf("expected the temp-dir target, got %+v, %v", items, err)
	}
}

func TestPathRule_MissingTargetIsSilentAndRunsNoCommands(t *testing.T) {
	sb := systest.NewSandbox(t)
	items, skips, err := testRule(guard.ProcSpec{Exact: "go"}).Plan(ctx, depsFor(sb))
	if err != nil || len(items) != 0 || len(skips) != 0 {
		t.Fatalf("a missing target is not news: %v %v %v", items, skips, err)
	}
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("no guard command should run when there is nothing to clean, ran %d", n)
	}
}

func TestPathRule_TargetBelowMinimumIsSilentlyLeftOut(t *testing.T) {
	sb := systest.NewSandbox(t)
	writeTarget(t, sb, "Library/Caches/go-build", 100)
	r := testRule()
	r.MinBytes = 10 * 1024 * 1024
	items, skips, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 0 {
		t.Errorf("a small cache should not be listed: %v %v", items, skips)
	}
}

func TestPathRule_SymlinkTargetIsSkipped(t *testing.T) {
	sb := systest.NewSandbox(t)
	real := sb.Home("elsewhere")
	sb.WriteFile(t, filepath.Join(real, "f"), 100_000, 0)
	link := sb.Home("Library", "Caches", "go-build")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	items, skips, _ := testRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symlink") {
		t.Errorf("a symlink must be skipped with a reason: %v %v", items, skips)
	}
}

func TestPathRule_RunningProcessBlocksTheRule(t *testing.T) {
	sb := systest.NewSandbox(t)
	writeTarget(t, sb, "Library/Caches/go-build", 100_000)
	pgrepRunning(sb)

	items, skips, err := testRule(guard.ProcSpec{Exact: "go"}).Plan(ctx, depsFor(sb))
	if err != nil || len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "a go command is running") {
		t.Errorf("a running process must skip the rule with its message: %v %v %v", items, skips, err)
	}
}

func TestPathRule_AGuardThatCannotAnswerFailsSafe(t *testing.T) {
	sb := systest.NewSandbox(t)
	writeTarget(t, sb, "Library/Caches/go-build", 100_000)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 2}, nil, "pgrep")

	items, skips, _ := testRule(guard.ProcSpec{Exact: "go"}).Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Errorf("an unanswered process check must skip, not proceed: %v %v", items, skips)
	}
}

func TestPathRule_InUseCheck(t *testing.T) {
	sb := systest.NewSandbox(t)
	target := writeTarget(t, sb, "Library/Caches/go-build", 100_000)
	r := testRule()
	r.CheckInUse = true

	sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nuv 1 saint cwd DIR x\n"}, nil, "lsof", "-w", "+D", target)
	items, skips, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "files open") {
		t.Errorf("an in-use target must be skipped: %v %v", items, skips)
	}

	sb2 := systest.NewSandbox(t)
	target2 := writeTarget(t, sb2, "Library/Caches/go-build", 100_000)
	sb2.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", target2)
	if items, _, _ := r.Plan(ctx, depsFor(sb2)); len(items) != 1 {
		t.Errorf("a free target should be planned, got %v", items)
	}

	sb3 := systest.NewSandbox(t)
	target3 := writeTarget(t, sb3, "Library/Caches/go-build", 100_000)
	sb3.Runner.Stub(sys.Result{ExitCode: 2}, nil, "lsof", "-w", "+D", target3)
	items, skips, _ = r.Plan(ctx, depsFor(sb3))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Errorf("an unanswered in-use check must skip: %v %v", items, skips)
	}
}

func TestPathRule_MultipleTargets(t *testing.T) {
	sb := systest.NewSandbox(t)
	a := writeTarget(t, sb, "Library/Developer/Xcode/DerivedData/ModuleCache.noindex", 50_000)
	b := writeTarget(t, sb, "Library/Developer/Xcode/DerivedData/CompilationCache.noindex", 50_000)
	r := &PathRule{RuleID: "xcode-module-cache", Label: "Xcode caches", MinBytes: 1,
		Targets: []string{"~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex", "~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex"}}

	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 2 || items[0].Path != a || items[1].Path != b {
		t.Errorf("both targets should be planned in order: %+v", items)
	}
}

// ---- Allows: exactly the targets, never their parents, siblings or children ----

func TestPathRule_AllowsOnlyTheExactTargets(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	r := testRule()
	target := sb.Home("Library", "Caches", "go-build")

	if !r.Allows(d, target) {
		t.Error("the target itself must be allowed")
	}
	for name, p := range map[string]string{
		"parent":              sb.Home("Library", "Caches"),
		"grandparent":         sb.Home("Library"),
		"sibling":             sb.Home("Library", "Caches", "go-build-2"),
		"child":               target + "/sub",
		"home":                sb.Env.Home,
		"relative":            "Library/Caches/go-build",
		"dot-dot":             sb.Env.Home + "/Library/Caches/x/../go-build", // built by hand: filepath.Join would clean the ".." away
		"trailing slash":      target + "/",
		"empty":               "",
		"same name elsewhere": sb.Home("elsewhere", "go-build"),
	} {
		if r.Allows(d, p) {
			t.Errorf("%s: %q must not be allowed", name, p)
		}
	}
}

func TestPathRule_TemplatesMustStartWithTildeOrTmp(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	r := &PathRule{RuleID: "bad", Label: "Bad", MinBytes: 1, Targets: []string{"/etc", "relative", "~", "{tmp}", "$HOME/x", "../x"}}
	if items, skips, _ := r.Plan(ctx, d); len(items) != 0 || len(skips) != 0 {
		t.Errorf("malformed templates must be ignored: %v %v", items, skips)
	}
	for _, p := range []string{"/etc", "relative", sb.Env.Home, sb.Env.TmpDir} {
		if r.Allows(d, p) {
			t.Errorf("a malformed template must never allow %q", p)
		}
	}
}

func TestPathRule_EmptyTmpDirDropsTmpTemplates(t *testing.T) {
	sb := systest.NewSandbox(t)
	sb.Env.TmpDir = ""
	r := &PathRule{RuleID: "jest-temp", Label: "Jest", MinBytes: 1, Targets: []string{"{tmp}/jest_dx"}}
	if r.Allows(depsFor(sb), "/jest_dx") {
		t.Error("without a temp dir a {tmp} template must resolve to nothing, not to /jest_dx")
	}
}

// ---- Recheck: the guards run again right before deletion ----

func TestPathRule_RecheckRunsTheGuardsAgain(t *testing.T) {
	sb := systest.NewSandbox(t)
	target := writeTarget(t, sb, "Library/Caches/go-build", 100_000)
	r := testRule(guard.ProcSpec{Exact: "go"})
	r.CheckInUse = true
	c := Candidate{Rule: r.RuleID, Path: target, Tier: TierSafe, Action: ActionDelete}

	pgrepNone(sb)
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", target)
	if err := r.Recheck(ctx, depsFor(sb), c); err != nil {
		t.Errorf("all clear should pass: %v", err)
	}

	sb2 := systest.NewSandbox(t)
	t2 := writeTarget(t, sb2, "Library/Caches/go-build", 100_000)
	pgrepRunning(sb2)
	c.Path = t2
	if err := r.Recheck(ctx, depsFor(sb2), c); err == nil || !strings.Contains(err.Error(), "a go command is running") {
		t.Errorf("a process that started after planning must block: %v", err)
	}

	sb3 := systest.NewSandbox(t)
	t3 := writeTarget(t, sb3, "Library/Caches/go-build", 100_000)
	pgrepNone(sb3)
	sb3.Runner.Stub(sys.Result{Stdout: "COMMAND\nx 1\n"}, nil, "lsof", "-w", "+D", t3)
	c.Path = t3
	if err := r.Recheck(ctx, depsFor(sb3), c); err == nil {
		t.Error("a file opened after planning must block")
	}

	sb4 := systest.NewSandbox(t)
	t4 := writeTarget(t, sb4, "Library/Caches/go-build", 100_000)
	sb4.Runner.StubPrefix(sys.Result{ExitCode: 3}, nil, "pgrep")
	c.Path = t4
	if err := r.Recheck(ctx, depsFor(sb4), c); err == nil {
		t.Error("an unanswerable guard must block at re-check time too")
	}
}

func TestPathRule_IdentityAndTier(t *testing.T) {
	r := testRule()
	if r.ID() != "go-build" || r.Group() != "Go build cache" {
		t.Errorf("ID/Group wrong: %q %q", r.ID(), r.Group())
	}
	r.Tier = TierReview
	sb := systest.NewSandbox(t)
	writeTarget(t, sb, "Library/Caches/go-build", 1000)
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Tier != TierReview {
		t.Errorf("an explicit tier should be used: %+v", items)
	}
}
