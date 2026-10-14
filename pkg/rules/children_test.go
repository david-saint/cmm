package rules

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

const shipIt = "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"

func maestroRule() *ChildrenRule { return maestroTemp() }
func cursorRule() *ChildrenRule  { return cursorUpdate() }

func maestroDir(t *testing.T, sb *systest.Sandbox, name string, age time.Duration) string {
	t.Helper()
	p := sb.Tmp("maestro_xctestrunner_xcodebuild_output" + name)
	sb.WriteFile(t, filepath.Join(p, "build.log"), 1000, 0)
	sb.Age(t, p, age)
	return p
}

func TestChildrenRule_ListsOnlyMatchingOldChildren(t *testing.T) {
	sb := systest.NewSandbox(t)
	old1 := maestroDir(t, sb, "111", 3*time.Hour)
	old2 := maestroDir(t, sb, "222", 5*time.Hour)
	maestroDir(t, sb, "333", 10*time.Minute)                            // too young
	sb.WriteFile(t, sb.Tmp("other_dir", "x"), 100, 5*time.Hour)         // wrong name
	sb.WriteFile(t, filepath.Join(old1, "nested_maestro_x", "y"), 1, 0) // nested, never a candidate itself
	sb.Age(t, old1, 3*time.Hour)                                        // writing inside touched it: age it again
	pgrepNone(sb)

	items, skips, err := maestroRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	if len(items) != 2 || items[0].Path != old1 || items[1].Path != old2 {
		t.Fatalf("only the two old matching directories should be planned: %+v", items)
	}
	for _, c := range items {
		if c.Group != "Maestro test output (older than 1 hour)" || c.Tier != TierSafe || c.Action != ActionDelete || c.Bytes <= 0 {
			t.Errorf("unexpected candidate %+v", c)
		}
	}
}

// BSD find -mmin +60 means strictly more than 60 minutes; this works in exact minutes.
func TestChildrenRule_AgeBoundaryIsExactMinutes(t *testing.T) {
	sb := systest.NewSandbox(t)
	young := maestroDir(t, sb, "young", 59*time.Minute)
	exactly := maestroDir(t, sb, "exact", 60*time.Minute)
	older := maestroDir(t, sb, "older", 61*time.Minute)
	pgrepNone(sb)

	items, _, _ := maestroRule().Plan(ctx, depsFor(sb))
	got := map[string]bool{}
	for _, c := range items {
		got[c.Path] = true
	}
	if got[young] || got[exactly] || !got[older] {
		t.Errorf("59 and 60 minutes stay, 61 goes: %v", got)
	}
}

func TestChildrenRule_AlsoFilesOnlyWhenAMatchExists(t *testing.T) {
	// a staged update and the updater's state file
	sb := systest.NewSandbox(t)
	update := sb.Home(shipIt, "update.maiIqDe")
	state := sb.Home(shipIt, "ShipItState.plist")
	sb.WriteFile(t, filepath.Join(update, "Cursor.app", "bin"), 5000, 0)
	sb.WriteFile(t, state, 300, 0)
	sb.WriteFile(t, sb.Home(shipIt, "ShipIt_stderr.log"), 100, 0) // never claimed
	pgrepNone(sb)

	items, _, _ := cursorRule().Plan(ctx, depsFor(sb))
	paths := map[string]bool{}
	for _, c := range items {
		paths[c.Path] = true
	}
	if len(items) != 2 || !paths[update] || !paths[state] {
		t.Errorf("the update folder and the state file should be planned, nothing else: %+v", items)
	}

	// no staged update: the state file alone is not worth touching
	sb2 := systest.NewSandbox(t)
	sb2.WriteFile(t, sb2.Home(shipIt, "ShipItState.plist"), 300, 0)
	pgrepNone(sb2)
	if items, _, _ := cursorRule().Plan(ctx, depsFor(sb2)); len(items) != 0 {
		t.Errorf("the state file alone must not be planned: %+v", items)
	}
}

func TestChildrenRule_NothingToCleanRunsNoCommands(t *testing.T) {
	sb := systest.NewSandbox(t)
	if items, skips, _ := maestroRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 {
		t.Errorf("nothing there, nothing to say: %v %v", items, skips)
	}
	maestroDir(t, sb, "young", time.Minute) // present but too young: still nothing to clean
	maestroRule().Plan(ctx, depsFor(sb))
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("guards must not run when nothing qualifies, ran %d commands", n)
	}
}

func TestChildrenRule_RunningToolSkipsTheWholeRule(t *testing.T) {
	sb := systest.NewSandbox(t)
	maestroDir(t, sb, "1", 3*time.Hour)
	pgrepRunning(sb)
	items, skips, _ := maestroRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "Maestro or xcodebuild is running") {
		t.Errorf("a running tool must skip the rule: %v %v", items, skips)
	}
}

func TestChildrenRule_AGuardThatCannotAnswerFailsSafe(t *testing.T) {
	sb := systest.NewSandbox(t)
	maestroDir(t, sb, "1", 3*time.Hour)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 2}, nil, "pgrep")
	items, skips, _ := maestroRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Errorf("an unanswered guard must skip: %v %v", items, skips)
	}
}

func TestChildrenRule_SymlinkedChildAndSymlinkedRootAreSkipped(t *testing.T) {
	sb := systest.NewSandbox(t)
	pgrepNone(sb)
	real := filepath.Join(sb.Root, "elsewhere", "precious")
	sb.WriteFile(t, filepath.Join(real, "f"), 100, 0)
	l := sb.Tmp("maestro_xctestrunner_xcodebuild_outputLINK")
	if err := os.Symlink(real, l); err != nil {
		t.Fatal(err)
	}
	sb.Age(t, real, 5*time.Hour)

	items, skips, _ := maestroRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Errorf("a symlinked child must be skipped with a reason: %v %v", items, skips)
	}

	// the folder that holds the staged update is itself a link to another disk
	sb2 := systest.NewSandbox(t)
	pgrepNone(sb2)
	realShip := filepath.Join(sb2.Root, "ssd", "ShipIt")
	sb2.WriteFile(t, filepath.Join(realShip, "update.abc", "x"), 5000, 0)
	if err := os.MkdirAll(sb2.Home("Library", "Caches"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realShip, sb2.Home(shipIt)); err != nil {
		t.Fatal(err)
	}
	items, skips, _ = cursorRule().Plan(ctx, depsFor(sb2))
	if len(items) != 0 || len(skips) == 0 {
		t.Errorf("children below a symlinked root must be skipped: %v %v", items, skips)
	}
	if _, err := os.Stat(filepath.Join(realShip, "update.abc", "x")); err != nil {
		t.Errorf("the real folder must be untouched: %v", err)
	}
}

func TestChildrenRule_MinBytes(t *testing.T) {
	sb := systest.NewSandbox(t)
	maestroDir(t, sb, "tiny", 3*time.Hour)
	pgrepNone(sb)
	r := maestroRule()
	r.MinBytes = 10 * 1024 * 1024
	if items, _, _ := r.Plan(ctx, depsFor(sb)); len(items) != 0 {
		t.Errorf("a child below MinBytes should be left out: %+v", items)
	}
}

func TestChildrenRule_AllowsOnlyDirectMatchingChildren(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	m := maestroRule()
	c := cursorRule()
	root := sb.Home(shipIt)

	if !m.Allows(d, sb.Tmp("maestro_xctestrunner_xcodebuild_output123")) {
		t.Error("a matching child of the temp dir must be allowed")
	}
	for name, p := range map[string]string{
		"the temp dir itself": sb.Env.TmpDir,
		"non-matching name":   sb.Tmp("something_else"),
		"nested match":        sb.Tmp("a", "maestro_xctestrunner_xcodebuild_output1"),
		"grandchild":          sb.Tmp("maestro_xctestrunner_xcodebuild_output1", "inner"),
		"relative":            "maestro_xctestrunner_xcodebuild_output1",
		"empty":               "",
		"dot-dot":             sb.Env.TmpDir + "/x/../maestro_xctestrunner_xcodebuild_output1",
	} {
		if m.Allows(d, p) {
			t.Errorf("maestro: %s (%q) must not be allowed", name, p)
		}
	}

	for _, ok := range []string{filepath.Join(root, "update.abc"), filepath.Join(root, "ShipItState.plist")} {
		if !c.Allows(d, ok) {
			t.Errorf("cursor: %q must be allowed", ok)
		}
	}
	for name, p := range map[string]string{
		"the root":         root,
		"log file":         filepath.Join(root, "ShipIt_stderr.log"),
		"inside update":    filepath.Join(root, "update.abc", "Cursor.app"),
		"parent":           sb.Home("Library", "Caches"),
		"update lookalike": filepath.Join(root, "updates"),
	} {
		if c.Allows(d, p) {
			t.Errorf("cursor: %s (%q) must not be allowed", name, p)
		}
	}
}

func TestChildrenRule_RootTemplates(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)

	bad := &ChildrenRule{RuleID: "bad", Label: "Bad", Pattern: "*", MinBytes: 0}
	for _, root := range []string{"", "/etc", "relative", "~", "{tmp}/x", "../x", "$HOME"} {
		bad.Root = root
		if items, skips, _ := bad.Plan(ctx, d); len(items) != 0 || len(skips) != 0 {
			t.Errorf("root %q is not a valid template and must plan nothing", root)
		}
		if bad.Allows(d, "/etc/passwd") || bad.Allows(d, sb.Env.Home+"/x") {
			t.Errorf("root %q must never allow anything", root)
		}
	}

	sb.Env.TmpDir = ""
	if maestroRule().Allows(depsFor(sb), "/maestro_xctestrunner_xcodebuild_output1") {
		t.Error("without a temp dir {tmp} must resolve to nothing, not to /")
	}
}

func TestChildrenRule_RecheckRunsGuardsAndAgeAgain(t *testing.T) {
	sb := systest.NewSandbox(t)
	old := maestroDir(t, sb, "1", 3*time.Hour)
	r := maestroRule()
	c := Candidate{Rule: r.RuleID, Path: old, Tier: TierSafe, Action: ActionDelete}

	pgrepNone(sb)
	if err := r.Recheck(ctx, depsFor(sb), c); err != nil {
		t.Errorf("all clear should pass: %v", err)
	}

	sb.Age(t, old, time.Minute) // a run touched it after planning
	if err := r.Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "changed") {
		t.Errorf("a child that became recent must be blocked: %v", err)
	}

	sb2 := systest.NewSandbox(t)
	old2 := maestroDir(t, sb2, "2", 3*time.Hour)
	pgrepRunning(sb2)
	if err := r.Recheck(ctx, depsFor(sb2), Candidate{Path: old2}); err == nil || !strings.Contains(err.Error(), "Maestro or xcodebuild is running") {
		t.Errorf("a tool started after planning must block: %v", err)
	}
}

func TestChildrenRule_IdentityAndManyChildren(t *testing.T) {
	sb := systest.NewSandbox(t)
	pgrepNone(sb)
	for i := 0; i < 60; i++ {
		maestroDir(t, sb, fmt.Sprintf("%03d", i), 2*time.Hour)
	}
	r := maestroRule()
	if r.ID() != "maestro-temp" || r.Group() != "Maestro test output (older than 1 hour)" {
		t.Errorf("ID/Group wrong: %q %q", r.ID(), r.Group())
	}
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 60 {
		t.Errorf("every old child is its own item: got %d", len(items))
	}
}
