package rules

import (
	"errors"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

var brewEnvArgs = []string{"HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_ENV_HINTS=1", "brew"}

// brewCmd is the command line the rule must use: brew with Homebrew's update, analytics and hint noise off.
func brewCmd(args ...string) []string { return append(append([]string{}, brewEnvArgs...), args...) }

func stubBrew(sb *systest.Sandbox, res sys.Result, err error, args ...string) {
	sb.Runner.Stub(res, err, "env", brewCmd(args...)...)
}

func brewIdle(sb *systest.Sandbox) {
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "pgrep", "-f", procBrew.Pattern)
}

const brewSample = `Would remove: /opt/homebrew/Cellar/boost/1.85.0 (15,123 files, 1.2GB)
Would remove: /opt/homebrew/Cellar/python@3.14/3.14.7 (3,456 files, 800.0MB)
Would remove: /opt/homebrew/Cellar/jq/1.7 (30 files, 1.1MB)
Would remove: /opt/homebrew/Cellar/wget/1.24 (50 files, 4.0MB)
Would remove: /Users/saint/Library/Caches/Homebrew/downloads/abc--bottle.tar.gz (123.4MB)
Would remove: /Users/saint/Library/Caches/Homebrew/Cask/tiny--1.0.dmg (2.0MB)
==> This operation would free approximately 2.2GB of disk space.
`

func brewRule() *HomebrewRule { return homebrew() }

func TestHomebrew_Identity(t *testing.T) {
	r := brewRule()
	if r.ID() != "homebrew" || r.Group() != "Homebrew: old versions of installed formulae (brew cleanup)" {
		t.Errorf("identity wrong: %q %q", r.ID(), r.Group())
	}
}

func TestHomebrew_PlansBrewsOwnCleanupAndNamesWhatGoes(t *testing.T) {
	sb := systest.NewSandbox(t)
	brewIdle(sb)
	stubBrew(sb, sys.Result{Stdout: brewSample, Stderr: "Warning: Skipping python: most recent version 3.14.8 not installed\n"}, nil, "cleanup", "-n")

	items, skips, err := brewRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	if len(items) != 1 {
		t.Fatalf("one command item expected: %+v", items)
	}
	c := items[0]
	if c.Path != "homebrew: cleanup" || c.Action != ActionCommand || c.Tier != TierSafe || c.Group != brewRule().Group() {
		t.Errorf("unexpected candidate %+v", c)
	}
	if want := int64(2362232012); c.Bytes != want { // "approximately 2.2GB", truncated like brew's own rounding allows
		t.Errorf("Bytes = %d, want %d (brew's own total)", c.Bytes, want)
	}
	want := "boost 1.85.0 (1.2 GB), python@3.14 3.14.7 (800 MB), Homebrew housekeeping: downloads/abc--bottle.tar.gz (123 MB); " +
		"+ 3 smaller old versions (7 MB); " +
		"a Python version is in this list: a virtualenv that points at the old one needs recreating"
	if c.Note != want {
		t.Errorf("Note =\n%q\nwant\n%q", c.Note, want)
	}
}

func TestHomebrew_NoPythonNoWarningAndNothingSmall(t *testing.T) {
	sb := systest.NewSandbox(t)
	brewIdle(sb)
	stubBrew(sb, sys.Result{Stdout: "Would remove: /opt/homebrew/Cellar/ffmpeg/7.0 (900 files, 300.0MB)\n==> This operation would free approximately 300.0MB of disk space.\n"}, nil, "cleanup", "-n")
	items, _, _ := brewRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Note != "ffmpeg 7.0 (300 MB)" {
		t.Fatalf("%+v", items)
	}
}

func TestHomebrew_NamesVersionsFrom20MBUp(t *testing.T) {
	sb := systest.NewSandbox(t)
	brewIdle(sb)
	stubBrew(sb, sys.Result{Stdout: "Would remove: /opt/homebrew/Cellar/small/1 (10 files, 19.9MB)\n" +
		"Would remove: /opt/homebrew/Cellar/edge/1 (10 files, 20.0MB)\n" +
		"Would remove: /opt/homebrew/Cellar/over/1 (10 files, 20.1MB)\n" +
		"==> This operation would free approximately 60.0MB of disk space.\n"}, nil, "cleanup", "-n")
	items, _, _ := brewRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Note != "edge 1 (20 MB), over 1 (20 MB); + 1 smaller old versions (19 MB)" {
		t.Fatalf("exactly 20 MB is named, just under is counted: %+v", items)
	}
}

func TestHomebrew_NothingToCleanIsSilent(t *testing.T) {
	for name, out := range map[string]string{
		"empty output":           "",
		"only a status line":     "==> Nothing to clean up\n",
		"warnings on stdout too": "Warning: Skipping foo: most recent version 1 not installed\n",
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			brewIdle(sb)
			stubBrew(sb, sys.Result{Stdout: out}, nil, "cleanup", "-n")
			if items, skips, err := brewRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 || err != nil {
				t.Fatalf("nothing to say: %v %v %v", items, skips, err)
			}
		})
	}
}

func TestHomebrew_ListedItemsWithoutATotalAreReported(t *testing.T) {
	sb := systest.NewSandbox(t)
	brewIdle(sb)
	stubBrew(sb, sys.Result{Stdout: "Would remove: /opt/homebrew/Cellar/jq/1.7 (30 files, 1.1MB)\n"}, nil, "cleanup", "-n")
	items, skips, _ := brewRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "no total") {
		t.Fatalf("brew output that cannot be read must not pass silently: %v %v", items, skips)
	}
}

func TestHomebrew_BrewRunningOrUnknownSkipsWithoutRunningBrew(t *testing.T) {
	for name, c := range map[string]struct {
		res    sys.Result
		reason string
	}{
		"running":          {sys.Result{ExitCode: 0}, "brew is running"},
		"cannot be judged": {sys.Result{ExitCode: 2}, "could not check"},
	} {
		t.Run(name, func(t *testing.T) {
			sb := systest.NewSandbox(t)
			sb.Runner.Stub(c.res, nil, "pgrep", "-f", procBrew.Pattern)
			stubBrew(sb, sys.Result{Stdout: brewSample}, nil, "cleanup", "-n")
			items, skips, _ := brewRule().Plan(ctx, depsFor(sb))
			if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, c.reason) {
				t.Fatalf("%v %v", items, skips)
			}
			for _, call := range sb.Runner.Calls() {
				if call.Name == "env" {
					t.Errorf("brew must not be started: %v", call)
				}
			}
		})
	}
}

func TestHomebrew_BrewProblems(t *testing.T) {
	t.Run("not installed is not worth a word", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		brewIdle(sb)
		stubBrew(sb, sys.Result{ExitCode: 127, Stderr: "env: brew: No such file or directory"}, nil, "cleanup", "-n")
		if items, skips, _ := brewRule().Plan(ctx, depsFor(sb)); len(items) != 0 || len(skips) != 0 {
			t.Fatalf("%v %v", items, skips)
		}
	})
	t.Run("a failing dry run is reported", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		brewIdle(sb)
		stubBrew(sb, sys.Result{ExitCode: 1, Stdout: brewSample, Stderr: "Error: boom"}, nil, "cleanup", "-n")
		items, skips, _ := brewRule().Plan(ctx, depsFor(sb))
		if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "status 1") || !strings.Contains(skips[0].Reason, "boom") {
			t.Fatalf("a dry run that failed cannot be trusted, whatever it printed: %v %v", items, skips)
		}
	})
	t.Run("cannot be started", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		brewIdle(sb)
		stubBrew(sb, sys.Result{}, errors.New("fork/exec: resource temporarily unavailable"), "cleanup", "-n")
		items, skips, _ := brewRule().Plan(ctx, depsFor(sb))
		if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "resource temporarily unavailable") {
			t.Fatalf("%v %v", items, skips)
		}
	})
}

func TestHomebrew_ParsesWhatBrewPrints(t *testing.T) {
	for _, c := range []struct {
		out   string
		bytes int64
		ok    bool
	}{
		{"==> This operation would free approximately 1.3GB of disk space.", 1395864371, true},
		{"This operation would free approximately 567.8MB of disk space.", 595381452, true},
		{"This operation would free approximately 892.5KB of disk space.", 913920, true},
		{"This operation would free approximately 12B of disk space.", 12, true},
		{"This operation would free approximately 1.3 GB of disk space.", 1395864371, true},
		{"This operation would free approximately 1GB", 1073741824, true},
		{"nothing here", 0, false},
		{"approximately lots", 0, false},
	} {
		got, ok := parseBrewTotal(c.out)
		if ok != c.ok || (ok && got != c.bytes) {
			t.Errorf("parseBrewTotal(%q) = %d, %v; want %d, %v", c.out, got, ok, c.bytes, c.ok)
		}
	}

	for _, c := range []struct {
		line  string
		name  string
		bytes int64
		ok    bool
	}{
		{"Would remove: /opt/homebrew/Cellar/boost/1.85.0 (15,123 files, 1.2GB)", "boost 1.85.0", 1288490188, true},
		{"Would remove: /opt/homebrew/Cellar/python@3.14/3.14.7 (3,456 files, 800.0MB)", "python@3.14 3.14.7", 838860800, true},
		{"Would remove: /usr/local/Cellar/jq/1.7 (30 files, 1.1MB)", "jq 1.7", 1153433, true},
		{"Would remove: /Users/saint/Library/Caches/Homebrew/downloads/abc--x.tar.gz (123.4MB)", "Homebrew housekeeping: downloads/abc--x.tar.gz", 129394278, true},
		{"Would remove: /Users/saint/Library/Caches/Homebrew/downloads/odd (1).dmg (2.0MB)", "Homebrew housekeeping: downloads/odd (1).dmg", 2097152, true},
		{"Would remove: /opt/homebrew/Cellar/x/1 (1 file, 10B)", "x 1", 10, true},
		{"Would remove: /opt/homebrew/Cellar/x/1 (nothing sensible)", "x 1", 0, true},
		{"Would remove: /opt/homebrew/Cellar/x/1", "x 1", 0, true},
		{"Removing: /opt/homebrew/Cellar/x/1... (1 file, 10B)", "", 0, false},
		{"==> Would remove: nothing", "", 0, false},
		{"Would remove: ", "", 0, false},
		{"", "", 0, false},
	} {
		name, bytes, ok := parseWouldRemove(c.line)
		if ok != c.ok || (ok && (name != c.name || bytes != c.bytes)) {
			t.Errorf("parseWouldRemove(%q) = %q, %d, %v; want %q, %d, %v", c.line, name, bytes, ok, c.name, c.bytes, c.ok)
		}
	}
}

func TestHomebrew_AllowsOnlyItsOneActionName(t *testing.T) {
	sb := systest.NewSandbox(t)
	d := depsFor(sb)
	r := brewRule()
	if !r.Allows(d, "homebrew: cleanup") {
		t.Fatal("its own action name must be allowed")
	}
	for _, p := range []string{
		"", "homebrew", "Homebrew: cleanup", "homebrew: cleanup ", " homebrew: cleanup", "homebrew: cleanup2", "homebrew:cleanup",
		"/opt/homebrew", "/opt/homebrew/Cellar", "/opt/homebrew/Cellar/jq/1.7", sb.Home("homebrew: cleanup"), "/homebrew: cleanup",
	} {
		if r.Allows(d, p) {
			t.Errorf("%q must not be allowed", p)
		}
	}
}

func TestHomebrew_ExecuteRunsBrewCleanupAndChecksTheExitStatus(t *testing.T) {
	item := Candidate{Rule: "homebrew", Path: "homebrew: cleanup", Bytes: 1000, Tier: TierSafe, Action: ActionCommand}

	t.Run("works and reports what brew says it freed", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		stubBrew(sb, sys.Result{Stdout: "Removing: /opt/homebrew/Cellar/boost/1.85.0... (15,123 files, 1.2GB)\n==> This operation has freed approximately 1.1GB of disk space.\n"}, nil, "cleanup")
		freed, err := brewRule().Execute(ctx, depsFor(sb), item)
		if err != nil || freed != 1181116006 {
			t.Fatalf("Execute() = %d, %v", freed, err)
		}
		for _, c := range sb.Runner.Calls() {
			if c.Name == "env" && strings.Contains(strings.Join(c.Args, " "), "-n") {
				t.Errorf("the real run must not be a dry run: %v", c)
			}
		}
	})
	t.Run("no freed line: the plan's figure stands", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		stubBrew(sb, sys.Result{Stdout: "done\n"}, nil, "cleanup")
		if freed, err := brewRule().Execute(ctx, depsFor(sb), item); err != nil || freed != -1 {
			t.Errorf("Execute() = %d, %v; -1 tells the engine to use the planned size", freed, err)
		}
	})
	t.Run("brew says it freed nothing: that is believed", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		stubBrew(sb, sys.Result{Stdout: "==> This operation has freed approximately 0B of disk space.\n"}, nil, "cleanup")
		if freed, err := brewRule().Execute(ctx, depsFor(sb), item); err != nil || freed != 0 {
			t.Errorf("Execute() = %d, %v; a reported 0 is a real 0", freed, err)
		}
	})
	t.Run("a failing brew is a failure and says why", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		stubBrew(sb, sys.Result{ExitCode: 1, Stdout: "Removing...\n", Stderr: "Error: Permission denied @ apply2files - /opt/homebrew/Cellar/x\n"}, nil, "cleanup")
		_, err := brewRule().Execute(ctx, depsFor(sb), item)
		if err == nil || !strings.Contains(err.Error(), "status 1") || !strings.Contains(err.Error(), "Permission denied") {
			t.Errorf("%v", err)
		}
	})
	t.Run("cannot be started", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		stubBrew(sb, sys.Result{}, errors.New("no such file"), "cleanup")
		if _, err := brewRule().Execute(ctx, depsFor(sb), item); err == nil {
			t.Error("expected an error")
		}
	})
	t.Run("refuses anything but its own action, before running a command", func(t *testing.T) {
		sb := systest.NewSandbox(t)
		for _, bad := range []string{"", "/opt/homebrew/Cellar", "homebrew: uninstall", sb.Home("x")} {
			c := item
			c.Path = bad
			if _, err := brewRule().Execute(ctx, depsFor(sb), c); err == nil {
				t.Errorf("%q must be refused", bad)
			}
		}
		if n := len(sb.Runner.Calls()); n != 0 {
			t.Errorf("no command may run for a refused action, ran %d", n)
		}
	})
}

func TestHomebrew_RecheckReasksBrewBeforeRunningIt(t *testing.T) {
	plan := func(t *testing.T) (*systest.Sandbox, Candidate) {
		sb := systest.NewSandbox(t)
		brewIdle(sb)
		stubBrew(sb, sys.Result{Stdout: brewSample}, nil, "cleanup", "-n")
		items, _, _ := brewRule().Plan(ctx, depsFor(sb))
		if len(items) != 1 {
			t.Fatalf("setup: %+v", items)
		}
		if err := brewRule().Recheck(ctx, depsFor(sb), items[0]); err != nil {
			t.Fatalf("unchanged, it should pass: %v", err)
		}
		return sb, items[0]
	}
	total := func(s string) sys.Result {
		return sys.Result{Stdout: "Would remove: /opt/homebrew/Cellar/x/1 (1 file, 1MB)\n==> This operation would free approximately " + s + " of disk space.\n"}
	}

	t.Run("brew started after planning", func(t *testing.T) {
		sb, c := plan(t)
		sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-f", procBrew.Pattern)
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "brew is running") {
			t.Errorf("%v", err)
		}
	})
	t.Run("brew would now remove much more", func(t *testing.T) {
		sb, c := plan(t)
		stubBrew(sb, total("6.0GB"), nil, "cleanup", "-n")
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "more than was planned") {
			t.Errorf("a list that grew since the plan was not agreed to: %v", err)
		}
	})
	t.Run("a little more is rounding and new caches", func(t *testing.T) {
		sb, c := plan(t)
		stubBrew(sb, total("2.3GB"), nil, "cleanup", "-n")
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err != nil {
			t.Errorf("%v", err)
		}
	})
	t.Run("less is fine, even nothing", func(t *testing.T) {
		sb, c := plan(t)
		stubBrew(sb, sys.Result{}, nil, "cleanup", "-n")
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err != nil {
			t.Errorf("someone cleaned up in the meantime: %v", err)
		}
	})
	t.Run("the dry run fails", func(t *testing.T) {
		sb, c := plan(t)
		stubBrew(sb, sys.Result{ExitCode: 1, Stderr: "Error: boom"}, nil, "cleanup", "-n")
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "boom") {
			t.Errorf("%v", err)
		}
	})
	t.Run("brew cannot be asked", func(t *testing.T) {
		sb, c := plan(t)
		stubBrew(sb, sys.Result{}, errors.New("gone"), "cleanup", "-n")
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err == nil {
			t.Error("expected an error")
		}
	})
	t.Run("brew was uninstalled", func(t *testing.T) {
		sb, c := plan(t)
		stubBrew(sb, sys.Result{ExitCode: 127}, nil, "cleanup", "-n")
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err == nil {
			t.Error("a missing brew cannot clean anything")
		}
	})
	t.Run("a candidate that is not its own", func(t *testing.T) {
		sb, c := plan(t)
		c.Path = "/opt/homebrew/Cellar"
		if err := brewRule().Recheck(ctx, depsFor(sb), c); err == nil {
			t.Error("expected an error")
		}
	})
}
