package rules

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/david-saint/cmm/pkg/guard"
)

// expand turns a path template into a path, or reports that the template is not acceptable. Templates must
// start with "~/" (the home directory) or "{tmp}/" (the per-user temp directory) and continue with a plain
// relative path (no empty, "." or ".." elements); anything else is refused, so no rule can name a path outside
// those two roots, not even by climbing out of them.
func expand(d Deps, tmpl string) (string, bool) {
	switch {
	case strings.HasPrefix(tmpl, "~/") && d.Env.Home != "" && plainRelative(tmpl[2:]):
		return filepath.Join(d.Env.Home, tmpl[2:]), true
	case strings.HasPrefix(tmpl, "{tmp}/") && d.Env.TmpDir != "" && plainRelative(tmpl[6:]):
		return filepath.Join(d.Env.TmpDir, tmpl[6:]), true
	}
	return "", false
}

// plainRelative reports whether rel is a non-empty slash-separated path whose elements are all real names.
func plainRelative(rel string) bool {
	if rel == "" {
		return false
	}
	for _, part := range strings.Split(rel, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

// expandRoot is expand for a folder whose children are the targets: it also accepts the bare "{tmp}".
func expandRoot(d Deps, tmpl string) (string, bool) {
	if tmpl == "{tmp}" {
		if d.Env.TmpDir == "" {
			return "", false
		}
		return d.Env.TmpDir, true
	}
	return expand(d, tmpl)
}

// blockedBy returns an error with the reason if one of the processes runs, or if that cannot be checked
// (a guard that cannot answer never counts as "not running").
func blockedBy(ctx context.Context, d Deps, label string, block []guard.ProcSpec, msg string) error {
	if len(block) == 0 {
		return nil
	}
	running, _, err := d.Guard.AnyRunning(ctx, block...)
	if err != nil {
		return fmt.Errorf("%s: could not check whether the tools using it are running (%v)", label, err)
	}
	if running {
		return fmt.Errorf("%s: %s", label, msg)
	}
	return nil
}
