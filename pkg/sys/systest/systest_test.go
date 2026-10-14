package systest

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
)

// recordingTB lets a test observe the failure of a helper without failing itself.
type recordingTB struct {
	testing.TB
	failed bool
	msg    string
}

func (r *recordingTB) Helper() {}
func (r *recordingTB) Fatalf(format string, args ...any) {
	r.failed = true
	r.msg = fmt.Sprintf(format, args...)
	panic("fatal") // stop the helper the way a real Fatalf would
}

func expectFatal(t *testing.T, fn func(tb *recordingTB)) *recordingTB {
	t.Helper()
	tb := &recordingTB{TB: t}
	func() {
		defer func() { _ = recover() }()
		fn(tb)
	}()
	return tb
}

func TestNewSandbox_HomeAndTmpAreInsideRoot(t *testing.T) {
	sb := NewSandbox(t)
	for _, p := range []string{sb.Env.Home, sb.Env.TmpDir} {
		if !strings.HasPrefix(p, sb.Root+string(filepath.Separator)) {
			t.Errorf("%q is not inside the sandbox root %q", p, sb.Root)
		}
		if st, err := os.Stat(p); err != nil || !st.IsDir() {
			t.Errorf("%q should exist as a directory (err=%v)", p, err)
		}
	}
}

func TestSandbox_UsesFakeRunnerAndControlledClock(t *testing.T) {
	sb := NewSandbox(t)
	if _, ok := sb.Env.Runner.(*sys.FakeRunner); !ok {
		t.Fatalf("sandbox runner must be a *sys.FakeRunner, got %T", sb.Env.Runner)
	}
	before := sb.Env.Clock()
	sb.Advance(48 * time.Hour)
	if got := sb.Env.Clock().Sub(before); got != 48*time.Hour {
		t.Errorf("Advance should move the clock by 48h, moved %v", got)
	}
}

func TestSandbox_RequireInside(t *testing.T) {
	sb := NewSandbox(t)
	sb.RequireInside(t, filepath.Join(sb.Env.Home, "x", "y")) // must not fail

	tb := expectFatal(t, func(tb *recordingTB) { sb.RequireInside(tb, "/Users/someone/Library") })
	if !tb.failed {
		t.Error("RequireInside must fail for a path outside the sandbox")
	}
	tb = expectFatal(t, func(tb *recordingTB) { sb.RequireInside(tb, sb.Root+"-evil/x") })
	if !tb.failed {
		t.Error("a sibling directory that merely shares the prefix must be rejected")
	}
}

func TestSandbox_WriteBackdatesFile(t *testing.T) {
	sb := NewSandbox(t)
	p := sb.Home("lane", "src", "a.js")
	sb.WriteFile(t, p, 10, 30*24*time.Hour)

	st, err := os.Stat(p)
	if err != nil {
		t.Fatalf("file not created: %v", err)
	}
	if st.Size() != 10 {
		t.Errorf("expected 10 bytes, got %d", st.Size())
	}
	age := sb.Env.Clock().Sub(st.ModTime())
	if age < 29*24*time.Hour || age > 31*24*time.Hour {
		t.Errorf("file should be about 30 days old, is %v", age)
	}
}

func TestSandbox_BackdateTreeCoversDirectories(t *testing.T) {
	sb := NewSandbox(t)
	root := sb.Home("lane")
	sb.WriteFile(t, filepath.Join(root, "a", "b", "c.txt"), 1, 0)
	sb.BackdateTree(t, root, 10*24*time.Hour)

	for _, p := range []string{root, filepath.Join(root, "a"), filepath.Join(root, "a", "b"), filepath.Join(root, "a", "b", "c.txt")} {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if age := sb.Env.Clock().Sub(st.ModTime()); age < 9*24*time.Hour {
			t.Errorf("%s was not backdated (age %v)", p, age)
		}
	}
}

func TestSandbox_RefusesToWriteOutsideItself(t *testing.T) {
	sb := NewSandbox(t)
	tb := expectFatal(t, func(tb *recordingTB) { sb.WriteFile(tb, "/tmp/cmm-should-never-be-written", 1, 0) })
	if !tb.failed {
		t.Error("WriteFile must refuse paths outside the sandbox")
	}
	if _, err := os.Stat("/tmp/cmm-should-never-be-written"); err == nil {
		t.Error("a file outside the sandbox was created")
	}
}
