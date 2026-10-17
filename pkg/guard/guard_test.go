package guard

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

var ctx = context.Background()

func newGuard(t *testing.T) (*Guard, *systest.Sandbox) {
	t.Helper()
	sb := systest.NewSandbox(t)
	return New(sb.Env), sb
}

func lsofOutput() string {
	return "COMMAND   PID  USER   FD   TYPE DEVICE SIZE/OFF NODE NAME\nnode    12345 saint  cwd    DIR   1,17      512  123 /x\n"
}

// ---- InUse: exit 1 + empty stdout = free; non-empty stdout = in use; anything else = cannot answer ----

func TestInUse_DirectoryInUse(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("lane", "node_modules")
	sb.WriteFile(t, filepath.Join(dir, "a.js"), 1, 0)
	sb.Runner.Stub(sys.Result{Stdout: lsofOutput(), ExitCode: 0}, nil, "lsof", "-w", "+D", dir)

	inUse, err := g.InUse(ctx, dir)
	if err != nil || !inUse {
		t.Fatalf("InUse() = %v, %v; want true, nil", inUse, err)
	}
}

func TestInUse_DirectoryFree(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("lane", "node_modules")
	sb.WriteFile(t, filepath.Join(dir, "a.js"), 1, 0)
	sb.Runner.Stub(sys.Result{Stdout: "", ExitCode: 1}, nil, "lsof", "-w", "+D", dir)

	inUse, err := g.InUse(ctx, dir)
	if err != nil || inUse {
		t.Fatalf("InUse() = %v, %v; want false, nil", inUse, err)
	}
}

func TestInUse_FileUsesPlainLsof(t *testing.T) {
	g, sb := newGuard(t)
	f := sb.Home("bin", "claude")
	sb.WriteFile(t, f, 1, 0)
	sb.Runner.Stub(sys.Result{Stdout: lsofOutput()}, nil, "lsof", "-w", f)

	inUse, err := g.InUse(ctx, f)
	if err != nil || !inUse {
		t.Fatalf("InUse(file) = %v, %v; want true, nil", inUse, err)
	}
}

func TestInUse_OutputWithExitOneStillMeansInUse(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("d")
	sb.WriteFile(t, filepath.Join(dir, "f"), 1, 0)
	// lsof exits 1 when it printed warnings; rows on stdout still mean something has the file open
	sb.Runner.Stub(sys.Result{Stdout: lsofOutput(), ExitCode: 1}, nil, "lsof", "-w", "+D", dir)

	if inUse, err := g.InUse(ctx, dir); err != nil || !inUse {
		t.Fatalf("InUse() = %v, %v; want true, nil", inUse, err)
	}
}

func TestInUse_UnexpectedExitCodeCannotBeAnswered(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("d")
	sb.WriteFile(t, filepath.Join(dir, "f"), 1, 0)
	sb.Runner.Stub(sys.Result{Stdout: "", ExitCode: 2}, nil, "lsof", "-w", "+D", dir)

	inUse, err := g.InUse(ctx, dir)
	if !errors.Is(err, ErrCannotDetermine) {
		t.Fatalf("exit code 2 must be ErrCannotDetermine, got %v", err)
	}
	if inUse {
		t.Error("an unanswered question must not report in use = true either; the caller decides from the error")
	}
}

func TestInUse_SpawnFailureAndTimeoutCannotBeAnswered(t *testing.T) {
	for name, runErr := range map[string]error{
		"spawn failure": errors.New("exec: lsof: not found"),
		"timeout":       context.DeadlineExceeded,
	} {
		t.Run(name, func(t *testing.T) {
			g, sb := newGuard(t)
			dir := sb.Home("d")
			sb.WriteFile(t, filepath.Join(dir, "f"), 1, 0)
			sb.Runner.Stub(sys.Result{}, runErr, "lsof", "-w", "+D", dir)

			if _, err := g.InUse(ctx, dir); !errors.Is(err, ErrCannotDetermine) {
				t.Fatalf("%s must be ErrCannotDetermine, got %v", name, err)
			}
		})
	}
}

func TestInUse_MissingPathIsFreeWithoutRunningLsof(t *testing.T) {
	g, sb := newGuard(t)
	inUse, err := g.InUse(ctx, sb.Home("does-not-exist"))
	if err != nil || inUse {
		t.Fatalf("InUse(missing) = %v, %v; want false, nil", inUse, err)
	}
	if n := len(sb.Runner.Calls()); n != 0 {
		t.Errorf("no command should run for a missing path, ran %d", n)
	}
}

// ---- AnyRunning: pgrep exit 0 = running, 1 = none, 2+ or failure = cannot answer ----

func TestAnyRunning_ExactName(t *testing.T) {
	g, sb := newGuard(t)
	sb.Runner.Stub(sys.Result{ExitCode: 0, Stdout: "4242\n"}, nil, "pgrep", "-x", "go")

	running, matched, err := g.AnyRunning(ctx, ProcSpec{Exact: "go"})
	if err != nil || !running || matched.Exact != "go" {
		t.Fatalf("AnyRunning() = %v, %+v, %v", running, matched, err)
	}
}

func TestAnyRunning_PatternUsesFullCommandLine(t *testing.T) {
	g, sb := newGuard(t)
	pattern := "[n]pm (install|ci)( |$)"
	sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-f", pattern)

	running, matched, err := g.AnyRunning(ctx, ProcSpec{Pattern: pattern})
	if err != nil || !running || matched.Pattern != pattern {
		t.Fatalf("AnyRunning() = %v, %+v, %v", running, matched, err)
	}
}

func TestAnyRunning_NoneRunning(t *testing.T) {
	g, sb := newGuard(t)
	sb.Runner.StubPrefix(sys.Result{ExitCode: 1}, nil, "pgrep")

	running, _, err := g.AnyRunning(ctx, ProcSpec{Exact: "Xcode"}, ProcSpec{Exact: "xcodebuild"})
	if err != nil || running {
		t.Fatalf("AnyRunning() = %v, %v; want false, nil", running, err)
	}
	if n := len(sb.Runner.Calls()); n != 2 {
		t.Errorf("every spec should be checked, ran %d commands", n)
	}
}

func TestAnyRunning_SecondSpecMatches(t *testing.T) {
	g, sb := newGuard(t)
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "pgrep", "-x", "Xcode")
	sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-x", "xcodebuild")

	running, matched, err := g.AnyRunning(ctx, ProcSpec{Exact: "Xcode"}, ProcSpec{Exact: "xcodebuild"})
	if err != nil || !running || matched.Exact != "xcodebuild" {
		t.Fatalf("AnyRunning() = %v, %+v, %v", running, matched, err)
	}
}

func TestAnyRunning_ErrorsCannotBeAnswered(t *testing.T) {
	cases := map[string]struct {
		res sys.Result
		err error
	}{
		"exit 2":        {res: sys.Result{ExitCode: 2}},
		"exit 3":        {res: sys.Result{ExitCode: 3}},
		"spawn failure": {err: errors.New("exec: pgrep: not found")},
		"timeout":       {err: context.DeadlineExceeded},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			g, sb := newGuard(t)
			sb.Runner.StubPrefix(c.res, c.err, "pgrep")
			running, _, err := g.AnyRunning(ctx, ProcSpec{Exact: "go"})
			if !errors.Is(err, ErrCannotDetermine) {
				t.Fatalf("want ErrCannotDetermine, got %v", err)
			}
			if running {
				t.Error("running must be false when the question could not be answered")
			}
		})
	}
}

func TestAnyRunning_AMatchWinsOverAnErroringSpec(t *testing.T) {
	g, sb := newGuard(t)
	sb.Runner.Stub(sys.Result{ExitCode: 2}, nil, "pgrep", "-x", "a")
	sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-x", "b")

	running, matched, err := g.AnyRunning(ctx, ProcSpec{Exact: "a"}, ProcSpec{Exact: "b"})
	if err != nil || !running || matched.Exact != "b" {
		t.Fatalf("a positive match must be reported even if another check failed: %v %+v %v", running, matched, err)
	}
}

func TestAnyRunning_EmptySpecIsAProgrammingError(t *testing.T) {
	g, _ := newGuard(t)
	if _, _, err := g.AnyRunning(ctx, ProcSpec{}); err == nil || errors.Is(err, ErrCannotDetermine) {
		t.Fatalf("an empty spec should be a plain error, got %v", err)
	}
}

// ---- RecentlyModified ----

func TestRecentlyModified_FileWithinAndBeyondWindow(t *testing.T) {
	g, sb := newGuard(t)
	recent := sb.Home("recent")
	old := sb.Home("old")
	sb.WriteFile(t, filepath.Join(recent, "a"), 1, 2*24*time.Hour)
	sb.WriteFile(t, filepath.Join(old, "a"), 1, 20*24*time.Hour)
	sb.BackdateTree(t, old, 20*24*time.Hour)

	opts := Recent{Within: 5 * 24 * time.Hour, MaxDepth: -1}
	if got, err := g.RecentlyModified(recent, opts); err != nil || !got {
		t.Errorf("recent tree: got %v, %v; want true", got, err)
	}
	if got, err := g.RecentlyModified(old, opts); err != nil || got {
		t.Errorf("old tree: got %v, %v; want false", got, err)
	}
}

// BSD find -mtime rounds up to whole days; this check works in exact minutes.
func TestRecentlyModified_HalfDayEdgeOfTheFiveDayLine(t *testing.T) {
	opts := Recent{Within: 5 * 24 * time.Hour, MaxDepth: -1}
	for name, c := range map[string]struct {
		age  time.Duration
		want bool
	}{
		"4.5 days is still recent": {108 * time.Hour, true},
		"5.5 days is idle":         {132 * time.Hour, false},
	} {
		t.Run(name, func(t *testing.T) {
			g, sb := newGuard(t)
			dir := sb.Home("lane")
			sb.WriteFile(t, filepath.Join(dir, "src", "a.js"), 1, 0)
			sb.BackdateTree(t, dir, c.age)
			got, err := g.RecentlyModified(dir, opts)
			if err != nil || got != c.want {
				t.Fatalf("got %v, %v; want %v", got, err, c.want)
			}
		})
	}
}

func TestRecentlyModified_MaxDepth(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("dd")
	deep := filepath.Join(dir, "a", "b", "c", "fresh.log") // depth 4 below dir
	sb.WriteFile(t, deep, 1, 0)
	sb.BackdateTree(t, dir, 30*24*time.Hour)
	sb.Age(t, deep, 0) // only the depth-4 file is fresh

	if got, _ := g.RecentlyModified(dir, Recent{Within: 24 * time.Hour, MaxDepth: 3}); got {
		t.Error("an entry deeper than MaxDepth must be ignored")
	}
	if got, _ := g.RecentlyModified(dir, Recent{Within: 24 * time.Hour, MaxDepth: 4}); !got {
		t.Error("an entry at exactly MaxDepth must count")
	}
	if got, _ := g.RecentlyModified(dir, Recent{Within: 24 * time.Hour, MaxDepth: -1}); !got {
		t.Error("MaxDepth -1 means unlimited")
	}
}

func TestRecentlyModified_RootItselfCounts(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("dd")
	sb.WriteFile(t, filepath.Join(dir, "f"), 1, 30*24*time.Hour)
	sb.Age(t, dir, 0) // directory fresh, content old

	if got, _ := g.RecentlyModified(dir, Recent{Within: time.Hour, MaxDepth: -1}); !got {
		t.Error("the root directory's own time must count, like find starting at the root")
	}
}

func TestRecentlyModified_FilesOnly(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("lane")
	sb.WriteFile(t, filepath.Join(dir, "sub", "old.txt"), 1, 30*24*time.Hour)
	sb.Age(t, filepath.Join(dir, "sub"), 0) // fresh directory, old file
	sb.Age(t, dir, 0)

	if got, _ := g.RecentlyModified(dir, Recent{Within: time.Hour, MaxDepth: -1}); !got {
		t.Error("without FilesOnly a fresh directory counts")
	}
	if got, _ := g.RecentlyModified(dir, Recent{Within: time.Hour, MaxDepth: -1, FilesOnly: true}); got {
		t.Error("with FilesOnly only regular files count")
	}
}

func TestRecentlyModified_PrunedDirectoriesAreSkipped(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("lane")
	sb.WriteFile(t, filepath.Join(dir, "src", "a.js"), 1, 30*24*time.Hour)
	sb.WriteFile(t, filepath.Join(dir, "node_modules", "pkg", "i.js"), 1, 0) // fresh, but inside node_modules
	sb.WriteFile(t, filepath.Join(dir, "ios", "Pods", "P", "p.h"), 1, 0)
	sb.WriteFile(t, filepath.Join(dir, ".git", "HEAD"), 1, 0)
	sb.BackdateTree(t, filepath.Join(dir, "src"), 30*24*time.Hour)
	for _, d := range []string{dir, filepath.Join(dir, "ios")} {
		sb.Age(t, d, 30*24*time.Hour)
	}

	opts := Recent{Within: 24 * time.Hour, MaxDepth: -1, FilesOnly: true, Prune: []string{"node_modules", "Pods", ".git"}}
	if got, err := g.RecentlyModified(dir, opts); err != nil || got {
		t.Errorf("fresh files inside pruned directories must be ignored: got %v, %v", got, err)
	}
	opts.Prune = nil
	if got, _ := g.RecentlyModified(dir, opts); !got {
		t.Error("without pruning the fresh files must be found")
	}
}

func TestRecentlyModified_FutureTimestampCountsAsRecent(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("d")
	sb.WriteFile(t, filepath.Join(dir, "f"), 1, -48*time.Hour) // two days in the future
	sb.Age(t, dir, 30*24*time.Hour)

	if got, _ := g.RecentlyModified(dir, Recent{Within: time.Hour, MaxDepth: -1}); !got {
		t.Error("a timestamp in the future (clock skew) must be treated as recent")
	}
}

func TestRecentlyModified_UnreadableDirectoryFailsSafe(t *testing.T) {
	g, sb := newGuard(t)
	dir := sb.Home("d")
	locked := filepath.Join(dir, "locked")
	sb.WriteFile(t, filepath.Join(locked, "hidden"), 1, 0)
	sb.BackdateTree(t, dir, 30*24*time.Hour)
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(locked, 0o755)

	_, err := g.RecentlyModified(dir, Recent{Within: time.Hour, MaxDepth: -1})
	if !errors.Is(err, ErrCannotDetermine) {
		t.Fatalf("an unreadable directory with nothing recent elsewhere must be ErrCannotDetermine, got %v", err)
	}

	// but a positive finding elsewhere is still a clear answer
	sb.WriteFile(t, filepath.Join(dir, "fresh"), 1, 0)
	if got, err := g.RecentlyModified(dir, Recent{Within: time.Hour, MaxDepth: -1}); err != nil || !got {
		t.Errorf("a fresh file elsewhere settles the question: got %v, %v", got, err)
	}
}

func TestRecentlyModified_MissingRootIsAnError(t *testing.T) {
	g, sb := newGuard(t)
	if _, err := g.RecentlyModified(sb.Home("nope"), Recent{Within: time.Hour, MaxDepth: -1}); err == nil {
		t.Fatal("expected an error for a missing root")
	}
}

// ---- IsTerminal: the no-human-no-deletion guard depends on this being right for /dev/null and pipes ----

func TestIsTerminal_NotForPipesFilesOrDevNull(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	if IsTerminal(r) || IsTerminal(w) {
		t.Error("a pipe is not a terminal")
	}

	f, err := os.Create(filepath.Join(t.TempDir(), "f"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if IsTerminal(f) {
		t.Error("a regular file is not a terminal")
	}

	null, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer null.Close()
	if IsTerminal(null) {
		t.Error("/dev/null is a character device but must NOT count as a terminal")
	}
}

func TestNew_DefaultTimeout(t *testing.T) {
	g := New(&sys.Env{})
	if g.timeout() != 60*time.Second {
		t.Errorf("default timeout should be 60s, got %v", g.timeout())
	}
	g.Timeout = 5 * time.Second
	if g.timeout() != 5*time.Second || !strings.Contains(ErrCannotDetermine.Error(), "cannot determine") {
		t.Errorf("timeout override or error text wrong")
	}
}

// The single test that runs a real tool (read-only, on a temp dir): it pins down how the real lsof answers,
// including for a /var/folders path where /var is a symlink to /private/var.
func TestInUse_RealLsofOnATempDir(t *testing.T) {
	if _, err := exec.LookPath("lsof"); err != nil {
		t.Skip("lsof is not installed")
	}
	dir := t.TempDir()
	f, err := os.Create(filepath.Join(dir, "held"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	g := New(&sys.Env{Runner: sys.ExecRunner{}})
	if inUse, err := g.InUse(ctx, dir); err != nil || !inUse {
		t.Fatalf("a directory with an open file must be in use: got %v, %v", inUse, err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	if inUse, err := g.InUse(ctx, dir); err != nil || inUse {
		t.Fatalf("after closing, the directory must be free: got %v, %v", inUse, err)
	}
}
