package rules_test

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

const brewDryOut = "Would remove: /opt/homebrew/Cellar/boost/1.85.0 (15,123 files, 1.2GB)\n==> This operation would free approximately 1.2GB of disk space.\n"

var brewPrefix = []string{"HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_ENV_HINTS=1", "brew"}

// actionRunner stands in for the machine's tools: the sandbox's fake answers everything it was taught, and the
// two commands that really change something are carried out inside the sandbox (a simulator delete removes the
// device folder, brew cleanup is recorded) so a whole plan can be applied.
type actionRunner struct {
	sys.Runner
	devices string

	log        []string // every command line, in order
	simDeleted []string
	brewRuns   []string
}

func (r *actionRunner) Run(ctx context.Context, name string, args ...string) (sys.Result, error) {
	r.log = append(r.log, name+" "+strings.Join(args, " "))
	switch {
	case name == "xcrun" && len(args) == 3 && args[0] == "simctl" && args[1] == "delete":
		r.simDeleted = append(r.simDeleted, args[2])
		return sys.Result{}, os.RemoveAll(filepath.Join(r.devices, args[2]))
	case name == "env" && len(args) == len(brewPrefix)+1 && strings.Join(args, " ") == strings.Join(append(append([]string{}, brewPrefix...), "cleanup"), " "):
		r.brewRuns = append(r.brewRuns, strings.Join(args, " "))
		return sys.Result{Stdout: "==> This operation has freed approximately 1.2GB of disk space.\n"}, nil
	}
	return r.Runner.Run(ctx, name, args...)
}

// seeded describes a machine every built-in rule has something to do on.
type seeded struct {
	goes    []string // folders a real run removes
	stays   []string // folders and files a real run must leave alone
	simDir  string
	devices string
}

// seedEverything lays out the files only; stubEverything teaches the fake tools to answer.
func seedEverything(t *testing.T, sb *systest.Sandbox) *seeded {
	t.Helper()
	s := &seeded{devices: sb.Home("Library", "Developer", "CoreSimulator", "Devices")}
	add := func(list *[]string, paths ...string) { *list = append(*list, paths...) }
	file := func(p string, age time.Duration) { sb.WriteFile(t, p, 4000, age) }

	// caches (age does not matter to them)
	for _, p := range seedAllCaches(t, sb) {
		add(&s.goes, p)
	}

	// Xcode build folders: a stale project and a fresh one in DerivedData, a stale lane-local one
	dd := sb.Home("Library", "Developer", "Xcode", "DerivedData")
	for _, p := range []string{dd + "/Stale-" + hash28, dd + "/Fresh-" + hash28, sb.Home("lane-builds", "app-dd")} {
		file(p+"/Build/Products/obj", 0)
		file(p+"/Logs/Build/a.log", 0)
		file(p+"/info.plist", 0)
	}
	sb.BackdateTree(t, dd+"/Stale-"+hash28, 30*day)
	sb.BackdateTree(t, dd+"/Fresh-"+hash28, time.Hour)
	sb.BackdateTree(t, sb.Home("lane-builds", "app-dd"), 30*day)
	add(&s.goes, dd+"/Stale-"+hash28, sb.Home("lane-builds", "app-dd"))
	add(&s.stays, dd+"/Fresh-"+hash28)
	mustMkdir(t, sb.Home("code", "App.xcworkspace"))

	// lanes: one idle (dependencies and build output go, the project stays), one busy
	idle, busy := sb.Home("lane-builds", "idle"), sb.Home("lane-builds", "busy")
	for _, lane := range []string{idle, busy} {
		file(lane+"/package.json", 0)
		file(lane+"/src/App.tsx", 0)
		for _, h := range []string{"node_modules/x/i.js", "ios/Pods/x/p.h", "ios/build/o", "android/build/o"} {
			file(lane+"/"+h, 0)
		}
	}
	sb.BackdateTree(t, idle, 30*day)
	sb.BackdateTree(t, busy, time.Hour)
	add(&s.goes, idle+"/node_modules", idle+"/ios/Pods", idle+"/ios/build", idle+"/android/build")
	add(&s.stays, idle+"/package.json", idle+"/src/App.tsx", busy+"/node_modules", busy+"/ios/build", busy+"/package.json")

	// temp output of Maestro runs: an old one goes, a new one stays
	old, fresh := sb.Tmp("maestro_xctestrunner_xcodebuild_output_old"), sb.Tmp("maestro_xctestrunner_xcodebuild_output_new")
	file(old+"/log", 0)
	file(fresh+"/log", 0)
	sb.BackdateTree(t, old, 3*time.Hour)
	sb.BackdateTree(t, fresh, 10*time.Minute)
	add(&s.goes, old)
	add(&s.stays, fresh)

	// Cursor's failed update
	shipit := sb.Home("Library", "Caches", "com.todesktop.230313mzl4w4u92.ShipIt")
	file(shipit+"/update.1/Cursor.app/x", 0)
	file(shipit+"/ShipItState.plist", 0)
	file(shipit+"/ShipIt_stderr.log", 0)
	add(&s.goes, shipit+"/update.1", shipit+"/ShipItState.plist")
	add(&s.stays, shipit+"/ShipIt_stderr.log")

	// old CLI versions: the newest and the linked one stay
	claude := sb.Home(".local", "share", "claude", "versions")
	file(claude+"/1.0.0", 30*day)
	file(claude+"/2.0.0", day)
	mustSymlink(t, claude+"/2.0.0", sb.Home(".local", "bin", "claude"))
	agent := sb.Home(".local", "share", "cursor-agent", "versions")
	file(agent+"/2026.01.01/bin/agent", 0)
	file(agent+"/2026.09.28-64d2043/bin/agent", 0)
	sb.BackdateTree(t, agent+"/2026.01.01", 30*day)
	sb.BackdateTree(t, agent+"/2026.09.28-64d2043", day)
	add(&s.goes, claude+"/1.0.0", agent+"/2026.01.01")
	add(&s.stays, claude+"/2.0.0", agent+"/2026.09.28-64d2043")

	// a simulator whose runtime is gone
	s.simDir = s.devices + "/" + goodUDID
	file(s.simDir+"/device.plist", 0)
	file(s.simDir+"/data/Library/blob", 0)
	sb.BackdateTree(t, s.simDir, 30*day)
	add(&s.goes, s.simDir)

	// the parents no rule may claim
	add(&s.stays, sb.Home("lane-builds"), dd, sb.Home("Library", "Caches"), sb.Home(".local", "bin"), sb.Env.TmpDir, s.devices)
	return s
}

func stubEverything(t *testing.T, sb *systest.Sandbox, s *seeded) *actionRunner {
	t.Helper()
	dd := sb.Home("Library", "Developer", "Xcode", "DerivedData")
	ws := sb.Home("code", "App.xcworkspace")
	for _, dir := range []string{dd + "/Stale-" + hash28, dd + "/Fresh-" + hash28, sb.Home("lane-builds", "app-dd")} {
		sb.Runner.Stub(sys.Result{Stdout: ws + "\n"}, nil, "plutil", "-extract", "WorkspacePath", "raw", filepath.Join(dir, "info.plist"))
	}
	plist := filepath.Join(s.simDir, "device.plist")
	for key, val := range map[string]string{"runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-2", "state": "1", "name": "iPhone 17 Pro"} {
		sb.Runner.Stub(sys.Result{Stdout: val + "\n"}, nil, "plutil", "-extract", key, "raw", plist)
	}
	sb.Runner.Stub(sys.Result{Stdout: "== Runtimes ==\niOS 27.0 (27.0 - 25A5279m) - com.apple.CoreSimulator.SimRuntime.iOS-27-0\n"}, nil, "xcrun", "simctl", "list", "runtimes")
	sb.Runner.Stub(sys.Result{Stdout: "== Devices ==\n    iPhone 17 Pro (" + goodUDID + ") (Shutdown) (unavailable)\n"}, nil, "xcrun", "simctl", "list", "devices", "unavailable")
	sb.Runner.Stub(sys.Result{Stdout: brewDryOut}, nil, "env", append(append([]string{}, brewPrefix...), "cleanup", "-n")...)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep") // nothing is running
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "lsof")  // nothing is open

	ar := &actionRunner{Runner: sb.Runner, devices: s.devices}
	sb.Env.Runner = ar
	return ar
}

// every rule that has something to do, and how many items it plans
var wantItems = map[string]int{
	"simulators": 1, "deriveddata-stale": 1, "xcode-module-cache": 2, "go-build": 1, "npm-cache": 1, "cocoapods": 1,
	"bun-cache": 1, "uv-cache": 1, "jest-temp": 1, "maestro-temp": 1, "cursor-update": 2, "claude-versions": 1,
	"cursor-agent-versions": 1, "lane-deps": 2, "lane-build-output": 2, "lane-local-build": 1, "homebrew": 1,
}

func countByRule(plan *engine.Plan) map[string]int {
	got := map[string]int{}
	for _, it := range plan.Items {
		got[it.Rule]++
	}
	return got
}

func TestRegistry_EveryRuleThroughTheRealEngineInASandbox(t *testing.T) {
	sb := systest.NewSandbox(t)
	s := seedEverything(t, sb)
	ar := stubEverything(t, sb, s)
	e := engineFor(sb, rules.BuiltinWithMin(1, 1))

	plan, err := e.Plan(ctx)
	if err != nil {
		t.Fatalf("Plan() failed: %v", err)
	}
	if got := countByRule(plan); len(got) != len(wantItems) {
		t.Fatalf("items per rule = %v, want %v", got, wantItems)
	} else {
		for id, n := range wantItems {
			if got[id] != n {
				t.Errorf("rule %s planned %d items, want %d (all: %v)", id, got[id], n, got)
			}
		}
	}
	if len(plan.Skipped) != 0 {
		t.Errorf("nothing should be skipped: %v", plan.Skipped)
	}
	if len(plan.Groups) != len(wantItems) {
		t.Errorf("one group per rule expected, got %d: %+v", len(plan.Groups), plan.Groups)
	}
	for _, it := range plan.Items {
		if it.Tier != rules.TierSafe || it.Bytes <= 0 {
			t.Errorf("unexpected item %+v", it)
		}
		if (it.Rule == "simulators" || it.Rule == "homebrew") != (it.Action == rules.ActionCommand) {
			t.Errorf("only simulators and homebrew are commands: %+v", it)
		}
	}
	if len(ar.simDeleted) != 0 || len(ar.brewRuns) != 0 {
		t.Fatalf("planning must change nothing: %v %v", ar.simDeleted, ar.brewRuns)
	}

	rep, err := e.Apply(ctx, plan, engine.ApplyOptions{})
	if err != nil || !rep.OK() || rep.Skipped != 0 || rep.Deleted != len(plan.Items) {
		t.Fatalf("Apply() = %+v, %v", rep, err)
	}
	for _, p := range s.goes {
		if _, err := os.Lstat(p); err == nil {
			t.Errorf("should have gone: %s", p)
		}
	}
	for _, p := range s.stays {
		if _, err := os.Lstat(p); err != nil {
			t.Errorf("must have stayed: %s (%v)", p, err)
		}
	}
	if len(ar.simDeleted) != 1 || ar.simDeleted[0] != goodUDID {
		t.Errorf("the simulator must go through simctl delete: %v", ar.simDeleted)
	}
	if len(ar.brewRuns) != 1 {
		t.Errorf("brew cleanup must run once: %v", ar.brewRuns)
	}
}

func TestRegistry_ADryRunRunsNoCommandThatChangesAnything(t *testing.T) {
	sb := systest.NewSandbox(t)
	s := seedEverything(t, sb)
	ar := stubEverything(t, sb, s)
	e := engineFor(sb, rules.BuiltinWithMin(1, 1))

	plan, err := e.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	rep, err := e.Apply(ctx, plan, engine.ApplyOptions{DryRun: true})
	if err != nil || rep.Deleted != 0 || rep.Failed != 0 || rep.Skipped != 0 {
		t.Fatalf("Apply(dry run) = %+v, %v", rep, err)
	}
	for _, p := range append(append([]string{}, s.goes...), s.stays...) {
		if _, err := os.Lstat(p); err != nil {
			t.Errorf("a dry run removed %s", p)
		}
	}
	if len(ar.simDeleted) != 0 || len(ar.brewRuns) != 0 {
		t.Errorf("a dry run ran a changing command: %v %v", ar.simDeleted, ar.brewRuns)
	}
}

// Only these programs may ever be started, and only these two command lines may change anything.
func TestRegistry_OnlyKnownToolsAreRunAndOnlyTwoCommandsChangeAnything(t *testing.T) {
	sb := systest.NewSandbox(t)
	s := seedEverything(t, sb)
	ar := stubEverything(t, sb, s)
	e := engineFor(sb, rules.BuiltinWithMin(1, 1))
	plan, err := e.Plan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.Apply(ctx, plan, engine.ApplyOptions{}); err != nil {
		t.Fatal(err)
	}

	known := map[string]bool{"pgrep": true, "lsof": true, "plutil": true, "xcrun": true, "env": true}
	seen := map[string]bool{}
	for _, line := range ar.log {
		name, _, _ := strings.Cut(line, " ")
		seen[name] = true
		if !known[name] {
			t.Errorf("an unexpected program was started: %s", line)
		}
		if name == "xcrun" && !strings.HasPrefix(line, "xcrun simctl list ") && line != "xcrun simctl delete "+goodUDID {
			t.Errorf("unexpected xcrun call: %s", line)
		}
		if name == "env" && !strings.HasPrefix(line, "env "+strings.Join(brewPrefix, " ")+" cleanup") {
			t.Errorf("env must only be used to run brew cleanup: %s", line)
		}
	}
	var names []string
	for n := range seen {
		names = append(names, n)
	}
	sort.Strings(names)
	if strings.Join(names, " ") != "env lsof pgrep plutil xcrun" {
		t.Errorf("every tool should have been needed on this machine, got %v", names)
	}
}

// With every tool unreachable (a fake runner that answers nothing) no rule may plan anything: a question that
// cannot be answered is never read as "safe". Nothing is deleted and nothing panics.
func TestRegistry_ToolsThatCannotAnswerNeverMakeAnythingSafe(t *testing.T) {
	sb := systest.NewSandbox(t)
	s := seedEverything(t, sb) // files only: the fake runner has no stubs at all
	e := engineFor(sb, rules.BuiltinWithMin(1, 1))

	plan, err := e.Plan(ctx)
	if err != nil {
		t.Fatalf("Plan() failed: %v", err)
	}
	if len(plan.Items) != 0 {
		t.Fatalf("with no tool answering, nothing may be planned, got %+v", plan.Items)
	}
	if len(plan.Skipped) == 0 {
		t.Error("the rules that could not ask their questions should say so")
	}
	for _, sk := range plan.Skipped {
		t.Logf("skipped %-22s %s", sk.Rule, sk.Reason)
	}
	if len(sb.Runner.Calls()) == 0 {
		t.Error("the rules should have tried to ask their questions through the runner")
	}
	rep, err := e.Apply(ctx, plan, engine.ApplyOptions{})
	if err != nil || rep.Deleted != 0 {
		t.Fatalf("Apply() = %+v, %v", rep, err)
	}
	for _, p := range append(append([]string{}, s.goes...), s.stays...) {
		if _, err := os.Lstat(p); err != nil {
			t.Errorf("%s vanished", p)
		}
	}
}
