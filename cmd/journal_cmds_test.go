package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

// withJournal gives the sandboxed app the journal that the real wiring gives the real engine.
func (a *app) withJournal() *engine.FileJournal {
	j := engine.NewFileJournal(a.sb.Env.Home, a.sb.Env.Clock)
	a.eng.Journal = j
	return j
}

func TestApply_ARealRunKeepsALogAndAStampAndSaysWhere(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}

	log, err := os.ReadFile(j.LogPath())
	if err != nil {
		t.Fatalf("no cleanup log was written: %v", err)
	}
	for _, p := range []string{a.goCache, a.npmCache} {
		if want := "2026-10-14 12:00:00 deleted " + p + "\n"; !strings.Contains(string(log), want) {
			t.Errorf("the log should contain %q:\n%s", want, log)
		}
	}
	stamp, err := os.ReadFile(filepath.Join(j.Dir, engine.StampFile))
	if want := fmt.Sprintf("%d\n", a.sb.Env.Clock().Unix()); err != nil || string(stamp) != want {
		t.Errorf("stamp = %q (err %v), want %q", stamp, err, want)
	}
	if !strings.Contains(o.stdout, "Log: ~/.local/state/cmm/cleanup.log") {
		t.Errorf("a real run should say where the log is:\n%s", o.stdout)
	}
}

func TestEverythingButARealApplyLeavesNoStateBehind(t *testing.T) {
	cases := []struct {
		name  string
		tty   bool
		input string
		args  []string
	}{
		{"plan", true, "", []string{"plan"}},
		{"plan verbose", true, "", []string{"plan", "-v"}},
		{"plan json", true, "", []string{"plan", "--json"}},
		{"dry run", false, "", []string{"apply", "--dry-run"}},
		{"dry run with --yes", true, "", []string{"apply", "--dry-run", "--yes"}},
		{"no terminal", false, "\n", []string{"apply"}},
		{"end of input", true, "", []string{"apply"}},
		{"declined", true, "n\n", []string{"apply"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := newApp(t)
			a.withJournal()
			a.tty = c.tty
			a.run(c.input, c.args...)
			if present(engine.StateDir(a.sb.Env.Home)) {
				t.Errorf("%v must not create the state folder", c.args)
			}
			if !present(a.goCache) || !present(a.npmCache) {
				t.Errorf("%v must not delete anything", c.args)
			}
		})
	}
}

func TestApply_ALogThatCannotBeWrittenIsAWarningNotAFailure(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	a.sb.WriteFile(t, j.Dir, 1, 0) // a file where the state folder should be
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("the cleanup itself worked, so apply must succeed: %v\n%s", o.err, o.stdout)
	}
	if present(a.goCache) || present(a.npmCache) {
		t.Error("both caches must still be deleted")
	}
	if n := strings.Count(o.stderr, "warning: cleanup log:"); n != 1 {
		t.Errorf("two items were deleted but the log problem is told once, got %d:\n%s", n, o.stderr)
	}
	if !strings.Contains(o.stderr, "warning: last-run stamp:") {
		t.Errorf("the stamp problem should be told too:\n%s", o.stderr)
	}
	if strings.Contains(o.stdout, "Log: ") {
		t.Errorf("it must not point at a log that was not written:\n%s", o.stdout)
	}
}

func TestPlanAndApplySayWhenTheLastCleanupWas(t *testing.T) {
	a := newApp(t)
	j := a.withJournal()
	if err := j.Stamp(); err != nil { // a cleanup at the sandbox clock: 2026-10-14 12:00 UTC
		t.Fatal(err)
	}
	a.sb.Advance(3 * 24 * time.Hour)

	for _, args := range [][]string{{"plan"}, {"apply", "--dry-run"}} {
		o := a.run("", args...)
		if !strings.Contains(o.stderr, "Last cleanup: 2026-10-14 (3 days ago)") {
			t.Errorf("%v should say when the last cleanup was:\n%s", args, o.stderr)
		}
		if strings.Contains(o.stdout, "Last cleanup") {
			t.Errorf("%v: the line belongs with the banner, not in the plan on stdout", args)
		}
	}
	if o := a.run("", "plan", "--json"); strings.Contains(o.stdout+o.stderr, "Last cleanup") {
		t.Errorf("--json is for programs and carries no such line:\n%s%s", o.stdout, o.stderr)
	}
}

func TestPlan_SaysNothingAboutAMissingOrImplausibleStamp(t *testing.T) {
	a := newApp(t)
	if o := a.run("", "plan"); strings.Contains(o.stderr, "Last cleanup") {
		t.Errorf("no stamp, no line:\n%s", o.stderr)
	}
	dir := engine.StateDir(a.sb.Env.Home)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, content := range []string{"garbage\n", "99999999999\n", ""} {
		if err := os.WriteFile(filepath.Join(dir, engine.StampFile), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if o := a.run("", "plan"); strings.Contains(o.stderr, "Last cleanup") {
			t.Errorf("stamp %q should not be shown:\n%s", content, o.stderr)
		}
	}
}

func TestLastCleanupLine(t *testing.T) {
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		ago  time.Duration
		want string
	}{
		{2 * time.Hour, "Last cleanup: 2026-10-17 (less than a day ago)"},
		{23*time.Hour + 59*time.Minute, "Last cleanup: 2026-10-16 (less than a day ago)"},
		{24 * time.Hour, "Last cleanup: 2026-10-16 (1 day ago)"},
		{47 * time.Hour, "Last cleanup: 2026-10-15 (1 day ago)"},
		{48 * time.Hour, "Last cleanup: 2026-10-15 (2 days ago)"},
		{40 * 24 * time.Hour, "Last cleanup: 2026-09-07 (40 days ago)"},
		{-2 * time.Hour, "Last cleanup: 2026-10-17 (less than a day ago)"}, // a little clock skew is tolerated
		{-25 * time.Hour, ""}, // more than a day in the future cannot be right
	}
	for _, c := range cases {
		if got := lastCleanupLine(now.Add(-c.ago), now); got != c.want {
			t.Errorf("%v ago: %q, want %q", c.ago, got, c.want)
		}
	}
}

func TestLastCleanupLine_ShowsTheDateInTheClocksTimeZone(t *testing.T) {
	cest := time.FixedZone("CEST", 2*60*60)
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, cest)
	last := time.Date(2026, 10, 16, 23, 30, 0, 0, time.UTC) // 01:30 on the 17th in CEST
	if got, want := lastCleanupLine(last, now), "Last cleanup: 2026-10-17 (less than a day ago)"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestProductionEngine_KeepsAJournalInTheUsersStateFolder(t *testing.T) {
	sb := systest.NewSandbox(t)
	eng := newProductionEngine(sb.Env)
	j, ok := eng.Journal.(*engine.FileJournal)
	if !ok {
		t.Fatalf("the engine built for real use must keep a journal, got %T", eng.Journal)
	}
	if want := filepath.Join(sb.Env.Home, ".local", "state", "cmm", "cleanup.log"); j.LogPath() != want {
		t.Errorf("log path = %q, want %q", j.LogPath(), want)
	}
	if len(eng.Rules) != len(rules.Builtin()) {
		t.Errorf("the real engine runs every built-in rule: %d, want %d", len(eng.Rules), len(rules.Builtin()))
	}
}
