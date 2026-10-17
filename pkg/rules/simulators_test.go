package rules

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

const (
	simA  = "1C7EE994-6898-4D40-883D-0EF75816C39A"
	simB  = "2D8FF0A5-7909-4E51-994E-1FA86927D40B"
	rtOld = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
	rtNew = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"

	runtimesOut = "== Runtimes ==\niOS 27.0 (27.0 - 25A5279m) - " + rtNew + "\n"
)

func simRoot(sb *systest.Sandbox) string {
	return sb.Home("Library", "Developer", "CoreSimulator", "Devices")
}

func unavailableOut(udids ...string) string {
	out := "== Devices ==\n-- Unavailable: " + rtOld + " --\n"
	for _, u := range udids {
		out += "    iPhone 17 Pro (" + u + ") (Shutdown) (unavailable, runtime profile not found)\n"
	}
	return out
}

type simSpec struct {
	udid, runtime, state, name string
	age                        time.Duration
}

// goodSim is a shut-down device of a removed runtime that nothing has touched for a month.
func goodSim(udid string) simSpec {
	return simSpec{udid: udid, runtime: rtOld, state: "1", name: "iPhone 17 Pro", age: 30 * day}
}

// addSim lays out one device folder and teaches the fake plutil what its device.plist says.
func addSim(t *testing.T, sb *systest.Sandbox, s simSpec) string {
	t.Helper()
	dir := filepath.Join(simRoot(sb), s.udid)
	plist := filepath.Join(dir, "device.plist")
	sb.WriteFile(t, plist, 100, 0)
	sb.WriteFile(t, filepath.Join(dir, "data", "Library", "Caches", "blob"), 4000, 0)
	sb.BackdateTree(t, dir, s.age)
	for key, val := range map[string]string{"runtime": s.runtime, "state": s.state, "name": s.name} {
		sb.Runner.Stub(sys.Result{Stdout: val + "\n"}, nil, "plutil", "-extract", key, "raw", plist)
	}
	return dir
}

// simctlAnswers makes the fake simctl list the given runtimes and report these devices as unavailable.
func simctlAnswers(sb *systest.Sandbox, runtimes string, unavailable ...string) {
	sb.Runner.Stub(sys.Result{Stdout: runtimes}, nil, "xcrun", "simctl", "list", "runtimes")
	sb.Runner.Stub(sys.Result{Stdout: unavailableOut(unavailable...)}, nil, "xcrun", "simctl", "list", "devices", "unavailable")
}

func simRule() *SimulatorsRule { return simulators() }

func TestSimulators_Identity(t *testing.T) {
	r := simRule()
	if r.ID() != "simulators" || r.Group() != "Simulators whose runtime was removed" {
		t.Errorf("identity wrong: %q %q", r.ID(), r.Group())
	}
}

func TestSimulators_UnavailableDeviceOfARemovedRuntimeIsPlanned(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := addSim(t, sb, goodSim(simA))
	simctlAnswers(sb, runtimesOut, simA)
	lsofFree(sb)

	items, skips, err := simRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	if len(items) != 1 {
		t.Fatalf("want one device: %+v", items)
	}
	c := items[0]
	if c.Path != dir || c.Action != ActionCommand || c.Tier != TierSafe || c.Bytes <= 0 || c.Group != "Simulators whose runtime was removed" {
		t.Errorf("unexpected candidate %+v", c)
	}
	if c.Note != "iPhone 17 Pro (iOS-26-2): its runtime is no longer installed" {
		t.Errorf("the note should name the device and its runtime: %q", c.Note)
	}
}

func TestSimulators_NoDevicesFolderIsSilentAndRunsNothing(t *testing.T) {
	sb := systest.NewSandbox(t)
	if items, skips, err := simRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 || err != nil {
		t.Errorf("nothing to say: %v %v %v", items, skips, err)
	}
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("ran %d commands for nothing", n)
	}
}

func TestSimulators_CoreSimulatorNotAnsweringJudgesNothing(t *testing.T) {
	for name, stub := range map[string]struct {
		res sys.Result
		err error
	}{
		"empty list":          {sys.Result{Stdout: ""}, nil},
		"no runtime in it":    {sys.Result{Stdout: "== Runtimes ==\n"}, nil},
		"error output only":   {sys.Result{Stderr: "CoreSimulatorService connection became invalid", ExitCode: 1}, nil},
		"nonzero with output": {sys.Result{Stdout: "== Runtimes ==\n" + rtNew, ExitCode: 1}, nil},
		"cannot be started":   {sys.Result{}, errors.New("xcrun: not found")},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			addSim(t, sb, goodSim(simA))
			sb.Runner.Stub(stub.res, stub.err, "xcrun", "simctl", "list", "runtimes")
			// if the unavailable list were asked for, the fake would answer; it must not be asked
			sb.Runner.Stub(sys.Result{Stdout: unavailableOut(simA)}, nil, "xcrun", "simctl", "list", "devices", "unavailable")
			lsofFree(sb)

			items, skips, _ := simRule().Plan(ctx, depsFor(sb))
			if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "CoreSimulator did not list any runtime") {
				t.Fatalf("a simulator service that is not answering must stop the judging: %v %v", items, skips)
			}
			for _, c := range sb.Runner.Calls() {
				if strings.Contains(strings.Join(c.Args, " "), "devices") {
					t.Errorf("the device list must not be asked for: %v", c)
				}
			}
		})
	}
}

func TestSimulators_UnavailableListFailureIsReported(t *testing.T) {
	sb := systest.NewSandbox(t)
	addSim(t, sb, goodSim(simA))
	sb.Runner.Stub(sys.Result{Stdout: runtimesOut}, nil, "xcrun", "simctl", "list", "runtimes")
	sb.Runner.Stub(sys.Result{ExitCode: 1, Stderr: "boom"}, nil, "xcrun", "simctl", "list", "devices", "unavailable")
	items, skips, _ := simRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "unavailable") {
		t.Fatalf("%v %v", items, skips)
	}
}

func TestSimulators_OnlyDevicesThatReallyExistAreConsidered(t *testing.T) {
	sb := systest.NewSandbox(t)
	addSim(t, sb, goodSim(simA))
	// listed, but no folder; and a folder without a device.plist
	noPlist := filepath.Join(simRoot(sb), simB)
	sb.WriteFile(t, filepath.Join(noPlist, "data", "x"), 100, 30*day)
	sb.BackdateTree(t, noPlist, 30*day)
	simctlAnswers(sb, runtimesOut, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", simB, simA)
	lsofFree(sb)

	items, skips, _ := simRule().Plan(ctx, depsFor(sb))
	if len(skips) != 0 || len(items) != 1 || !strings.HasSuffix(items[0].Path, simA) {
		t.Fatalf("only the device with a folder and a device.plist may be planned: %v %v", items, skips)
	}
}

func TestSimulators_OnlyWellFormedIdsAreTakenFromTheList(t *testing.T) {
	sb := systest.NewSandbox(t)
	addSim(t, sb, goodSim(simA))
	// a folder whose name is not a device id, and ids in the wrong case, must never be reached
	odd := filepath.Join(simRoot(sb), "not-a-device")
	sb.WriteFile(t, filepath.Join(odd, "device.plist"), 10, 30*day)
	sb.BackdateTree(t, odd, 30*day)
	out := "== Devices ==\n    x (not-a-device) (Shutdown)\n    y (" + strings.ToLower(simB) + ") (Shutdown)\n    z (../" + simA + "/..) (Shutdown)\n    w (" + simA + ") (Shutdown)\n    dup (" + simA + ")\n"
	sb.Runner.Stub(sys.Result{Stdout: runtimesOut}, nil, "xcrun", "simctl", "list", "runtimes")
	sb.Runner.Stub(sys.Result{Stdout: out}, nil, "xcrun", "simctl", "list", "devices", "unavailable")
	lsofFree(sb)

	items, skips, _ := simRule().Plan(ctx, depsFor(sb))
	if len(skips) != 0 || len(items) != 1 || !strings.HasSuffix(items[0].Path, simA) {
		t.Fatalf("only the exact id may be used, and once: %v %v", items, skips)
	}
}

func TestSimulators_EveryGuardKeepsADevice(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(s *simSpec)
		stubs  func(sb *systest.Sandbox, dir string)
		reason string
	}{
		{"no runtime recorded", func(s *simSpec) { s.runtime = "" }, nil, "no runtime recorded"},
		{"booted", func(s *simSpec) { s.state = "3" }, nil, "not shut down"},
		{"booting", func(s *simSpec) { s.state = "2" }, nil, "not shut down"},
		{"state unreadable", nil, func(sb *systest.Sandbox, dir string) {
			sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "plutil", "-extract", "state", "raw", filepath.Join(dir, "device.plist"))
		}, "not shut down"},
		{"touched 2 days ago", func(s *simSpec) { s.age = 2 * day }, nil, "changed in the last 3 days"},
		{"runtime installed after all", func(s *simSpec) { s.runtime = rtNew }, nil, "its runtime is installed after all"},
		{"in use", nil, func(sb *systest.Sandbox, dir string) {
			sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\ncom.apple 1 saint txt\n"}, nil, "lsof", "-w", "+D", dir)
		}, "something has it open"},
		{"in use cannot be checked", nil, func(sb *systest.Sandbox, dir string) {
			sb.Runner.Stub(sys.Result{ExitCode: 2}, nil, "lsof", "-w", "+D", dir)
		}, "could not check"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			spec := goodSim(simA)
			if c.mutate != nil {
				c.mutate(&spec)
			}
			dir := addSim(t, sb, spec)
			simctlAnswers(sb, runtimesOut, simA)
			lsofFree(sb)
			if c.stubs != nil {
				c.stubs(sb, dir)
			}
			items, skips, _ := simRule().Plan(ctx, depsFor(sb))
			if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, c.reason) {
				t.Fatalf("must be kept for %q: %v %v", c.reason, items, skips)
			}
			if _, err := os.Stat(dir); err != nil {
				t.Errorf("nothing may be touched: %v", err)
			}
		})
	}
}

func TestSimulators_ThreeDayLineIsExactToTheMinute(t *testing.T) {
	for name, c := range map[string]struct {
		age  time.Duration
		want bool
	}{
		"2.5 days is too recent": {60 * time.Hour, false},
		"3.5 days is old enough": {84 * time.Hour, true},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			spec := goodSim(simA)
			spec.age = c.age
			addSim(t, sb, spec)
			simctlAnswers(sb, runtimesOut, simA)
			lsofFree(sb)
			items, _, _ := simRule().Plan(ctx, depsFor(sb))
			if (len(items) == 1) != c.want {
				t.Fatalf("planned=%v, want %v", len(items) == 1, c.want)
			}
		})
	}
}

func TestSimulators_OnlyTheFolderAndItsDirectChildrenTellWhenItWasLastUsed(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := addSim(t, sb, goodSim(simA))
	// the device is shut down: files deep in its data folder do not say it was used again
	sb.WriteFile(t, filepath.Join(dir, "data", "Library", "Caches", "newer"), 10, time.Hour)
	simctlAnswers(sb, runtimesOut, simA)
	lsofFree(sb)
	if items, _, _ := simRule().Plan(ctx, depsFor(sb)); len(items) != 1 {
		t.Fatalf("deep activity must not matter (device.plist records a shutdown): %+v", items)
	}

	sb2 := systest.NewSandbox(t)
	dir2 := addSim(t, sb2, goodSim(simA))
	sb2.WriteFile(t, filepath.Join(dir2, "device.plist"), 100, time.Hour) // rewritten an hour ago
	simctlAnswers(sb2, runtimesOut, simA)
	lsofFree(sb2)
	if items, _, _ := simRule().Plan(ctx, depsFor(sb2)); len(items) != 0 {
		t.Fatalf("a device.plist written an hour ago is recent use: %+v", items)
	}
}

func TestSimulators_LinksAreNeverFollowed(t *testing.T) {
	sb := systest.NewSandbox(t)
	real := addSim(t, sb, goodSim(simA))
	moved := filepath.Join(sb.Root, "ssd", simA)
	if err := os.MkdirAll(filepath.Dir(moved), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(real, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(moved, real); err != nil {
		t.Fatal(err)
	}
	simctlAnswers(sb, runtimesOut, simA)
	lsofFree(sb)
	items, skips, _ := simRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Fatalf("a linked device folder must be skipped with a reason: %v %v", items, skips)
	}

	// the whole Devices folder lives on another disk behind a link: one skip
	sb2 := systest.NewSandbox(t)
	addSim(t, sb2, goodSim(simA))
	addSim(t, sb2, goodSim(simB))
	root := simRoot(sb2)
	elsewhere := filepath.Join(sb2.Root, "ssd", "Devices")
	if err := os.MkdirAll(filepath.Dir(elsewhere), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(root, elsewhere); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, root); err != nil {
		t.Fatal(err)
	}
	simctlAnswers(sb2, runtimesOut, simA, simB)
	lsofFree(sb2)
	items, skips, _ = simRule().Plan(ctx, depsFor(sb2))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "symbolic link") {
		t.Fatalf("a linked Devices folder must be skipped once: %v %v", items, skips)
	}
}

func TestSimulators_AllowsOnlyDeviceFoldersDirectlyBelowDevices(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	r := simRule()
	root := simRoot(sb)
	if !r.Allows(d, filepath.Join(root, simA)) { // it need not exist: Allows is about the shape
		t.Error("a device folder must be allowed")
	}
	for name, p := range map[string]string{
		"the Devices folder": root,
		"its parent":         filepath.Dir(root),
		"nested":             filepath.Join(root, simA, "data"),
		"device.plist":       filepath.Join(root, simA, "device.plist"),
		"lower case":         filepath.Join(root, strings.ToLower(simA)),
		"too short":          filepath.Join(root, simA[:35]),
		"too long":           filepath.Join(root, simA+"0"),
		"not hex":            filepath.Join(root, "ZZZZZZZZ"+simA[8:]),
		"not an id":          filepath.Join(root, "not-a-device"),
		"dot-dot":            root + "/x/../" + simA,
		"dot-dot id":         root + "/" + simA + "/..",
		"trailing slash":     root + "/" + simA + "/",
		"another folder":     sb.Home("Library", "Developer", "CoreSimulator", simA),
		"relative":           simA,
		"empty":              "",
		"outside the home":   filepath.Join(sb.Root, "Devices", simA),
	} {
		if r.Allows(d, p) {
			t.Errorf("%s (%q) must not be allowed", name, p)
		}
	}
}

// deleter answers "xcrun simctl delete <udid>" itself and passes everything else to the sandbox's fake.
type deleter struct {
	sys.Runner
	onDelete func(udid string) (sys.Result, error)
	deleted  []string
}

func (r *deleter) Run(ctx context.Context, name string, args ...string) (sys.Result, error) {
	if name == "xcrun" && len(args) >= 2 && args[0] == "simctl" && args[1] == "delete" {
		r.deleted = append(r.deleted, strings.Join(args[2:], " "))
		return r.onDelete(args[len(args)-1])
	}
	return r.Runner.Run(ctx, name, args...)
}

func withDeleter(sb *systest.Sandbox, on func(udid string) (sys.Result, error)) *deleter {
	dl := &deleter{Runner: sb.Runner, onDelete: on}
	sb.Env.Runner = dl
	return dl
}

func TestSimulators_ExecuteDeletesThroughSimctlAndChecksTheFolderIsGone(t *testing.T) {
	sb := systest.NewSandbox(t)
	dir := addSim(t, sb, goodSim(simA))
	simctlAnswers(sb, runtimesOut, simA)
	lsofFree(sb)
	items, _, _ := simRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 {
		t.Fatalf("setup: %+v", items)
	}

	t.Run("works", func(t *testing.T) {
		dl := withDeleter(sb, func(string) (sys.Result, error) {
			return sys.Result{}, os.RemoveAll(dir)
		})
		freed, err := simRule().Execute(ctx, depsFor(sb), items[0])
		if err != nil || freed != items[0].Bytes {
			t.Fatalf("Execute() = %d, %v", freed, err)
		}
		if len(dl.deleted) != 1 || dl.deleted[0] != simA {
			t.Errorf("simctl delete must be called once with exactly the id: %v", dl.deleted)
		}
	})
}

func TestSimulators_ExecuteFailuresAreFailures(t *testing.T) {
	setup := func(t *testing.T, on func(string) (sys.Result, error)) (*systest.Sandbox, *deleter, string, Candidate) {
		sb := systest.NewSandbox(t)
		dir := addSim(t, sb, goodSim(simA))
		c := Candidate{Rule: "simulators", Path: dir, Bytes: 4100, Tier: TierSafe, Action: ActionCommand}
		return sb, withDeleter(sb, on), dir, c
	}
	t.Run("exit status", func(t *testing.T) {
		sb, dl, _, c := setup(t, func(string) (sys.Result, error) {
			return sys.Result{ExitCode: 1, Stderr: "Unable to delete device"}, nil
		})
		if _, err := simRule().Execute(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "Unable to delete device") || len(dl.deleted) != 1 {
			t.Errorf("a failing simctl must be an error that says why: %v", err)
		}
	})
	t.Run("cannot be started", func(t *testing.T) {
		sb, _, _, c := setup(t, func(string) (sys.Result, error) { return sys.Result{}, errors.New("xcrun: not found") })
		if _, err := simRule().Execute(ctx, depsFor(sb), c); err == nil {
			t.Error("expected an error")
		}
	})
	t.Run("exit 0 but the folder is still there", func(t *testing.T) {
		sb, _, dir, c := setup(t, func(string) (sys.Result, error) { return sys.Result{}, nil })
		if _, err := simRule().Execute(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "still") {
			t.Errorf("a delete that left the folder must count as failed: %v", err)
		}
		if _, err := os.Stat(dir); err != nil {
			t.Errorf("setup: %v", err)
		}
	})
	t.Run("refuses anything that is not a device folder, before running a command", func(t *testing.T) {
		sb, dl, _, c := setup(t, func(string) (sys.Result, error) { return sys.Result{}, nil })
		for _, bad := range []string{
			simRoot(sb), filepath.Join(simRoot(sb), simA, "data"), filepath.Join(simRoot(sb), "not-a-device"),
			sb.Home("Documents"), "", simA, simRoot(sb) + "/x/../" + simA,
		} {
			bc := c
			bc.Path = bad
			if _, err := simRule().Execute(ctx, depsFor(sb), bc); err == nil {
				t.Errorf("%q must be refused", bad)
			}
		}
		if len(dl.deleted) != 0 {
			t.Errorf("no command may run for a refused path: %v", dl.deleted)
		}
	})
}

func TestSimulators_RecheckReasksEverythingBeforeDeleting(t *testing.T) {
	plan := func(t *testing.T) (*systest.Sandbox, string, Candidate) {
		sb := systest.NewSandbox(t)
		dir := addSim(t, sb, goodSim(simA))
		simctlAnswers(sb, runtimesOut, simA)
		sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "lsof", "-w", "+D", dir)
		items, _, _ := simRule().Plan(ctx, depsFor(sb))
		if len(items) != 1 {
			t.Fatalf("setup: %+v", items)
		}
		if err := simRule().Recheck(ctx, depsFor(sb), items[0]); err != nil {
			t.Fatalf("unchanged, it should pass: %v", err)
		}
		return sb, dir, items[0]
	}

	t.Run("the runtime was installed after planning", func(t *testing.T) {
		sb, _, c := plan(t)
		simctlAnswers(sb, runtimesOut+"iOS 26.2 (26.2 - 23C54) - "+rtOld+"\n", simA)
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "installed after all") {
			t.Errorf("%v", err)
		}
	})
	t.Run("the device is not listed as unavailable any more", func(t *testing.T) {
		sb, _, c := plan(t)
		simctlAnswers(sb, runtimesOut) // nothing unavailable
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "no longer unavailable") {
			t.Errorf("%v", err)
		}
	})
	t.Run("another device is listed, not this one", func(t *testing.T) {
		sb, _, c := plan(t)
		simctlAnswers(sb, runtimesOut, simB)
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "no longer unavailable") {
			t.Errorf("%v", err)
		}
	})
	t.Run("CoreSimulator stopped answering", func(t *testing.T) {
		sb, _, c := plan(t)
		sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "xcrun", "simctl", "list", "runtimes")
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "CoreSimulator did not list any runtime") {
			t.Errorf("%v", err)
		}
	})
	t.Run("the device was booted after planning", func(t *testing.T) {
		sb, dir, c := plan(t)
		sb.Runner.Stub(sys.Result{Stdout: "3\n"}, nil, "plutil", "-extract", "state", "raw", filepath.Join(dir, "device.plist"))
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "not shut down") {
			t.Errorf("%v", err)
		}
	})
	t.Run("the device was used after planning", func(t *testing.T) {
		sb, dir, c := plan(t)
		sb.WriteFile(t, filepath.Join(dir, "device.plist"), 100, time.Minute)
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "changed in the last 3 days") {
			t.Errorf("%v", err)
		}
	})
	t.Run("something opened it after planning", func(t *testing.T) {
		sb, dir, c := plan(t)
		sb.Runner.Stub(sys.Result{Stdout: "COMMAND PID\ncom.apple 1 saint txt\n"}, nil, "lsof", "-w", "+D", dir)
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "something has it open") {
			t.Errorf("%v", err)
		}
	})
	t.Run("the device folder vanished", func(t *testing.T) {
		sb, dir, c := plan(t)
		if err := os.RemoveAll(dir); err != nil {
			t.Fatal(err)
		}
		if err := simRule().Recheck(ctx, depsFor(sb), c); err == nil {
			t.Error("a device that is gone cannot be deleted")
		}
	})
}
