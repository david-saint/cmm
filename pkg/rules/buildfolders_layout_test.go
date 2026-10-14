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

func laneRule() *BuildFoldersRule { return laneLocalBuildFolders() }

// laneDD builds a folder made by `xcodebuild -derivedDataPath` directly under ~/lane-builds. ddProject already
// lays out info.plist, Build/, Logs/ and Index.noindex/.
func laneDD(t *testing.T, sb *systest.Sandbox, name, ws string, age time.Duration) string {
	t.Helper()
	return ddProject(t, sb, sb.Home("lane-builds"), name, ws, age)
}

func TestLaneLocal_Identity(t *testing.T) {
	r := laneLocalBuildFolders()
	if r.ID() != "lane-local-build" || r.Group() != "Stale lane-local Xcode build folders" {
		t.Errorf("identity wrong: %q %q", r.ID(), r.Group())
	}
}

func TestLaneLocal_StaleFolderIsPlannedAnyNameWorks(t *testing.T) {
	sb := systest.NewSandbox(t)
	ws := existingWorkspace(t, sb, "mlp-ios")
	stale := laneDD(t, sb, "mlp-ios-dd", ws, 30*day)
	laneDD(t, sb, "fresh-dd", ws, time.Hour)
	lsofFree(sb)

	items, skips, err := laneRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	if len(items) != 1 || items[0].Path != stale {
		t.Fatalf("only the stale folder may be planned: %+v", items)
	}
	c := items[0]
	if c.Group != "Stale lane-local Xcode build folders" || c.Tier != TierSafe || c.Action != ActionDelete || c.Bytes <= 0 {
		t.Errorf("unexpected candidate %+v", c)
	}
	if c.Note != "mlp-ios-dd: ~/lane-builds/mlp-ios/ios/App.xcworkspace (not used for 5+ days)" {
		t.Errorf("the note should name the folder, its workspace and why: %q", c.Note)
	}
}

func TestLaneLocal_SameStalenessAsDerivedData(t *testing.T) {
	missing := func(sb *systest.Sandbox) string { return sb.Home("lane-builds", "gone", "App.xcworkspace") }
	for name, c := range map[string]struct {
		age     time.Duration
		missing bool
		want    string // substring of the note; empty: stays
	}{
		"4.5 days with its workspace stays":     {108 * time.Hour, false, ""},
		"5.5 days is idle":                      {132 * time.Hour, false, "not used for 5+ days"},
		"workspace gone for 4 days":             {4 * day, true, "workspace no longer exists"},
		"workspace gone but touched 2 days ago": {2 * day, true, ""},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			ws := existingWorkspace(t, sb, "lane")
			if c.missing {
				ws = missing(sb)
			}
			laneDD(t, sb, "dd", ws, c.age)
			lsofFree(sb)
			items, _, _ := laneRule().Plan(ctx, depsFor(sb))
			switch {
			case c.want == "" && len(items) != 0:
				t.Fatalf("must stay: %+v", items)
			case c.want != "" && (len(items) != 1 || !strings.Contains(items[0].Note, c.want)):
				t.Fatalf("must be planned because %q: %+v", c.want, items)
			}
		})
	}
}

func TestLaneLocal_LanesAndLookAlikesAreNotBuildFolders(t *testing.T) {
	ws := func(t *testing.T, sb *systest.Sandbox) string { return existingWorkspace(t, sb, "lane") }
	remove := func(rel ...string) func(*testing.T, *systest.Sandbox, string) {
		return func(t *testing.T, _ *systest.Sandbox, dir string) {
			if err := os.RemoveAll(filepath.Join(append([]string{dir}, rel...)...)); err != nil {
				t.Fatal(err)
			}
		}
	}
	cases := map[string]func(t *testing.T, sb *systest.Sandbox, dir string){
		"package.json: it is a lane": func(t *testing.T, sb *systest.Sandbox, dir string) {
			sb.WriteFile(t, filepath.Join(dir, "package.json"), 10, 0)
		},
		"package.json that is a dangling link": func(t *testing.T, _ *systest.Sandbox, dir string) {
			if err := os.Symlink(filepath.Join(dir, "nowhere"), filepath.Join(dir, "package.json")); err != nil {
				t.Fatal(err)
			}
		},
		".git: it is a checkout": func(t *testing.T, _ *systest.Sandbox, dir string) {
			if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
				t.Fatal(err)
			}
		},
		"no info.plist": remove("info.plist"),
		"info.plist is a folder": func(t *testing.T, _ *systest.Sandbox, dir string) {
			remove("info.plist")(t, nil, dir)
			if err := os.MkdirAll(filepath.Join(dir, "info.plist"), 0o755); err != nil {
				t.Fatal(err)
			}
		},
		"no Build": remove("Build"),
		"Build is a file": func(t *testing.T, sb *systest.Sandbox, dir string) {
			remove("Build")(t, sb, dir)
			sb.WriteFile(t, filepath.Join(dir, "Build"), 10, 0)
		},
		"neither Index.noindex nor Logs": func(t *testing.T, sb *systest.Sandbox, dir string) {
			remove("Index.noindex")(t, sb, dir)
			remove("Logs")(t, sb, dir)
		},
		"workspace path unreadable": func(t *testing.T, sb *systest.Sandbox, dir string) {
			sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "plutil", "-extract", "WorkspacePath", "raw", filepath.Join(dir, "info.plist"))
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			dir := laneDD(t, sb, "look-alike", ws(t, sb), 30*day)
			lsofFree(sb)
			mutate(t, sb, dir)
			sb.BackdateTree(t, dir, 30*day) // the change must not make it look fresh
			items, skips, _ := laneRule().Plan(ctx, depsFor(sb))
			if len(items) != 0 || len(skips) != 0 {
				t.Fatalf("not a build folder: it must be ignored silently: %v %v", items, skips)
			}
			if laneRule().Allows(depsFor(sb), dir) {
				t.Errorf("not a build folder: it must not be allowed")
			}
		})
	}

	t.Run("control: the same folder without the change is planned and allowed", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		dir := laneDD(t, sb, "look-alike", ws(t, sb), 30*day)
		lsofFree(sb)
		if items, _, _ := laneRule().Plan(ctx, depsFor(sb)); len(items) != 1 || items[0].Path != dir {
			t.Fatalf("setup: %+v", items)
		}
		if !laneRule().Allows(depsFor(sb), dir) {
			t.Error("setup: a layout folder must be allowed")
		}
	})
}

func TestLaneLocal_EitherIndexOrLogsIsEnough(t *testing.T) {
	for _, gone := range []string{"Index.noindex", "Logs"} {
		t.Run("without "+gone, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			dir := laneDD(t, sb, "dd", existingWorkspace(t, sb, "lane"), 30*day)
			if err := os.RemoveAll(filepath.Join(dir, gone)); err != nil {
				t.Fatal(err)
			}
			sb.BackdateTree(t, dir, 30*day)
			lsofFree(sb)
			if items, _, _ := laneRule().Plan(ctx, depsFor(sb)); len(items) != 1 {
				t.Fatalf("a folder with Build and info.plist plus one of Index.noindex/Logs is a build folder: %+v", items)
			}
		})
	}
}

func TestLaneLocal_RealLanesNextToABuildFolderAreLeftAlone(t *testing.T) {
	sb := systest.NewSandbox(t)
	ws := existingWorkspace(t, sb, "lane")
	dd := laneDD(t, sb, "mlp-ios-dd", ws, 30*day)
	lane := sb.Home("lane-builds", "mlp-ios")
	sb.WriteFile(t, filepath.Join(lane, "package.json"), 20, 30*day)
	sb.WriteFile(t, filepath.Join(lane, "src", "App.tsx"), 200, 30*day)
	sb.WriteFile(t, filepath.Join(lane, "node_modules", "x", "i.js"), 5000, 30*day)
	sb.BackdateTree(t, lane, 30*day)
	sb.WriteFile(t, sb.Home("lane-builds", "notes.txt"), 10, 30*day)
	lsofFree(sb)

	items, skips, _ := laneRule().Plan(ctx, depsFor(sb))
	if len(skips) != 0 || len(items) != 1 || items[0].Path != dd {
		t.Fatalf("only the build folder may be planned: %v %v", items, skips)
	}
}

func TestLaneLocal_AllowsOnlyDirectChildrenWithTheLayout(t *testing.T) {
	sb := systest.NewSandbox(t)
	dd := laneDD(t, sb, "mlp-ios-dd", existingWorkspace(t, sb, "lane"), 30*day)
	d := depsFor(sb)
	r := laneRule()
	if !r.Allows(d, dd) {
		t.Fatal("a layout folder under ~/lane-builds must be allowed")
	}
	lane := sb.Home("lane-builds", "some-lane")
	sb.WriteFile(t, filepath.Join(lane, "package.json"), 10, 30*day)
	nested := ddProject(t, sb, lane, "mlp-ios-dd", existingWorkspace(t, sb, "lane"), 30*day) // a real layout folder, one level too deep
	for name, p := range map[string]string{
		"the root":                 sb.Home("lane-builds"),
		"a lane":                   lane,
		"missing":                  sb.Home("lane-builds", "does-not-exist"),
		"inside the build folder":  filepath.Join(dd, "Build"),
		"deeper":                   filepath.Join(dd, "Build", "Products"),
		"a layout folder nested":   nested,
		"the parent":               sb.Home(),
		"outside ~/lane-builds":    filepath.Join(sb.Root, "mlp-ios-dd"),
		"DerivedData-style folder": sb.Home("Library", "Developer", "Xcode", "DerivedData", "mlp-ios-dd"),
		"relative":                 "mlp-ios-dd",
		"empty":                    "",
		"dot-dot":                  sb.Home("lane-builds") + "/x/../mlp-ios-dd", // Join would clean it away
	} {
		if r.Allows(d, p) {
			t.Errorf("%s (%q) must not be allowed", name, p)
		}
	}
	// the content test is repeated every time: a lane that appears inside the folder after planning is refused
	sb.WriteFile(t, filepath.Join(dd, "package.json"), 10, 0)
	if r.Allows(d, dd) {
		t.Error("a folder that gained a package.json is a lane now")
	}
}

func TestLaneLocal_NameAloneIsNotEnoughHere(t *testing.T) {
	sb := systest.NewSandbox(t)
	// named exactly like an Xcode project folder, but nothing inside says it is one
	p := sb.Home("lane-builds", "Conduxe-"+hash28)
	sb.WriteFile(t, filepath.Join(p, "src", "a.txt"), 10, 30*day)
	sb.BackdateTree(t, p, 30*day)
	if laneRule().Allows(depsFor(sb), p) {
		t.Error("the layout flavour decides by content, not by name")
	}
	// and the reverse: the DerivedData flavour decides by name, not by content
	q := sb.Home(ddRel, "mlp-ios-dd")
	ddProject(t, sb, sb.Home(ddRel), "mlp-ios-dd", existingWorkspace(t, sb, "lane"), 30*day)
	if ddRule().Allows(depsFor(sb), q) {
		t.Error("the DerivedData flavour decides by name, not by content")
	}
}

func TestLaneLocal_SymlinksAreNeverFollowed(t *testing.T) {
	sb := systest.NewSandbox(t)
	ws := existingWorkspace(t, sb, "lane")
	real := ddProject(t, sb, filepath.Join(sb.Root, "ssd"), "dd", ws, 30*day)
	if err := os.MkdirAll(sb.Home("lane-builds"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := sb.Home("lane-builds", "linked-dd")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	// make the link answer exactly like the real folder, so only the rule's own link check can refuse it
	sb.Runner.Stub(sys.Result{Stdout: ws + "\n"}, nil, "plutil", "-extract", "WorkspacePath", "raw", filepath.Join(link, "info.plist"))
	lsofFree(sb)

	items, skips, _ := laneRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 0 {
		t.Fatalf("a link in ~/lane-builds is nothing this rule knows about: %v %v", items, skips)
	}
	if laneRule().Allows(depsFor(sb), link) {
		t.Error("a link must not be allowed")
	}
	if _, err := os.Stat(filepath.Join(real, "Build", "Products", "obj")); err != nil {
		t.Errorf("the real folder must be untouched: %v", err)
	}

	// ~/lane-builds itself is a link to another disk: one skip, nothing planned
	sb2 := systest.NewSandbox(t)
	realRoot := filepath.Join(sb2.Root, "ssd", "lane-builds")
	ws2 := sb2.Home("Projects", "App.xcworkspace") // outside ~/lane-builds, which must not exist yet
	if err := os.MkdirAll(ws2, 0o755); err != nil {
		t.Fatal(err)
	}
	ddProject(t, sb2, realRoot, "a-dd", ws2, 30*day)
	ddProject(t, sb2, realRoot, "b-dd", ws2, 30*day)
	if err := os.Symlink(realRoot, sb2.Home("lane-builds")); err != nil {
		t.Fatal(err)
	}
	lsofFree(sb2)
	items, skips, _ = laneRule().Plan(ctx, depsFor(sb2))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Fatalf("a symlinked ~/lane-builds must be skipped once, with a reason: %v %v", items, skips)
	}
}

func TestLaneLocal_InUseUnmountedAndRecheck(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := laneDD(t, sb, "dd", existingWorkspace(t, sb, "lane"), 30*day)
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", dir)
	r := laneRule()
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 1 {
		t.Fatalf("setup: %+v", items)
	}
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err != nil {
		t.Errorf("unchanged, it should pass: %v", err)
	}

	sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nxcodebuild 1 saint cwd\n"}, nil, "lsof", "-w", "+D", dir)
	if _, skips, _ := r.Plan(ctx, depsFor(sb)); len(skips) != 1 || !strings.Contains(skips[0].Reason, "in use") {
		t.Errorf("an open folder must be skipped: %v", skips)
	}
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err == nil || !strings.Contains(err.Error(), "in use") {
		t.Errorf("a folder opened after planning must block: %v", err)
	}

	// it turned into a lane after planning
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", dir)
	sb.WriteFile(t, filepath.Join(dir, "package.json"), 10, 30*day)
	if err := r.Recheck(ctx, depsFor(sb), items[0]); err == nil || !strings.Contains(err.Error(), "no longer") {
		t.Errorf("a folder that stopped looking like a build folder must block: %v", err)
	}
}

func TestLaneLocal_UnmountedVolumeIsSkipped(t *testing.T) {
	sb := systest.NewSandbox(t)
	vols := filepath.Join(sb.Root, "Volumes")
	withVolumes(t, vols)
	laneDD(t, sb, "dd", filepath.Join(vols, "NOT MOUNTED", "App.xcworkspace"), 30*day)
	lsofFree(sb)
	items, skips, _ := laneRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "not mounted") {
		t.Fatalf("an unmounted workspace volume must skip with a reason: %v %v", items, skips)
	}
}
