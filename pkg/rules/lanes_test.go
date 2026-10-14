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

// lane constructors with a tiny size threshold, so tests do not need big files
func depsRule() *LaneRule {
	r := laneDeps()
	r.MinBytes = 1
	return r
}

func outputRule() *LaneRule {
	r := laneBuildOutput()
	r.MinBytes = 1
	return r
}

// makeLane builds ~/lane-builds/<name> with a package.json, a source file and the given heavy folders, all
// aged the same.
func makeLane(t *testing.T, sb *systest.Sandbox, name string, age time.Duration, heavy ...string) string {
	t.Helper()
	lane := sb.Home("lane-builds", name)
	sb.WriteFile(t, filepath.Join(lane, "package.json"), 20, 0)
	sb.WriteFile(t, filepath.Join(lane, "src", "App.tsx"), 200, 0)
	sb.WriteFile(t, filepath.Join(lane, ".env"), 30, 0)
	for _, h := range heavy {
		sb.WriteFile(t, filepath.Join(lane, filepath.FromSlash(h), "big.bin"), 4000, 0)
	}
	sb.BackdateTree(t, lane, age)
	return lane
}

var (
	allDeps   = []string{"node_modules", "ios/Pods"}
	allOutput = []string{"ios/build", "android/build", "android/.gradle", "android/app/build", "android/app/.cxx"}
)

func planned(items []Candidate) []string {
	var out []string
	for _, c := range items {
		out = append(out, c.Path)
	}
	return out
}

func TestLanes_Identity(t *testing.T) {
	d, o := laneDeps(), laneBuildOutput()
	if d.ID() != "lane-deps" || d.Group() != "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)" {
		t.Errorf("deps identity wrong: %q %q", d.ID(), d.Group())
	}
	if o.ID() != "lane-build-output" || o.Group() != "Idle lane build output (untouched 5+ days; rebuilds on the next build)" {
		t.Errorf("output identity wrong: %q %q", o.ID(), o.Group())
	}
	if d.MinBytes != 50*mb || o.MinBytes != 50*mb {
		t.Errorf("both rules leave out anything under 50 MB: %d %d", d.MinBytes, o.MinBytes)
	}
}

func TestLanes_IdleLanePlansDependenciesAndBuildOutputSeparately(t *testing.T) {
	sb := systest.NewSandbox(t)
	lane := makeLane(t, sb, "mlp-ios", 30*day, append(append([]string{}, allDeps...), allOutput...)...)
	lsofFree(sb)

	items, skips, err := depsRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("deps: %v %v %v", items, skips, err)
	}
	want := []string{filepath.Join(lane, "node_modules"), filepath.Join(lane, "ios", "Pods")}
	if got := planned(items); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("deps planned %v, want %v", got, want)
	}
	for _, c := range items {
		if c.Tier != TierSafe || c.Action != ActionDelete || c.Bytes <= 0 || c.Group != depsRule().Group() {
			t.Errorf("unexpected candidate %+v", c)
		}
		if c.Note != "lane mlp-ios: untouched for 5+ days" {
			t.Errorf("the note should name the lane and why: %q", c.Note)
		}
	}

	items, skips, err = outputRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("output: %v %v %v", items, skips, err)
	}
	want = nil
	for _, sub := range allOutput {
		want = append(want, filepath.Join(lane, filepath.FromSlash(sub)))
	}
	if got := planned(items); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("output planned %v, want %v", got, want)
	}
}

func TestLanes_OnlyWhatExistsIsPlannedAndFreshLanesRunNothing(t *testing.T) {
	sb := systest.NewSandbox(t)
	makeLane(t, sb, "only-modules", 30*day, "node_modules")
	lsofFree(sb)
	items, _, _ := depsRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || !strings.HasSuffix(items[0].Path, "only-modules/node_modules") {
		t.Fatalf("%+v", items)
	}
	if items, _, _ := outputRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
		t.Fatalf("no build output exists: %+v", items)
	}

	sb2 := systest.NewSandbox(t)
	makeLane(t, sb2, "busy", time.Hour, allDeps...)
	if items, skips, _ := depsRule().Plan(ctx, depsFor(sb2)); len(items) != 0 || len(skips) != 0 {
		t.Fatalf("a lane used an hour ago keeps everything: %v %v", items, skips)
	}
	if n := len(sb2.Runner.Calls()); n != 0 {
		t.Errorf("a lane in use needs no command, ran %d", n)
	}
}

func TestLanes_FiveDayLineIsExactToTheMinute(t *testing.T) {
	for name, c := range map[string]struct {
		age  time.Duration
		want bool
	}{
		"4.5 days is still in use": {108 * time.Hour, false},
		"5.5 days is idle":         {132 * time.Hour, true},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			makeLane(t, sb, "lane", c.age, "node_modules")
			lsofFree(sb)
			items, _, _ := depsRule().Plan(ctx, depsFor(sb))
			if (len(items) == 1) != c.want {
				t.Fatalf("planned=%v, want %v", len(items) == 1, c.want)
			}
		})
	}
}

func TestLanes_WhatCountsAsActivity(t *testing.T) {
	setup := func(t *testing.T) (*systest.Sandbox, string) {
		sb := systest.NewSandbox(t)
		lane := makeLane(t, sb, "lane", 30*day, "node_modules", "ios/Pods", "ios/build", "android/app/build")
		lsofFree(sb)
		return sb, lane
	}
	t.Run("a new file in source keeps the lane", func(t *testing.T) {
		sb, lane := setup(t)
		sb.WriteFile(t, filepath.Join(lane, "src", "new.ts"), 10, time.Hour)
		if items, _, _ := depsRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
			t.Fatalf("%+v", items)
		}
	})
	t.Run("a new file in a build folder keeps the lane", func(t *testing.T) {
		sb, lane := setup(t)
		sb.WriteFile(t, filepath.Join(lane, "android", "app", "build", "out.apk"), 10, time.Hour)
		if items, _, _ := depsRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
			t.Fatalf("a build is activity: %+v", items)
		}
		if items, _, _ := outputRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
			t.Fatalf("a build is activity: %+v", items)
		}
	})
	t.Run("changes inside node_modules, Pods and .git do not", func(t *testing.T) {
		sb, lane := setup(t)
		sb.WriteFile(t, filepath.Join(lane, "node_modules", "pkg", "fresh.js"), 10, time.Minute)
		sb.WriteFile(t, filepath.Join(lane, "ios", "Pods", "fresh.h"), 10, time.Minute)
		sb.WriteFile(t, filepath.Join(lane, ".git", "index"), 10, time.Minute)
		sb.WriteFile(t, filepath.Join(lane, "packages", "a", "node_modules", "x.js"), 10, time.Minute) // nested ones too
		if items, _, _ := depsRule().Plan(ctx, depsFor(sb)); len(items) != 2 {
			t.Fatalf("activity inside dependencies and git is not use of the lane: %+v", items)
		}
	})
	t.Run("a fresh folder with only old files does not", func(t *testing.T) {
		sb, lane := setup(t)
		now := time.Date(2026, 10, 14, 11, 59, 0, 0, time.UTC)
		for _, p := range []string{lane, filepath.Join(lane, "src")} {
			if err := os.Chtimes(p, now, now); err != nil {
				t.Fatal(err)
			}
		}
		if items, _, _ := depsRule().Plan(ctx, depsFor(sb)); len(items) != 2 {
			t.Fatalf("only regular files count as activity: %+v", items)
		}
	})
	t.Run("a new file deep in the tree keeps the lane, there is no depth limit", func(t *testing.T) {
		sb, lane := setup(t)
		sb.WriteFile(t, filepath.Join(lane, "a", "b", "c", "d", "e", "deep.ts"), 10, time.Hour)
		if items, _, _ := depsRule().Plan(ctx, depsFor(sb)); len(items) != 0 {
			t.Fatalf("depth must not hide activity: %+v", items)
		}
	})
}

func TestLanes_OnlyRealLanesAreConsidered(t *testing.T) {
	sb := systest.NewSandbox(t)
	good := makeLane(t, sb, "lane", 30*day, "node_modules")
	// no package.json at the root: a build folder, a scratch folder, a lane whose project is one level down
	plain := sb.Home("lane-builds", "plain")
	sb.WriteFile(t, filepath.Join(plain, "node_modules", "big.bin"), 4000, 30*day)
	sb.BackdateTree(t, plain, 30*day)
	sub := sb.Home("lane-builds", "bakeoff-v2-main-d09b14a6d")
	sb.WriteFile(t, filepath.Join(sub, "cloud-mobile", "package.json"), 20, 30*day)
	sb.WriteFile(t, filepath.Join(sub, "cloud-mobile", "node_modules", "big.bin"), 4000, 30*day)
	sb.WriteFile(t, filepath.Join(sub, "cloud-mobile", "android", "app", "build", "out.apk"), 4000, 30*day)
	sb.BackdateTree(t, sub, 30*day)
	// package.json that is a folder
	odd := sb.Home("lane-builds", "odd")
	if err := os.MkdirAll(filepath.Join(odd, "package.json"), 0o755); err != nil {
		t.Fatal(err)
	}
	sb.WriteFile(t, filepath.Join(odd, "node_modules", "big.bin"), 4000, 30*day)
	sb.BackdateTree(t, odd, 30*day)
	// a plain file next to the lanes
	sb.WriteFile(t, sb.Home("lane-builds", "notes.txt"), 10, 30*day)
	lsofFree(sb)

	for _, r := range []*LaneRule{depsRule(), outputRule()} {
		items, skips, _ := r.Plan(ctx, depsFor(sb))
		if len(skips) != 0 {
			t.Errorf("%s: not lanes, so nothing to say: %v", r.ID(), skips)
		}
		for _, c := range items {
			if !strings.HasPrefix(c.Path, good+string(filepath.Separator)) {
				t.Errorf("%s planned %s, which is not in a real lane", r.ID(), c.Path)
			}
		}
	}
	if items, _, _ := depsRule().Plan(ctx, depsFor(sb)); len(items) != 1 {
		t.Errorf("the one real lane must be planned: %+v", items)
	}
}

func TestLanes_SizeThreshold(t *testing.T) {
	sb := systest.NewSandbox(t)
	makeLane(t, sb, "lane", 30*day, "node_modules")
	lsofFree(sb)
	r := depsRule()
	r.MinBytes = 1 << 20
	if items, skips, _ := r.Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 {
		t.Errorf("small ones are left out silently: %v %v", items, skips)
	}
}

func TestLanes_SymlinksAreNeverFollowed(t *testing.T) {
	t.Run("a linked lane", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		real := makeLane(t, sb, "real", 30*day, "node_modules")
		moved := filepath.Join(sb.Root, "ssd", "lane")
		if err := os.MkdirAll(filepath.Dir(moved), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(real, moved); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(moved, real); err != nil {
			t.Fatal(err)
		}
		lsofFree(sb)
		items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(items) != 0 || len(skips) != 0 {
			t.Fatalf("a link in ~/lane-builds is nothing this rule knows about: %v %v", items, skips)
		}
		if _, err := os.Stat(filepath.Join(moved, "node_modules", "big.bin")); err != nil {
			t.Errorf("the real lane must be untouched: %v", err)
		}
	})
	t.Run("node_modules is a link", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		lane := makeLane(t, sb, "lane", 30*day, "ios/Pods")
		target := filepath.Join(sb.Root, "shared", "node_modules")
		sb.WriteFile(t, filepath.Join(target, "big.bin"), 4000, 30*day)
		if err := os.Symlink(target, filepath.Join(lane, "node_modules")); err != nil {
			t.Fatal(err)
		}
		sb.BackdateTree(t, lane, 30*day)
		lsofFree(sb)
		items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(items) != 1 || !strings.HasSuffix(items[0].Path, "ios/Pods") {
			t.Fatalf("the link must not be planned, the real folder may: %+v", items)
		}
		if len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") || !strings.Contains(skips[0].Reason, "node_modules") {
			t.Fatalf("the link must be reported: %v", skips)
		}
	})
	t.Run("ios is a link, so ios/Pods is not below the lane", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		lane := makeLane(t, sb, "lane", 30*day, "node_modules")
		target := filepath.Join(sb.Root, "shared", "ios")
		sb.WriteFile(t, filepath.Join(target, "Pods", "big.bin"), 4000, 30*day)
		if err := os.Symlink(target, filepath.Join(lane, "ios")); err != nil {
			t.Fatal(err)
		}
		sb.BackdateTree(t, lane, 30*day)
		lsofFree(sb)
		items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(items) != 1 || !strings.HasSuffix(items[0].Path, "node_modules") {
			t.Fatalf("nothing behind the link may be planned: %+v", items)
		}
		if len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
			t.Fatalf("the link must be reported: %v", skips)
		}
		if _, err := os.Stat(filepath.Join(target, "Pods", "big.bin")); err != nil {
			t.Errorf("the folder behind the link must be untouched: %v", err)
		}
	})
	t.Run("~/lane-builds is a link", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		realRoot := filepath.Join(sb.Root, "ssd", "lane-builds")
		sb.WriteFile(t, filepath.Join(realRoot, "a", "package.json"), 20, 30*day)
		sb.WriteFile(t, filepath.Join(realRoot, "a", "node_modules", "big.bin"), 4000, 30*day)
		sb.WriteFile(t, filepath.Join(realRoot, "b", "package.json"), 20, 30*day)
		sb.WriteFile(t, filepath.Join(realRoot, "b", "node_modules", "big.bin"), 4000, 30*day)
		sb.BackdateTree(t, realRoot, 30*day)
		if err := os.Symlink(realRoot, sb.Home("lane-builds")); err != nil {
			t.Fatal(err)
		}
		lsofFree(sb)
		items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
			t.Fatalf("a linked ~/lane-builds is skipped once, with a reason: %v %v", items, skips)
		}
	})
}

func TestLanes_InUseAndUnanswerableInUse(t *testing.T) {
	sb := systest.NewSandbox(t)
	lane := makeLane(t, sb, "lane", 30*day, allDeps...)
	busy := filepath.Join(lane, "node_modules")
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "lsof")
	sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nnode 1 saint cwd\n"}, nil, "lsof", "-w", "+D", busy)
	items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || !strings.HasSuffix(items[0].Path, "ios/Pods") {
		t.Fatalf("only the folder nothing has open may be planned: %+v", items)
	}
	if len(skips) != 1 || !strings.Contains(skips[0].Reason, "in use") || !strings.Contains(skips[0].Reason, "node_modules") {
		t.Fatalf("the open folder must be reported: %v", skips)
	}

	sb2 := systest.NewSandbox(t)
	lane2 := makeLane(t, sb2, "lane", 30*day, "node_modules")
	sb2.Runner.Stub(sys.Result{ExitCode: 2}, nil, "lsof", "-w", "+D", filepath.Join(lane2, "node_modules"))
	items, skips, _ = depsRule().Plan(ctx, depsFor(sb2))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Fatalf("an unanswered in-use check must skip: %v %v", items, skips)
	}
}

func TestLanes_UnreadableLaneFailsSafeButUnreadableDependenciesDoNot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read everything")
	}
	t.Run("an unreadable folder in the source tree", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		lane := makeLane(t, sb, "lane", 30*day, "node_modules")
		locked := filepath.Join(lane, "src", "private")
		if err := os.MkdirAll(locked, 0o755); err != nil {
			t.Fatal(err)
		}
		sb.BackdateTree(t, lane, 30*day)
		if err := os.Chmod(locked, 0o000); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(locked, 0o755)
		lsofFree(sb)
		items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
			t.Fatalf("a lane whose use cannot be established must be skipped: %v %v", items, skips)
		}
	})
	t.Run("an unreadable folder inside node_modules", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		lane := makeLane(t, sb, "lane", 30*day, "node_modules")
		locked := filepath.Join(lane, "node_modules", "private")
		if err := os.MkdirAll(locked, 0o755); err != nil {
			t.Fatal(err)
		}
		sb.BackdateTree(t, lane, 30*day)
		if err := os.Chmod(locked, 0o000); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(locked, 0o755)
		lsofFree(sb)
		items, skips, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(skips) != 0 || len(items) != 1 {
			t.Fatalf("dependencies are not looked into, so they cannot block: %v %v", items, skips)
		}
		if !strings.Contains(items[0].Note, "could not be read") {
			t.Errorf("the size is a lower bound and the note must say so: %q", items[0].Note)
		}
	})
}

func TestLanes_MissingRootIsSilentAndRunsNothing(t *testing.T) {
	sb := systest.NewSandbox(t)
	for _, r := range []*LaneRule{depsRule(), outputRule()} {
		if items, skips, err := r.Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 || err != nil {
			t.Errorf("%s: nothing to say: %v %v %v", r.ID(), items, skips, err)
		}
	}
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("ran %d commands for nothing", n)
	}
}

func TestLanes_AllowsOnlyTheListedFoldersDirectlyBelowALane(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	lb := sb.Home("lane-builds")
	at := func(parts ...string) string { return lb + "/" + strings.Join(parts, "/") }

	for _, c := range []struct {
		rule *LaneRule
		subs []string
	}{{depsRule(), allDeps}, {outputRule(), allOutput}} {
		for _, sub := range c.subs {
			if p := at("some-lane", sub); !c.rule.Allows(d, p) { // the lane need not exist: Allows is about the shape
				t.Errorf("%s must allow %s", c.rule.ID(), p)
			}
		}
	}
	// each rule claims only its own folders
	for _, sub := range allOutput {
		if depsRule().Allows(d, at("some-lane", sub)) {
			t.Errorf("deps must not allow %s", sub)
		}
	}
	for _, sub := range allDeps {
		if outputRule().Allows(d, at("some-lane", sub)) {
			t.Errorf("output must not allow %s", sub)
		}
	}

	refused := []string{
		"", lb, sb.Home(), lb + "/",
		at("some-lane"), at("some-lane", "ios"), at("some-lane", "src"), at("some-lane", "android"), at("some-lane", "android", "app"),
		at("some-lane", ".env"), at("some-lane", "package.json"),
		at("a", "b", "node_modules"), at("a", "b", "ios", "Pods"), at("a", "b", "ios", "build"), at("a", "b", "android", "build"),
		at("a", "b", "android", ".gradle"), at("a", "b", "android", "app", "build"), at("a", "b", "c", "android", "app", "build"),
		at("some-lane", "node_modules", "x"), at("some-lane", "ios", "build", "x"), at("some-lane", "android", "app", "build", "x"),
		at("node_modules"), at("ios", "Pods"), at("ios", "build"), // a lane called "ios" has no ios/ folder inside it
		at("bakeoff-v2-main-d09b14a6d", "cloud-mobile", "node_modules"), at("bakeoff-v2-main-d09b14a6d", "cloud-mobile", "android", "app", "build"),
		lb + "/some-lane/../other/node_modules", lb + "/some-lane/./node_modules", lb + "//some-lane/node_modules",
		lb + "/./node_modules", lb + "/../node_modules", lb + "/./ios/Pods", lb + "/../ios/Pods", // "." and ".." taken as a lane name
		lb + "/some-lane/node_modules/", lb + "/some-lane/ios/Pods/",
		"some-lane/node_modules", "node_modules",
		sb.Home("other", "some-lane", "node_modules"), filepath.Join(sb.Root, "lane-builds", "some-lane", "node_modules"),
		sb.Home("lane-builds-x", "some-lane", "node_modules"),
	}
	for _, p := range refused {
		for _, r := range []*LaneRule{depsRule(), outputRule()} {
			if r.Allows(d, p) {
				t.Errorf("%s must refuse %q", r.ID(), p)
			}
		}
	}
}

func TestLanes_RecheckSeesNewActivitySymlinksAndOpenFiles(t *testing.T) {
	plan := func(t *testing.T) (*systest.Sandbox, string, Candidate) {
		sb := systest.NewSandbox(t)
		lane := makeLane(t, sb, "lane", 30*day, "node_modules")
		lsofFree(sb)
		items, _, _ := depsRule().Plan(ctx, depsFor(sb))
		if len(items) != 1 {
			t.Fatalf("setup: %+v", items)
		}
		if err := depsRule().Recheck(ctx, depsFor(sb), items[0]); err != nil {
			t.Fatalf("unchanged, it should pass: %v", err)
		}
		return sb, lane, items[0]
	}

	t.Run("work in the lane after planning", func(t *testing.T) {
		sb, lane, c := plan(t)
		sb.WriteFile(t, filepath.Join(lane, "src", "new.ts"), 10, time.Minute)
		if err := depsRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "used again") {
			t.Errorf("%v", err)
		}
	})
	t.Run("opened after planning", func(t *testing.T) {
		sb, lane, c := plan(t)
		sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\nnode 1 saint cwd\n"}, nil, "lsof", "-w", "+D", filepath.Join(lane, "node_modules"))
		if err := depsRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "in use") {
			t.Errorf("%v", err)
		}
	})
	t.Run("in-use check cannot answer", func(t *testing.T) {
		sb, lane, c := plan(t)
		sb.Runner.Stub(sys.Result{ExitCode: 2}, nil, "lsof", "-w", "+D", filepath.Join(lane, "node_modules"))
		if err := depsRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "could not check") {
			t.Errorf("%v", err)
		}
	})
	t.Run("replaced by a link after planning", func(t *testing.T) {
		sb, lane, c := plan(t)
		if err := os.RemoveAll(filepath.Join(lane, "node_modules")); err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(sb.Root, "elsewhere")
		sb.WriteFile(t, filepath.Join(target, "big.bin"), 10, 30*day)
		if err := os.Symlink(target, filepath.Join(lane, "node_modules")); err != nil {
			t.Fatal(err)
		}
		if err := depsRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Errorf("%v", err)
		}
	})
	t.Run("no longer a lane", func(t *testing.T) {
		sb, lane, c := plan(t)
		if err := os.Remove(filepath.Join(lane, "package.json")); err != nil {
			t.Fatal(err)
		}
		sb.BackdateTree(t, lane, 30*day)
		if err := depsRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "no longer") {
			t.Errorf("%v", err)
		}
	})
}
