// Package guard answers the questions that must be settled before cmm touches anything: is something using
// this path, is a tool that depends on it running, and has it changed recently.
//
// Every check fails safe. When a question cannot be answered (a command cannot be started, times out or
// returns an unexpected status) the check returns ErrCannotDetermine and callers must skip the item; an
// unanswered question is never read as "not in use".
package guard

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/mattn/go-isatty"
)

// ErrCannotDetermine marks a check that could not be answered. Callers must treat it as "unsafe: skip".
var ErrCannotDetermine = errors.New("guard: cannot determine")

// Guard runs the checks against an Env (so tests can fake the commands and the clock).
type Guard struct {
	Env     *sys.Env
	Timeout time.Duration // per external command; zero means 60 seconds
}

// New returns a Guard for env.
func New(env *sys.Env) *Guard { return &Guard{Env: env} }

func (g *Guard) timeout() time.Duration {
	if g.Timeout > 0 {
		return g.Timeout
	}
	return 60 * time.Second
}

func cannot(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrCannotDetermine, fmt.Sprintf(format, args...))
}

// InUse reports whether any process has a file open at or under path (lsof). A path that does not exist is
// not in use.
//
// lsof exit 1 with empty stdout means nothing is open. Any stdout means something is. A spawn failure, a
// timeout or any other exit status means the question could not be answered.
func (g *Guard) InUse(ctx context.Context, path string) (bool, error) {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false, nil
		}
		return false, cannot("cannot stat %s: %v", path, err)
	}

	args := []string{"-w", path}
	if info.IsDir() {
		args = []string{"-w", "+D", path}
	}
	ctx, cancel := context.WithTimeout(ctx, g.timeout())
	defer cancel()

	res, err := g.Env.Runner.Run(ctx, "lsof", args...)
	if err != nil {
		return false, cannot("lsof failed for %s: %v", path, err)
	}
	if strings.TrimSpace(res.Stdout) != "" {
		return true, nil
	}
	if res.ExitCode == 0 || res.ExitCode == 1 {
		return false, nil
	}
	return false, cannot("lsof exited with status %d for %s", res.ExitCode, path)
}

// ProcSpec names a process to look for: Exact matches the process name (pgrep -x), Pattern is a regular
// expression matched against the full command line (pgrep -f). Exactly one must be set.
type ProcSpec struct {
	Exact   string
	Pattern string
}

func (p ProcSpec) args() ([]string, error) {
	switch {
	case p.Exact != "" && p.Pattern == "":
		return []string{"-x", p.Exact}, nil
	case p.Pattern != "" && p.Exact == "":
		return []string{"-f", p.Pattern}, nil
	}
	return nil, fmt.Errorf("guard: a ProcSpec needs exactly one of Exact or Pattern, got %+v", p)
}

// AnyRunning reports whether any of the processes is running, and which spec matched.
//
// pgrep exit 0 means running and exit 1 means none; any other status, a spawn failure or a timeout is
// ErrCannotDetermine. A positive match is reported even if another spec could not be checked.
func (g *Guard) AnyRunning(ctx context.Context, specs ...ProcSpec) (bool, ProcSpec, error) {
	var failure error
	for _, spec := range specs {
		args, err := spec.args()
		if err != nil {
			return false, ProcSpec{}, err
		}
		res, err := g.runPgrep(ctx, args)
		switch {
		case err != nil:
			failure = cannot("pgrep %s failed: %v", strings.Join(args, " "), err)
		case res.ExitCode == 0:
			return true, spec, nil
		case res.ExitCode == 1:
			// not running
		default:
			failure = cannot("pgrep %s exited with status %d", strings.Join(args, " "), res.ExitCode)
		}
	}
	if failure != nil {
		return false, ProcSpec{}, failure
	}
	return false, ProcSpec{}, nil
}

func (g *Guard) runPgrep(ctx context.Context, args []string) (sys.Result, error) {
	ctx, cancel := context.WithTimeout(ctx, g.timeout())
	defer cancel()
	return g.Env.Runner.Run(ctx, "pgrep", args...)
}

// Recent describes a "was anything touched lately" question, the Go form of
// find <root> -maxdepth N [-prune ...] [-type f] -mmin -M.
type Recent struct {
	Within    time.Duration // modified less than this long ago counts as recent
	MaxDepth  int           // entries deeper than this are ignored (root is depth 0); negative means unlimited
	FilesOnly bool          // only regular files count
	Prune     []string      // directory names that are not entered, at any depth below the root
}

type foundRecent struct{}

func (foundRecent) Error() string { return "found" }

// RecentlyModified reports whether anything under root (the root itself included) was modified within
// o.Within of the Env clock. Timestamps in the future count as recent. If part of the tree cannot be read
// and nothing recent was found elsewhere, the answer is ErrCannotDetermine.
func (g *Guard) RecentlyModified(root string, o Recent) (bool, error) {
	if _, err := os.Lstat(root); err != nil {
		return false, err
	}
	now := g.Env.Clock()
	prune := make(map[string]struct{}, len(o.Prune))
	for _, n := range o.Prune {
		prune[n] = struct{}{}
	}
	unreadable := 0

	walkErr := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			unreadable++
			return nil
		}
		depth := 0
		if p != root {
			rel, _ := filepath.Rel(root, p)
			depth = strings.Count(rel, string(filepath.Separator)) + 1
		}
		if depth > 0 && d.IsDir() {
			if _, skip := prune[d.Name()]; skip {
				return fs.SkipDir
			}
		}

		info, err := d.Info()
		if err != nil {
			unreadable++
			return nil
		}
		if (!o.FilesOnly || info.Mode().IsRegular()) && now.Sub(info.ModTime()) < o.Within {
			return foundRecent{}
		}
		if o.MaxDepth >= 0 && depth >= o.MaxDepth && d.IsDir() {
			return fs.SkipDir
		}
		return nil
	})

	var found foundRecent
	switch {
	case errors.As(walkErr, &found):
		return true, nil
	case walkErr != nil:
		return false, walkErr
	case unreadable > 0:
		return false, cannot("%d unreadable entries under %s", unreadable, root)
	}
	return false, nil
}

// IsTerminal reports whether f is attached to a terminal. /dev/null is a character device but not a terminal.
func IsTerminal(f *os.File) bool {
	return isatty.IsTerminal(f.Fd())
}
