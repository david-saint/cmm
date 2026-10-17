package sys

import (
	"context"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// Env is everything a rule may read from the machine. Production code gets it from DefaultEnv; tests build
// one inside a sandbox (see package systest) so nothing real is ever touched.
type Env struct {
	Home   string           // the user's home directory, cleaned, unresolved
	TmpDir string           // per-user temp dir as reported by getconf, without a trailing slash
	Now    func() time.Time // the clock; nil means time.Now
	Runner Runner
}

// Clock returns the current time from the injected clock, or time.Now when none is set.
func (e *Env) Clock() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

// NormalizeTmpDir validates the per-user temp dir and strips one trailing slash.
//
// It only accepts the form getconf reports, /var/folders/<xx>/<hash>/T. The path is never resolved through
// symlinks: /var links to /private/var, and mixing the two forms between a root and a target is exactly the
// kind of mismatch that makes a prefix check pass or fail by accident.
func NormalizeTmpDir(p string) (string, error) {
	p = strings.TrimSuffix(p, "/")
	if p == "" || !filepath.IsAbs(p) || filepath.Clean(p) != p {
		return "", fmt.Errorf("sys: %q is not a clean absolute path", p)
	}
	if ok, _ := path.Match("/var/folders/*/*/T", p); !ok {
		return "", fmt.Errorf("sys: %q does not look like a per-user temp dir (/var/folders/*/*/T)", p)
	}
	return p, nil
}

// DefaultEnv reads the real machine: the home directory, the per-user temp dir from
// `getconf DARWIN_USER_TEMP_DIR` (never $TMPDIR or os.TempDir(), which callers can override) and the real clock.
func DefaultEnv() (*Env, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("sys: cannot find the home directory: %w", err)
	}
	home = filepath.Clean(home)
	if home == "/" || !filepath.IsAbs(home) {
		return nil, fmt.Errorf("sys: unexpected home directory %q", home)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	res, err := ExecRunner{}.Run(ctx, "getconf", "DARWIN_USER_TEMP_DIR")
	if err != nil {
		return nil, fmt.Errorf("sys: getconf DARWIN_USER_TEMP_DIR failed: %w", err)
	}
	if res.ExitCode != 0 {
		return nil, fmt.Errorf("sys: getconf DARWIN_USER_TEMP_DIR exited with status %d", res.ExitCode)
	}
	tmp, err := NormalizeTmpDir(strings.TrimSpace(res.Stdout))
	if err != nil {
		return nil, err
	}
	return &Env{Home: home, TmpDir: tmp, Now: time.Now, Runner: ExecRunner{}}, nil
}
