package rules

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

const day = 24 * time.Hour

func claudeRule() *VersionsRule { return claudeVersions() }

func versionPath(sb *systest.Sandbox, name string) string {
	return sb.Home(".local", "share", "claude", "versions", name)
}

// version creates one installed version (claude keeps single binaries) of the given age.
func version(t *testing.T, sb *systest.Sandbox, name string, age time.Duration) string {
	t.Helper()
	p := versionPath(sb, name)
	sb.WriteFile(t, p, 5000, age)
	return p
}

func linkBin(t *testing.T, sb *systest.Sandbox, tool, target string) string {
	t.Helper()
	l := sb.Home(".local", "bin", tool)
	if err := os.MkdirAll(filepath.Dir(l), 0o755); err != nil {
		t.Fatal(err)
	}
	_ = os.Remove(l)
	if err := os.Symlink(target, l); err != nil {
		t.Fatal(err)
	}
	return l
}

func lsofFree(sb *systest.Sandbox) { sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "lsof") }

func pathsOf(items []Candidate) map[string]bool {
	m := map[string]bool{}
	for _, c := range items {
		m[c.Path] = true
	}
	return m
}

func TestVersionsRule_KeepsNewestAndLinkedAndPlansTheRest(t *testing.T) {
	sb := systest.NewSandbox(t)
	v287 := version(t, sb, "2.1.287", 9*day)
	v292 := version(t, sb, "2.1.292", 6*day)
	v293 := version(t, sb, "2.1.293", 3*day)
	version(t, sb, "2.1.294", day) // newest
	linkBin(t, sb, "claude", v292) // the command on PATH still points at 2.1.292
	lsofFree(sb)

	items, skips, err := claudeRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	got := pathsOf(items)
	if len(items) != 2 || !got[v287] || !got[v293] {
		t.Fatalf("only 2.1.287 and 2.1.293 may go (294 is newest, 292 is linked): %+v", items)
	}
	for _, c := range items {
		if c.Group != "Old claude CLI versions" || c.Tier != TierSafe || c.Action != ActionDelete || c.Bytes <= 0 {
			t.Errorf("unexpected candidate %+v", c)
		}
	}
}

func TestVersionsRule_OnlyDigitNamedEntriesAreVersions(t *testing.T) {
	sb := systest.NewSandbox(t)
	old := version(t, sb, "2.1.287", 9*day)
	version(t, sb, "2.1.294", day)
	version(t, sb, "latest", 20*day) // not a version number
	version(t, sb, ".DS_Store", 20*day)
	lsofFree(sb)

	items, _, _ := claudeRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Path != old {
		t.Errorf("entries that do not start with a digit must be ignored: %+v", items)
	}
}

func TestVersionsRule_OneVersionMeansNothingToRemove(t *testing.T) {
	sb := systest.NewSandbox(t)
	version(t, sb, "2.1.294", day)
	if items, skips, _ := claudeRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 {
		t.Errorf("the only version is the newest: %v %v", items, skips)
	}
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("no command should run, ran %d", n)
	}
}

func TestVersionsRule_MissingFolderIsSilent(t *testing.T) {
	sb := systest.NewSandbox(t)
	if items, skips, err := claudeRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 || err != nil {
		t.Errorf("no versions folder, nothing to say: %v %v %v", items, skips, err)
	}
}

func TestVersionsRule_VersionInUseIsSkipped(t *testing.T) {
	sb := systest.NewSandbox(t)
	busy := version(t, sb, "2.1.287", 9*day)
	free := version(t, sb, "2.1.292", 6*day)
	version(t, sb, "2.1.294", day)
	sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nclaude 1 saint txt REG x\n"}, nil, "lsof", "-w", busy)
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", free)

	items, skips, _ := claudeRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Path != free {
		t.Errorf("the running version must stay: %+v", items)
	}
	if len(skips) != 1 || !strings.Contains(skips[0].Reason, "2.1.287") || !strings.Contains(skips[0].Reason, "in use") {
		t.Errorf("the skip should name the version: %+v", skips)
	}
}

func TestVersionsRule_AnUnanswerableInUseCheckFailsSafe(t *testing.T) {
	sb := systest.NewSandbox(t)
	version(t, sb, "2.1.287", 9*day)
	version(t, sb, "2.1.294", day)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 2}, nil, "lsof")

	items, skips, _ := claudeRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Errorf("an unanswered check must skip, not proceed: %v %v", items, skips)
	}
}

func TestVersionsRule_RelativeAndForeignLinks(t *testing.T) {
	sb := systest.NewSandbox(t)
	v287 := version(t, sb, "2.1.287", 9*day)
	v292 := version(t, sb, "2.1.292", 6*day)
	version(t, sb, "2.1.294", day)
	lsofFree(sb)

	// a relative link into this tool's versions counts
	linkBin(t, sb, "claude", "../share/claude/versions/2.1.292")
	// a link to ANOTHER tool's folder with the same version number must not protect claude's 2.1.287
	linkBin(t, sb, "cursor-agent", sb.Home(".local", "share", "cursor-agent", "versions", "2.1.287"))

	items, _, _ := claudeRule().Plan(ctx, depsFor(sb))
	got := pathsOf(items)
	if got[v292] || !got[v287] || len(items) != 1 {
		t.Errorf("the relative link protects 2.1.292 only: %+v", items)
	}
}

func TestVersionsRule_SymlinkedVersionIsSkipped(t *testing.T) {
	sb := systest.NewSandbox(t)
	version(t, sb, "2.1.294", day)
	real := filepath.Join(sb.Root, "elsewhere", "2.1.280")
	sb.WriteFile(t, real, 5000, 20*day)
	if err := os.Symlink(real, versionPath(sb, "2.1.280")); err != nil {
		t.Fatal(err)
	}
	lsofFree(sb)

	items, skips, _ := claudeRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) == 0 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Errorf("a symlinked version must be skipped with a reason: %v %v", items, skips)
	}
	if _, err := os.Stat(real); err != nil {
		t.Errorf("the link target must be untouched: %v", err)
	}
}

func TestVersionsRule_CursorAgentKeepsDirectories(t *testing.T) {
	sb := systest.NewSandbox(t)
	base := sb.Home(".local", "share", "cursor-agent", "versions")
	oldDir := filepath.Join(base, "2026.09.28-64d2043")
	sb.WriteFile(t, filepath.Join(oldDir, "bin", "cursor-agent"), 5000, 0)
	sb.Age(t, oldDir, 16*day)
	newDir := filepath.Join(base, "2026.10.01-14929f9")
	sb.WriteFile(t, filepath.Join(newDir, "bin", "cursor-agent"), 5000, 0)
	sb.Age(t, newDir, 13*day)
	linkBin(t, sb, "cursor-agent", filepath.Join(newDir, "cursor-agent"))
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", oldDir) // directories use +D

	items, _, err := cursorAgentVersions().Plan(ctx, depsFor(sb))
	if err != nil || len(items) != 1 || items[0].Path != oldDir || items[0].Group != "Old cursor-agent versions" {
		t.Errorf("the old directory goes, the new one stays: %+v %v", items, err)
	}
}

func TestVersionsRule_AllowsOnlyDigitNamedDirectChildren(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	r := claudeRule()
	root := sb.Home(".local", "share", "claude", "versions")
	if !r.Allows(d, filepath.Join(root, "2.1.287")) {
		t.Error("a version folder must be allowed")
	}
	for name, p := range map[string]string{
		"the versions folder": root,
		"parent":              sb.Home(".local", "share", "claude"),
		"non-version name":    filepath.Join(root, "latest"),
		"nested":              filepath.Join(root, "2.1.287", "bin"),
		"another tool":        sb.Home(".local", "share", "cursor-agent", "versions", "2.1.287"),
		"relative":            "2.1.287",
		"empty":               "",
		"bin link":            sb.Home(".local", "bin", "claude"),
	} {
		if r.Allows(d, p) {
			t.Errorf("%s (%q) must not be allowed", name, p)
		}
	}
}

// ---- Recheck: links and in-use state are read again, because an updater can relink between plan and apply ----

func TestVersionsRule_RecheckSeesALinkChangedAfterPlanning(t *testing.T) {
	sb := systest.NewSandbox(t)
	v287 := version(t, sb, "2.1.287", 9*day)
	v292 := version(t, sb, "2.1.292", 6*day)
	version(t, sb, "2.1.294", day)
	linkBin(t, sb, "claude", versionPath(sb, "2.1.294")) // PATH points at the newest when planning
	lsofFree(sb)
	r := claudeRule()
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if got := pathsOf(items); !got[v287] || !got[v292] {
		t.Fatalf("both older versions should be planned: %+v", items)
	}

	// an auto-update (or a rollback) now points the command at an older version we planned to delete
	linkBin(t, sb, "claude", v292)

	var c292 Candidate
	for _, c := range items {
		if c.Path == v292 {
			c292 = c
		}
	}
	if err := r.Recheck(ctx, depsFor(sb), c292); err == nil || !strings.Contains(err.Error(), "linked") {
		t.Errorf("the newly linked version must be blocked at re-check: %v", err)
	}
	for _, c := range items {
		if c.Path == v287 {
			if err := r.Recheck(ctx, depsFor(sb), c); err != nil {
				t.Errorf("the other old version is still fine: %v", err)
			}
		}
	}
}

func TestVersionsRule_RecheckSeesAVersionThatBecameTheNewest(t *testing.T) {
	sb := systest.NewSandbox(t)
	v287 := version(t, sb, "2.1.287", 9*day)
	version(t, sb, "2.1.294", 2*day)
	lsofFree(sb)
	r := claudeRule()
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 1 {
		t.Fatalf("setup: %+v", items)
	}
	sb.Age(t, v287, 0) // reinstalled just now: it is the newest again
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err == nil || !strings.Contains(err.Error(), "newest") {
		t.Errorf("a version that became the newest must be blocked: %v", err)
	}
}

func TestVersionsRule_RecheckSeesAVersionStartedAfterPlanning(t *testing.T) {
	sb := systest.NewSandbox(t)
	v287 := version(t, sb, "2.1.287", 9*day)
	version(t, sb, "2.1.294", day)
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", v287)
	r := claudeRule()
	items, _, _ := r.Plan(ctx, depsFor(sb))

	sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nclaude 9 saint txt REG x\n"}, nil, "lsof", "-w", v287)
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err == nil || !strings.Contains(err.Error(), "in use") {
		t.Errorf("a version started after planning must be blocked: %v", err)
	}

	sb.Runner.Stub(sys.Result{ExitCode: 3}, nil, "lsof", "-w", v287)
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err == nil {
		t.Error("an unanswerable check must block at re-check time too")
	}
}

func TestVersionsRule_RecheckFailsSafeWhenTheFolderCannotBeRead(t *testing.T) {
	sb := systest.NewSandbox(t)
	gone := Candidate{Path: versionPath(sb, "2.1.287")}
	if err := claudeRule().Recheck(ctx, depsFor(sb), gone); err == nil {
		t.Error("with no versions folder the item cannot be validated and must be blocked")
	}
}

func TestVersionsRule_Identity(t *testing.T) {
	if r := claudeVersions(); r.ID() != "claude-versions" || r.Group() != "Old claude CLI versions" {
		t.Errorf("claude identity wrong: %q %q", r.ID(), r.Group())
	}
	if r := cursorAgentVersions(); r.ID() != "cursor-agent-versions" || r.Group() != "Old cursor-agent versions" {
		t.Errorf("cursor-agent identity wrong: %q %q", r.ID(), r.Group())
	}
}
