// Package systest builds sandboxed environments for tests: a fake home and temp dir inside t.TempDir(), a
// FakeRunner and a controllable clock. A test that uses a Sandbox cannot reach the real home directory, the
// real temp dir or any real command.
package systest

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
)

// TB is the subset of testing.TB the helpers need (so tests can also observe a failing helper).
type TB interface {
	Helper()
	Fatalf(format string, args ...any)
	TempDir() string
}

// Sandbox is an isolated machine. Env.Home and Env.TmpDir live under Root.
type Sandbox struct {
	Root   string
	Env    *sys.Env
	Runner *sys.FakeRunner

	mu  sync.Mutex
	now time.Time
}

// NewSandbox creates a sandbox under t.TempDir() with a fixed clock (2026-10-14 12:00 UTC).
func NewSandbox(t TB) *Sandbox {
	t.Helper()
	root := t.TempDir()
	s := &Sandbox{
		Root:   root,
		Runner: sys.NewFakeRunner(),
		now:    time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC),
	}
	home := filepath.Join(root, "home")
	tmp := filepath.Join(root, "tmp")
	for _, d := range []string{home, tmp} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("systest: cannot create %s: %v", d, err)
		}
	}
	s.Env = &sys.Env{Home: home, TmpDir: tmp, Now: s.clock, Runner: s.Runner}
	return s
}

func (s *Sandbox) clock() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.now
}

// Advance moves the sandbox clock forward.
func (s *Sandbox) Advance(d time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.now = s.now.Add(d)
}

// Home joins elements onto the sandbox home directory.
func (s *Sandbox) Home(elem ...string) string {
	return filepath.Join(append([]string{s.Env.Home}, elem...)...)
}

// Tmp joins elements onto the sandbox temp directory.
func (s *Sandbox) Tmp(elem ...string) string {
	return filepath.Join(append([]string{s.Env.TmpDir}, elem...)...)
}

// RequireInside fails the test unless path is strictly inside the sandbox root.
func (s *Sandbox) RequireInside(t TB, path string) {
	t.Helper()
	clean := filepath.Clean(path)
	if clean != path || !strings.HasPrefix(clean, s.Root+string(filepath.Separator)) {
		t.Fatalf("systest: %q is outside the sandbox %q", path, s.Root)
	}
}

// WriteFile creates a file of the given size inside the sandbox and sets its modification time to age before
// the sandbox clock. Parent directories are created and keep the current time.
func (s *Sandbox) WriteFile(t TB, path string, size int, age time.Duration) {
	t.Helper()
	s.RequireInside(t, path)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("systest: %v", err)
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("x", size)), 0o644); err != nil {
		t.Fatalf("systest: %v", err)
	}
	s.Age(t, path, age)
}

// Age sets the modification time of one path to age before the sandbox clock.
func (s *Sandbox) Age(t TB, path string, age time.Duration) {
	t.Helper()
	s.RequireInside(t, path)
	ts := s.clock().Add(-age)
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatalf("systest: %v", err)
	}
}

// BackdateTree sets the modification time of root and everything below it, directories included, to age
// before the sandbox clock. Call it after the tree is complete: creating files later changes directory times.
// Symbolic links are skipped (they have no portable way to be re-timed).
func (s *Sandbox) BackdateTree(t TB, root string, age time.Duration) {
	t.Helper()
	s.RequireInside(t, root)
	ts := s.clock().Add(-age)
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		return os.Chtimes(p, ts, ts)
	})
	if err != nil {
		t.Fatalf("systest: %v", err)
	}
}
