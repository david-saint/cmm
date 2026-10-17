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

const (
	ddRel  = "Library/Developer/Xcode/DerivedData"
	hash28 = "abcdefghijklmnopqrstuvwxyzab"
)

func ddRule() *BuildFoldersRule { return staleDerivedData() }

func plistXML(ws string) string {
	return `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>WorkspacePath</key><string>` + ws +
		`</string><key>LastAccessedDate</key><integer>0</integer></dict></plist>`
}

// ddProject builds one DerivedData project folder aged `age`, recording ws as its workspace, and teaches the
// fake plutil to report that workspace.
func ddProject(t *testing.T, sb *systest.Sandbox, root, name, ws string, age time.Duration) string {
	t.Helper()
	dir := filepath.Join(root, name)
	sb.WriteFile(t, filepath.Join(dir, "Build", "Products", "obj"), 3000, 0)
	sb.WriteFile(t, filepath.Join(dir, "Logs", "Build", "a.xcactivitylog"), 500, 0)
	sb.WriteFile(t, filepath.Join(dir, "Index.noindex", "db"), 500, 0)
	plist := filepath.Join(dir, "info.plist")
	if err := os.WriteFile(plist, []byte(plistXML(ws)), 0o644); err != nil {
		t.Fatal(err)
	}
	sb.BackdateTree(t, dir, age)
	sb.Runner.Stub(sys.Result{Stdout: ws + "\n"}, nil, "plutil", "-extract", "WorkspacePath", "raw", plist)
	return dir
}

// existingWorkspace is a workspace path that really exists in the sandbox.
func existingWorkspace(t *testing.T, sb *systest.Sandbox, name string) string {
	t.Helper()
	ws := sb.Home("lane-builds", name, "ios", "App.xcworkspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	return ws
}

func TestBuildFolders_StaleProjectIsPlannedFreshOneIsNot(t *testing.T) {
	sb := systest.NewSandbox(t)
	root := sb.Home(ddRel)
	ws := existingWorkspace(t, sb, "lane")
	stale := ddProject(t, sb, root, "Stale-"+hash28, ws, 30*day)
	ddProject(t, sb, root, "Fresh-"+hash28, ws, time.Hour)
	lsofFree(sb)

	items, skips, err := ddRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	if len(items) != 1 || items[0].Path != stale {
		t.Fatalf("only the stale project may be planned: %+v", items)
	}
	c := items[0]
	if c.Group != "Stale Xcode build output (DerivedData)" || c.Tier != TierSafe || c.Action != ActionDelete || c.Bytes <= 0 {
		t.Errorf("unexpected candidate %+v", c)
	}
	if c.Note != "Stale: ~/lane-builds/lane/ios/App.xcworkspace (not used for 5+ days)" {
		t.Errorf("the note should name the project, its workspace and why: %q", c.Note)
	}
}

func TestBuildFolders_FiveDayLineIsExactToTheMinute(t *testing.T) {
	for name, c := range map[string]struct {
		age  time.Duration
		want bool
	}{
		"4.5 days is still in use": {108 * time.Hour, false},
		"5.5 days is idle":         {132 * time.Hour, true},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb, "lane"), c.age)
			lsofFree(sb)
			items, _, _ := ddRule().Plan(ctx, depsFor(sb))
			if (len(items) == 1) != c.want {
				t.Fatalf("planned=%v, want %v", len(items) == 1, c.want)
			}
		})
	}
}

func TestBuildFolders_WorkspaceGone(t *testing.T) {
	missing := func(sb *systest.Sandbox) string { return sb.Home("lane-builds", "deleted", "ios", "App.xcworkspace") }

	t.Run("gone for 4 days is stale", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, missing(sb), 4*day)
		lsofFree(sb)
		items, _, _ := ddRule().Plan(ctx, depsFor(sb))
		if len(items) != 1 || !strings.Contains(items[0].Note, "workspace no longer exists") {
			t.Fatalf("a project whose workspace is gone and untouched for 3+ days goes: %+v", items)
		}
	})
	t.Run("gone but touched a moment ago stays", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, missing(sb), time.Minute)
		if items, _, _ := ddRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
			t.Fatalf("recently touched must stay even if the workspace is gone: %+v", items)
		}
	})
	t.Run("gone and 2 days old stays", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, missing(sb), 2*day)
		if items, _, _ := ddRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
			t.Fatalf("under 3 days stays: %+v", items)
		}
	})
}

func TestBuildFolders_FreshProjectsRunNoCommands(t *testing.T) {
	sb := systest.NewSandbox(t)
	ddProject(t, sb, sb.Home(ddRel), "Fresh-"+hash28, existingWorkspace(t, sb, "lane"), time.Hour)
	ddRule().Plan(ctx, depsFor(sb))
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("a recently used project needs neither plutil nor lsof, ran %d commands", n)
	}
}

func TestBuildFolders_NestedActivityKeepsAProject(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb, "lane"), 30*day)
	sb.WriteFile(t, filepath.Join(dir, "Logs", "Build", "fresh.xcactivitylog"), 10, time.Hour) // info.plist is old, a log is new
	if items, _, _ := ddRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
		t.Fatalf("recent activity three levels down must keep the project: %+v", items)
	}
}

// withVolumes points the "external disks live here" folder at a sandbox for one test.
func withVolumes(t *testing.T, dir string) {
	t.Helper()
	old := volumesDir
	volumesDir = dir
	t.Cleanup(func() { volumesDir = old })
}

func TestBuildFolders_UnmountedVolumeIsSkippedWithAReason(t *testing.T) {
	sb := systest.NewSandbox(t)
	vols := filepath.Join(sb.Root, "Volumes")
	withVolumes(t, vols)
	dir := ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, filepath.Join(vols, "NOT MOUNTED", "x", "App.xcworkspace"), 30*day)
	lsofFree(sb)

	items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
	want := "its volume (" + filepath.Join(vols, "NOT MOUNTED") + ") is not mounted"
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, want) {
		t.Fatalf("an unmounted workspace volume must skip with a reason (%q): %v %v", want, items, skips)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Errorf("nothing must be touched: %v", err)
	}
}

func TestBuildFolders_WorkspaceOnAMountedVolumeIsJudgedNormally(t *testing.T) {
	sb := systest.NewSandbox(t)
	vols := filepath.Join(sb.Root, "Volumes")
	withVolumes(t, vols)
	ws := filepath.Join(vols, "SAINT SSD", "dev", "App.xcworkspace")
	if err := os.MkdirAll(ws, 0o755); err != nil {
		t.Fatal(err)
	}
	stale := ddProject(t, sb, sb.Home(ddRel), "Idle-"+hash28, ws, 30*day)
	ddProject(t, sb, sb.Home(ddRel), "Used-"+hash28, ws, 4*day) // 4 days old, workspace present: stays
	lsofFree(sb)

	items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
	if len(skips) != 0 || len(items) != 1 || items[0].Path != stale {
		t.Fatalf("a mounted volume must not block a stale folder: %v %v", items, skips)
	}
	if !strings.Contains(items[0].Note, filepath.Join(vols, "SAINT SSD", "dev", "App.xcworkspace")) {
		t.Errorf("a workspace outside the home folder is shown in full: %q", items[0].Note)
	}
}

func TestBuildFolders_OnlyProjectNamedFoldersWithAPlistAreCandidates(t *testing.T) {
	sb := systest.NewSandbox(t)
	root := sb.Home(ddRel)
	ws := existingWorkspace(t, sb, "lane")
	ok := ddProject(t, sb, root, "Good_Name.v2-"+hash28, ws, 30*day)
	for _, name := range []string{"Logs", "NotAProject-short", "ModuleCache.noindex", "SymbolCache.noindex", "Index.noindex",
		"Proj-" + strings.ToUpper(hash28), "Proj-" + hash28 + "x", "Proj-" + hash28[:27], hash28} {
		sb.WriteFile(t, filepath.Join(root, name, "data"), 100, 30*day)
		sb.BackdateTree(t, filepath.Join(root, name), 30*day)
	}
	// right name, but no info.plist: not an Xcode project folder
	noPlist := filepath.Join(root, "NoPlist-"+hash28)
	sb.WriteFile(t, filepath.Join(noPlist, "data"), 100, 0)
	sb.BackdateTree(t, noPlist, 30*day)
	lsofFree(sb)

	items, _, _ := ddRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Path != ok {
		t.Fatalf("only the well-formed project folder with an info.plist may be planned: %+v", items)
	}
}

func TestBuildFolders_UnreadableWorkspacePathSkips(t *testing.T) {
	for name, stub := range map[string]sys.Result{
		"plutil fails":  {ExitCode: 1},
		"empty output":  {Stdout: "\n"},
		"relative path": {Stdout: "App.xcworkspace\n"},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			dir := ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, "/placeholder", 30*day)
			sb.Runner.Stub(stub, nil, "plutil", "-extract", "WorkspacePath", "raw", filepath.Join(dir, "info.plist"))
			items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
			if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "workspace") {
				t.Fatalf("a folder whose workspace cannot be read must be skipped: %v %v", items, skips)
			}
		})
	}
}

func TestBuildFolders_InUseAndUnanswerableInUse(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb, "lane"), 30*day)
	sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nXcode 1 saint txt\n"}, nil, "lsof", "-w", "+D", dir)
	items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "in use") {
		t.Fatalf("an open folder must be skipped: %v %v", items, skips)
	}

	sb2 := systest.NewSandbox(t)
	dir2 := ddProject(t, sb2, sb2.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb2, "lane"), 30*day)
	sb2.Runner.Stub(sys.Result{ExitCode: 2}, nil, "lsof", "-w", "+D", dir2)
	items, skips, _ = ddRule().Plan(ctx, depsFor(sb2))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Fatalf("an unanswered in-use check must skip: %v %v", items, skips)
	}
}

func TestBuildFolders_UnreadableFolderFailsSafe(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read everything")
	}
	sb := systest.NewSandbox(t)
	dir := ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb, "lane"), 30*day)
	locked := filepath.Join(dir, "Build", "Products")
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0o755)
	lsofFree(sb)

	items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Fatalf("a folder whose recency cannot be established must be skipped: %v %v", items, skips)
	}
}

func TestBuildFolders_SymlinksAreNeverFollowed(t *testing.T) {
	sb := systest.NewSandbox(t)
	ws := existingWorkspace(t, sb, "lane")
	root := sb.Home(ddRel)
	real := ddProject(t, sb, filepath.Join(sb.Root, "ssd"), "P-"+hash28, ws, 30*day)
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(root, "Linked-"+hash28)); err != nil {
		t.Fatal(err)
	}
	lsofFree(sb)

	items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Fatalf("a symlinked project folder must be skipped with a reason: %v %v", items, skips)
	}
	if _, err := os.Stat(filepath.Join(real, "Build", "Products", "obj")); err != nil {
		t.Errorf("the real folder must be untouched: %v", err)
	}

	// the whole DerivedData root is a link to another disk: one skip for the root, not one per project
	sb2 := systest.NewSandbox(t)
	realRoot := filepath.Join(sb2.Root, "ssd", "DerivedData")
	ddProject(t, sb2, realRoot, "P-"+hash28, existingWorkspace(t, sb2, "lane"), 30*day)
	ddProject(t, sb2, realRoot, "Q-"+hash28, existingWorkspace(t, sb2, "lane"), 30*day)
	if err := os.MkdirAll(filepath.Dir(sb2.Home(ddRel)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realRoot, sb2.Home(ddRel)); err != nil {
		t.Fatal(err)
	}
	lsofFree(sb2)
	items, skips, _ = ddRule().Plan(ctx, depsFor(sb2))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Fatalf("a symlinked root must be skipped once, with a reason: %v %v", items, skips)
	}
}

func TestBuildFolders_UncheckableWorkspaceFailsSafe(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read everything")
	}
	sb := systest.NewSandbox(t)
	locked := sb.Home("locked")
	if err := os.MkdirAll(locked, 0o755); err != nil {
		t.Fatal(err)
	}
	// 4 days old: the workspace decides, and whether it exists cannot be found out
	ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, filepath.Join(locked, "App.xcworkspace"), 4*day)
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0o755)
	lsofFree(sb)

	items, skips, _ := ddRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "whether its workspace exists") {
		t.Fatalf("a workspace that cannot be looked up is not a missing workspace: %v %v", items, skips)
	}
}

func TestBuildFolders_MissingRootIsSilentAndRunsNothing(t *testing.T) {
	sb := systest.NewSandbox(t)
	if items, skips, err := ddRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 || err != nil {
		t.Errorf("no DerivedData folder, nothing to say: %v %v %v", items, skips, err)
	}
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("ran %d commands for nothing", n)
	}
}

func TestBuildFolders_AllowsOnlyProjectNamedDirectChildren(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	r := ddRule()
	root := sb.Home(ddRel)
	if !r.Allows(d, filepath.Join(root, "Conduxe-"+hash28)) {
		t.Error("a project folder must be allowed")
	}
	for name, p := range map[string]string{
		"the root":        root,
		"Logs":            filepath.Join(root, "Logs"),
		"module cache":    filepath.Join(root, "ModuleCache.noindex"),
		"nested":          filepath.Join(root, "Conduxe-"+hash28, "Build"),
		"short hash":      filepath.Join(root, "Conduxe-short"),
		"upper-case hash": filepath.Join(root, "Conduxe-"+strings.ToUpper(hash28)),
		"parent":          sb.Home("Library", "Developer", "Xcode"),
		"relative":        "Conduxe-" + hash28,
		"empty":           "",
		"dot-dot":         root + "/x/../Conduxe-" + hash28,
		"another folder":  sb.Home("lane-builds", "Conduxe-"+hash28),
	} {
		if r.Allows(d, p) {
			t.Errorf("%s (%q) must not be allowed", name, p)
		}
	}
}

func TestBuildFolders_RecheckSeesNewActivityAndOpenFiles(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := ddProject(t, sb, sb.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb, "lane"), 30*day)
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", dir)
	r := ddRule()
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 1 {
		t.Fatalf("setup: %+v", items)
	}
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err != nil {
		t.Errorf("unchanged, it should pass: %v", err)
	}

	sb.WriteFile(t, filepath.Join(dir, "Logs", "Build", "new.xcactivitylog"), 10, time.Minute) // a build ran after planning
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err == nil || !strings.Contains(err.Error(), "used again") {
		t.Errorf("a build after planning must block: %v", err)
	}

	sb2 := systest.NewSandbox(t)
	dir2 := ddProject(t, sb2, sb2.Home(ddRel), "P-"+hash28, existingWorkspace(t, sb2, "lane"), 30*day)
	sb2.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", dir2)
	items2, _, _ := r.Plan(ctx, depsFor(sb2))
	sb2.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nXcode 1 saint txt\n"}, nil, "lsof", "-w", "+D", dir2)
	if err := r.Recheck(ctx, depsFor(sb2), items2[0]); err == nil || !strings.Contains(err.Error(), "in use") {
		t.Errorf("a folder opened after planning must block: %v", err)
	}
}

func TestBuildFolders_Identity(t *testing.T) {
	if r := staleDerivedData(); r.ID() != "deriveddata-stale" || r.Group() != "Stale Xcode build output (DerivedData)" {
		t.Errorf("identity wrong: %q %q", r.ID(), r.Group())
	}
}
