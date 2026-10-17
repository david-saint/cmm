package rules_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

var ctx = context.Background()

func engineFor(sb *systest.Sandbox, rs []rules.Rule) *engine.Engine {
	e := engine.New(rules.Deps{Env: sb.Env, Guard: guard.New(sb.Env), Policy: policy.New(sb.Env)}, rs)
	e.Free = func() (string, int64, error) { return "/sandbox", 1 << 30, nil }
	return e
}

// pathRules keeps only the fixed-folder rules (the caches); the tests below seed nothing else.
func pathRules(rs []rules.Rule) []rules.Rule {
	var out []rules.Rule
	for _, r := range rs {
		if _, ok := r.(*rules.PathRule); ok {
			out = append(out, r)
		}
	}
	return out
}

func TestBuiltin_Definitions(t *testing.T) {
	const mb = 1 << 20
	byID := map[string]*rules.PathRule{}
	for _, r := range rules.Builtin() {
		pr, ok := r.(*rules.PathRule)
		if !ok {
			continue // other kinds are tested with their own rules
		}
		if _, dup := byID[pr.ID()]; dup {
			t.Fatalf("duplicate rule id %s", pr.ID())
		}
		byID[pr.ID()] = pr
	}

	want := map[string]struct {
		targets []string
		min     int64
		inUse   bool
	}{
		"go-build":           {[]string{"~/Library/Caches/go-build"}, 50 * mb, false},
		"npm-cache":          {[]string{"~/.npm/_cacache"}, 50 * mb, false},
		"cocoapods":          {[]string{"~/Library/Caches/CocoaPods"}, 50 * mb, false},
		"bun-cache":          {[]string{"~/.bun/install/cache"}, 50 * mb, false},
		"uv-cache":           {[]string{"~/.cache/uv"}, 50 * mb, true},
		"jest-temp":          {[]string{"{tmp}/jest_dx"}, 50 * mb, false},
		"xcode-module-cache": {[]string{"~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex", "~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex"}, 100 * mb, false},
	}
	for id, w := range want {
		r, ok := byID[id]
		if !ok {
			t.Errorf("built-in rule %s is missing", id)
			continue
		}
		if len(r.Targets) != len(w.targets) {
			t.Errorf("%s targets = %v, want %v", id, r.Targets, w.targets)
			continue
		}
		for i := range w.targets {
			if r.Targets[i] != w.targets[i] {
				t.Errorf("%s target %d = %q, want %q", id, i, r.Targets[i], w.targets[i])
			}
		}
		if r.MinBytes != w.min || r.CheckInUse != w.inUse || r.Tier != "" && r.Tier != rules.TierSafe {
			t.Errorf("%s: min=%d inUse=%v tier=%q", id, r.MinBytes, r.CheckInUse, r.Tier)
		}
		if len(r.Block) == 0 {
			t.Errorf("%s must have process guards", id)
		}
		if r.BlockedMsg == "" || r.Label == "" {
			t.Errorf("%s needs a label and a blocked message", id)
		}
	}
	if len(byID) != len(want) {
		t.Errorf("unexpected built-in path rules: have %d, expected %d", len(byID), len(want))
	}
}

// dev-cleanup's rules come first, in its order; rules only cmm has (Docker) follow.
func TestBuiltin_OrderMatchesDevCleanup(t *testing.T) {
	var ids []string
	for _, r := range rules.Builtin() {
		ids = append(ids, r.ID())
	}
	want := []string{
		"simulators", "deriveddata-stale", "xcode-module-cache",
		"go-build", "npm-cache", "cocoapods", "bun-cache", "uv-cache", "jest-temp", "maestro-temp",
		"cursor-update", "claude-versions", "cursor-agent-versions",
		"lane-deps", "lane-build-output", "lane-local-build",
		"homebrew",
		"docker",
	}
	if strings.Join(ids, " ") != strings.Join(want, " ") {
		t.Fatalf("rule order =\n%v\nwant\n%v", ids, want)
	}
}

func TestBuiltin_EveryRuleHasADistinctIdAndAGroup(t *testing.T) {
	seen := map[string]bool{}
	for _, r := range rules.Builtin() {
		if r.ID() == "" || r.Group() == "" {
			t.Errorf("rule %T needs an id and a group", r)
		}
		if seen[r.ID()] {
			t.Errorf("duplicate rule id %s", r.ID())
		}
		seen[r.ID()] = true
	}
}

func TestBuiltin_TheSizeThresholdAppliesToTheLanesToo(t *testing.T) {
	const mb = 1 << 20
	for _, r := range rules.Builtin() {
		if l, ok := r.(*rules.LaneRule); ok && l.MinBytes != 50*mb {
			t.Errorf("%s: lanes leave out anything under 50 MB, got %d", l.ID(), l.MinBytes)
		}
	}
	for _, r := range rules.BuiltinWithMin(7, 9) {
		if l, ok := r.(*rules.LaneRule); ok && l.MinBytes != 7 {
			t.Errorf("%s: BuiltinWithMin must set the lane threshold to the cache one, got %d", l.ID(), l.MinBytes)
		}
	}
}

// Everything at once, through the real engine, inside a sandbox: plan, then apply.
func seedAllCaches(t *testing.T, sb *systest.Sandbox) map[string]string {
	t.Helper()
	paths := map[string]string{
		"go-build":      sb.Home("Library/Caches/go-build"),
		"npm-cache":     sb.Home(".npm/_cacache"),
		"cocoapods":     sb.Home("Library/Caches/CocoaPods"),
		"bun-cache":     sb.Home(".bun/install/cache"),
		"uv-cache":      sb.Home(".cache/uv"),
		"module-cache":  sb.Home("Library/Developer/Xcode/DerivedData/ModuleCache.noindex"),
		"compile-cache": sb.Home("Library/Developer/Xcode/DerivedData/CompilationCache.noindex"),
		"jest-temp":     sb.Tmp("jest_dx"),
	}
	for _, p := range paths {
		sb.WriteFile(t, filepath.Join(p, "data"), 20_000, 0)
	}
	return paths
}

func TestBuiltin_EndToEndInASandbox(t *testing.T) {
	sb := systest.NewSandbox(t)
	paths := seedAllCaches(t, sb)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep") // nothing running
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", paths["uv-cache"])

	e := engineFor(sb, pathRules(rules.BuiltinWithMin(1, 1)))
	plan, err := e.Plan(ctx)
	if err != nil {
		t.Fatalf("Plan() failed: %v", err)
	}
	if len(plan.Items) != len(paths) || len(plan.Skipped) != 0 {
		t.Fatalf("expected %d items and no skips, got %d items, skips %v", len(paths), len(plan.Items), plan.Skipped)
	}
	if len(plan.Groups) != 7 { // the two Xcode caches share a group
		t.Errorf("expected 7 groups, got %d: %+v", len(plan.Groups), plan.Groups)
	}

	rep, err := e.Apply(ctx, plan, engine.ApplyOptions{})
	if err != nil || !rep.OK() || rep.Deleted != len(paths) {
		t.Fatalf("Apply() = %+v, %v", rep, err)
	}
	for name, p := range paths {
		if _, err := os.Lstat(p); err == nil {
			t.Errorf("%s should have been deleted: %s", name, p)
		}
	}
	// the parents the rules never claimed must survive
	for _, keep := range []string{sb.Home("Library/Caches"), sb.Home("Library/Developer/Xcode/DerivedData"), sb.Home(".cache"), sb.Env.TmpDir} {
		if _, err := os.Stat(keep); err != nil {
			t.Errorf("parent %s must remain: %v", keep, err)
		}
	}
}

func TestBuiltin_ARunningToolOnlyBlocksItsOwnRule(t *testing.T) {
	sb := systest.NewSandbox(t)
	paths := seedAllCaches(t, sb)
	sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-x", "go") // a go command is running
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep")
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", paths["uv-cache"])

	e := engineFor(sb, pathRules(rules.BuiltinWithMin(1, 1)))
	plan, err := e.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range plan.Items {
		if it.Rule == "go-build" {
			t.Error("go-build must be skipped while go runs")
		}
	}
	if len(plan.Items) != len(paths)-1 || len(plan.Skipped) != 1 || plan.Skipped[0].Rule != "go-build" {
		t.Errorf("only go-build should be skipped: items=%d skips=%v", len(plan.Items), plan.Skipped)
	}
}

func TestBuiltin_DryRunLeavesEverythingInPlace(t *testing.T) {
	sb := systest.NewSandbox(t)
	paths := seedAllCaches(t, sb)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep")
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", paths["uv-cache"])

	e := engineFor(sb, pathRules(rules.BuiltinWithMin(1, 1)))
	plan, _ := e.Plan(ctx)
	rep, _ := e.Apply(ctx, plan, engine.ApplyOptions{DryRun: true})
	if rep.Deleted != 0 {
		t.Errorf("a dry run deleted %d items", rep.Deleted)
	}
	for name, p := range paths {
		if _, err := os.Lstat(p); err != nil {
			t.Errorf("%s vanished during a dry run: %v", name, err)
		}
	}
}

func TestBuiltin_TheSizeThresholdAppliesToDockerToo(t *testing.T) {
	find := func(rs []rules.Rule) *rules.DockerRule {
		for _, r := range rs {
			if d, ok := r.(*rules.DockerRule); ok {
				return d
			}
		}
		t.Fatal("the docker rule is not registered")
		return nil
	}
	if got := find(rules.BuiltinWithMin(7, 9)).MinBytes; got != 7 {
		t.Errorf("the cache threshold passed in is Docker's too: %d", got)
	}
	if got := find(rules.Builtin()).MinBytes; got != 50<<20 {
		t.Errorf("by default Docker needs 50 MB to be worth an item: %d", got)
	}
}
