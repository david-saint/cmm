package rules

import (
	"context"
	"errors"
	"fmt"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/sys"
)

const (
	// brewAction is the one pseudo-path this rule plans: Homebrew's cleanup is a command, not a folder.
	brewAction = "homebrew: cleanup"
	// brewListed is the size from which an old version is named on its own in the plan's note.
	brewListed = 20 * mb
	// brewTolerance is how much more than planned `brew cleanup` may report when asked again before it runs
	// (rounding to 0.1 GB, new download caches) before the plan is considered out of date.
	brewTolerance = 128 * mb
	brewTimeout   = 10 * time.Minute
)

// brewEnv keeps Homebrew from updating itself, phoning home or printing hints while cmm runs it.
var brewEnv = []string{"HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_ENV_HINTS=1"}

var (
	brewTotalRE = regexp.MustCompile(`approximately ([0-9.]+) ?([KMG]?B)`)
	brewSizeRE  = regexp.MustCompile(`^([0-9.]+) ?([KMG]?B)$`)
)

// parseBrewSize turns "1.3" and "GB" into bytes (Homebrew counts in powers of 1024).
func parseBrewSize(num, unit string) (int64, bool) {
	v, err := strconv.ParseFloat(num, 64)
	if err != nil || v < 0 {
		return 0, false
	}
	mult := map[string]float64{"B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30}[unit]
	if mult == 0 {
		return 0, false
	}
	return int64(v * mult), true
}

// parseBrewTotal finds "approximately 1.3GB" in brew's output.
func parseBrewTotal(out string) (int64, bool) {
	m := brewTotalRE.FindStringSubmatch(out)
	if m == nil {
		return 0, false
	}
	return parseBrewSize(m[1], m[2])
}

// parseWouldRemove reads one "Would remove: <path> (<n> files, <size>)" line of a dry run and names what it
// is: "<formula> <version>" for a keg in the Cellar, "Homebrew housekeeping: <folder>/<name>" for the rest.
// A size that cannot be read is 0; the name still counts.
func parseWouldRemove(line string) (name string, bytes int64, ok bool) {
	const prefix = "Would remove: "
	if !strings.HasPrefix(line, prefix) {
		return "", 0, false
	}
	rest := strings.TrimSpace(line[len(prefix):])
	if rest == "" {
		return "", 0, false
	}
	p, meta := rest, ""
	if i := strings.LastIndex(rest, " ("); i >= 0 && strings.HasSuffix(rest, ")") {
		p, meta = rest[:i], rest[i+2:len(rest)-1]
	}

	if _, after, found := strings.Cut(p, "/Cellar/"); found {
		formula, _, _ := strings.Cut(after, "/")
		name = formula + " " + path.Base(p)
	} else {
		name = "Homebrew housekeeping: " + path.Base(path.Dir(p)) + "/" + path.Base(p)
	}

	size := meta
	if i := strings.LastIndex(meta, ", "); i >= 0 {
		size = meta[i+2:]
	}
	if m := brewSizeRE.FindStringSubmatch(strings.TrimSpace(size)); m != nil {
		bytes, _ = parseBrewSize(m[1], m[2])
	}
	return name, bytes, true
}

// humanBytes writes a size the way the plan's notes do: "1.2 GB", "800 MB", "512 KB".
func humanBytes(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%d MB", n>>20)
	default:
		return fmt.Sprintf("%d KB", n>>10)
	}
}

type brewEntry struct {
	name  string
	bytes int64
}

// brewDryRun is what `brew cleanup -n` printed.
type brewDryRun struct {
	total   int64
	hasSum  bool
	entries []brewEntry
}

// note describes the old versions in a way a person can judge: the big ones by name, the rest counted, and a
// warning when a Python version goes (virtualenvs point at one).
func (b *brewDryRun) note() string {
	var listed []string
	var smallN int
	var smallBytes int64
	python := false
	for _, e := range b.entries {
		if strings.HasPrefix(e.name, "python") {
			python = true
		}
		if e.bytes >= brewListed {
			listed = append(listed, fmt.Sprintf("%s (%s)", e.name, humanBytes(e.bytes)))
		} else {
			smallN++
			smallBytes += e.bytes
		}
	}
	parts := []string{}
	if len(listed) > 0 {
		parts = append(parts, strings.Join(listed, ", "))
	}
	if smallN > 0 {
		parts = append(parts, fmt.Sprintf("+ %d smaller old versions (%s)", smallN, humanBytes(smallBytes)))
	}
	if python {
		parts = append(parts, "a Python version is in this list: a virtualenv that points at the old one needs recreating")
	}
	return strings.Join(parts, "; ")
}

// HomebrewRule runs Homebrew's own `brew cleanup` (old versions of installed formulae, stale downloads). The
// plan comes from `brew cleanup -n`, which names what would go; nothing is guessed and no folder is removed
// by cmm itself.
type HomebrewRule struct {
	RuleID string
	Label  string
	Tier   Tier // empty means TierSafe
}

// ID implements Rule.
func (r *HomebrewRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *HomebrewRule) Group() string { return r.Label }

func (r *HomebrewRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

// brew runs brew with Homebrew's noise switched off.
func (r *HomebrewRule) brew(ctx context.Context, d Deps, args ...string) (sys.Result, error) {
	ctx, cancel := context.WithTimeout(ctx, brewTimeout)
	defer cancel()
	cmd := append(append([]string{}, brewEnv...), "brew")
	return d.Env.Runner.Run(ctx, "env", append(cmd, args...)...)
}

// idle returns an error with the reason if brew is running or that cannot be checked.
func (r *HomebrewRule) idle(ctx context.Context, d Deps) error {
	return blockedBy(ctx, d, r.Label, []guard.ProcSpec{procBrew}, "brew is running")
}

// errBrewMissing marks a machine without Homebrew; it is not worth a word.
var errBrewMissing = errors.New("brew is not installed")

// commandFailure describes a command that did not succeed, with the end of what it said.
func commandFailure(what string, res sys.Result) error {
	msg := strings.TrimSpace(res.Stderr)
	if msg == "" {
		msg = strings.TrimSpace(res.Stdout)
	}
	if len(msg) > 300 {
		msg = msg[len(msg)-300:]
	}
	return fmt.Errorf("%s exited with status %d: %s", what, res.ExitCode, msg)
}

// dryRun asks brew what it would remove.
func (r *HomebrewRule) dryRun(ctx context.Context, d Deps) (*brewDryRun, error) {
	res, err := r.brew(ctx, d, "cleanup", "-n")
	if err != nil {
		return nil, fmt.Errorf("could not run brew cleanup -n (%v)", err)
	}
	if res.ExitCode == 127 {
		return nil, errBrewMissing
	}
	if res.ExitCode != 0 {
		return nil, commandFailure("brew cleanup -n", res)
	}
	out := &brewDryRun{}
	out.total, out.hasSum = parseBrewTotal(res.Stdout)
	for _, line := range strings.Split(res.Stdout, "\n") {
		if name, bytes, ok := parseWouldRemove(strings.TrimSpace(line)); ok {
			out.entries = append(out.entries, brewEntry{name, bytes})
		}
	}
	return out, nil
}

// Plan implements Rule.
func (r *HomebrewRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	if err := r.idle(ctx, d); err != nil {
		return nil, []Skip{{Reason: err.Error()}}, nil
	}
	dry, err := r.dryRun(ctx, d)
	if err != nil {
		if errors.Is(err, errBrewMissing) {
			return nil, nil, nil
		}
		return nil, []Skip{{Reason: fmt.Sprintf("%s: %v", r.Label, err)}}, nil
	}
	if !dry.hasSum {
		if len(dry.entries) > 0 {
			return nil, []Skip{{Reason: r.Label + ": brew listed things to remove but gave no total, so its output was not understood"}}, nil
		}
		return nil, nil, nil // nothing to clean
	}
	if dry.total <= 0 {
		return nil, nil, nil
	}
	return []Candidate{{
		Rule: r.RuleID, Group: r.Label, Path: brewAction, Bytes: dry.total, Tier: r.tier(), Action: ActionCommand,
		Note: dry.note(),
	}}, nil, nil
}

// Allows implements Rule: the one action name.
func (r *HomebrewRule) Allows(_ Deps, p string) bool { return p == brewAction }

// Recheck implements Rule: brew must still be idle, and a fresh dry run must not promise much more than the
// plan did (an upgrade since then would have turned other versions into candidates the owner never saw).
func (r *HomebrewRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	if c.Path != brewAction {
		return fmt.Errorf("%s: %q is not Homebrew's cleanup", r.Label, c.Path)
	}
	if err := r.idle(ctx, d); err != nil {
		return err
	}
	dry, err := r.dryRun(ctx, d)
	if err != nil {
		return fmt.Errorf("%s: %v", r.Label, err)
	}
	if dry.hasSum && dry.total > c.Bytes+c.Bytes/10+brewTolerance {
		return fmt.Errorf("%s: brew would now remove more than was planned (%s instead of %s): plan again", r.Label, humanBytes(dry.total), humanBytes(c.Bytes))
	}
	return nil
}

// Execute implements Executor: `brew cleanup`, then its exit status. The size brew reports as freed is
// returned when it says one (0B is an answer too); otherwise -1 tells the engine to use the planned size.
func (r *HomebrewRule) Execute(ctx context.Context, d Deps, c Candidate) (int64, error) {
	if c.Path != brewAction {
		return 0, fmt.Errorf("%s: %q is not Homebrew's cleanup", r.Label, c.Path)
	}
	res, err := r.brew(ctx, d, "cleanup")
	if err != nil {
		return 0, fmt.Errorf("could not run brew cleanup (%v)", err)
	}
	if res.ExitCode != 0 {
		return 0, commandFailure("brew cleanup", res)
	}
	if freed, ok := parseBrewTotal(res.Stdout); ok {
		return freed, nil
	}
	return -1, nil
}
