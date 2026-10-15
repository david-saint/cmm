package rules

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/sys"
)

// The three things this rule can do, as pseudo-paths: Docker's cleanups are commands, not folders. Volumes are
// not among them, on purpose: a volume can hold a database nobody has a copy of.
const (
	dockerImages     = "docker: unused images"
	dockerContainers = "docker: stopped containers"
	dockerBuildCache = "docker: build cache"

	// dockerDFFormat makes `docker system df` print one tab-separated row per kind.
	dockerDFFormat = "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}"

	// dockerTolerance is how much more than planned `docker system df` may report when asked again before a
	// prune runs (a container stopped meanwhile, a fresh layer) before the plan is considered out of date.
	dockerTolerance    = 128 * 1000 * 1000
	dockerDFTimeout    = 2 * time.Minute
	dockerPruneTimeout = 15 * time.Minute

	// dockerInside is where a prune's space is freed: inside Docker's own disk image, not on the Mac directly.
	dockerInside = "Docker's disk image"
	// dockerWhere is said once per item, in its note.
	dockerWhere = "frees space inside " + dockerInside
)

// procDockerWork holds the rule back while Docker is building, pulling, pushing or composing: a prune then
// could pull the cache or an image from under it. Running containers do not matter (a prune never removes them).
var procDockerWork = guard.ProcSpec{Pattern: `[d]ocker( |-)(build|buildx|builder|compose|pull|push|image build)( |$)`}

// dockerKind is one cleanup: the row of `docker system df` it is sized from, the exact command that does it,
// and what a person should know before choosing it.
type dockerKind struct {
	path string
	row  string
	args []string
	note string
}

var dockerKinds = []dockerKind{
	{dockerImages, "Images", []string{"image", "prune", "-a", "-f"},
		"docker image prune -a: images you built must be rebuilt, the rest are pulled again; " + dockerWhere},
	{dockerContainers, "Containers", []string{"container", "prune", "-f"},
		"docker container prune: anything kept only inside a stopped container is lost, volumes are never touched; " + dockerWhere},
	{dockerBuildCache, "Build Cache", []string{"builder", "prune", "-f"},
		"docker builder prune: the next builds are slower once; " + dockerWhere},
}

func dockerKindFor(path string) (dockerKind, bool) {
	for _, k := range dockerKinds {
		if k.path == path {
			return k, true
		}
	}
	return dockerKind{}, false
}

var (
	dockerSizeRE      = regexp.MustCompile(`(?i)^([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?b)(?:\s|$)`)
	dockerReclaimedRE = regexp.MustCompile(`(?i)total(?: reclaimed space)?:\s*([0-9]+(?:\.[0-9]+)?\s*[kmgt]?b)(?:\s|$)`)
)

// parseDockerSize reads a size the way Docker prints it ("1.5kB", "150MB", "8.1GB (65%)"): decimal units, and
// anything after the unit is ignored. Anything that is not a plain non-negative size is not a size.
func parseDockerSize(s string) (int64, bool) {
	m := dockerSizeRE.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, false
	}
	mult := map[string]float64{"b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12}[strings.ToLower(m[2])]
	return int64(math.Round(v * mult)), true
}

// parseDockerReclaimed finds "Total reclaimed space: 1.2GB" (image and container prune) or "Total: 3.4GB"
// (builder prune) in a prune's output.
func parseDockerReclaimed(out string) (int64, bool) {
	m := dockerReclaimedRE.FindStringSubmatch(out)
	if m == nil {
		return 0, false
	}
	return parseDockerSize(m[1])
}

var (
	errDockerMissing    = errors.New("docker is not installed")
	errDockerDown       = errors.New("Docker is not running (start Docker Desktop to see what can be cleaned)")
	errDockerUnreadable = errors.New("docker system df gave an answer that was not understood")
)

// dockerDown tells "the daemon is not there" from other failures by what the docker client says.
func dockerDown(stderr string) bool {
	s := strings.ToLower(stderr)
	return strings.Contains(s, "cannot connect to the docker daemon") ||
		strings.Contains(s, "docker daemon running") ||
		strings.Contains(s, "error during connect")
}

// DockerRule offers Docker's own prunes for unused images, stopped containers and build cache. Sizes come from
// `docker system df` (what Docker itself says it could reclaim); nothing is deleted by cmm: each item is one
// prune command, run only after the usual re-checks. The items are review tier, never part of a plain apply, and
// volumes are never offered.
type DockerRule struct {
	RuleID   string
	Label    string
	MinBytes int64 // a kind that would reclaim less than this is not worth an item
	Tier     Tier  // empty means TierReview
}

// ID implements Rule.
func (r *DockerRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *DockerRule) Group() string { return r.Label }

func (r *DockerRule) tier() Tier {
	if r.Tier == "" {
		return TierReview
	}
	return r.Tier
}

// idle returns an error with the reason if Docker is busy building or pulling, or if that cannot be checked.
func (r *DockerRule) idle(ctx context.Context, d Deps) error {
	return blockedBy(ctx, d, r.Label, []guard.ProcSpec{procDockerWork}, "a docker build, pull or compose is running")
}

// usage asks Docker what each kind could reclaim, in bytes by item path.
func (r *DockerRule) usage(ctx context.Context, d Deps) (map[string]int64, error) {
	ctx, cancel := context.WithTimeout(ctx, dockerDFTimeout)
	defer cancel()
	res, err := d.Env.Runner.Run(ctx, "docker", "system", "df", "--format", dockerDFFormat)
	if err != nil {
		if sys.IsNotFound(err) {
			return nil, errDockerMissing
		}
		return nil, fmt.Errorf("could not run docker system df (%v)", err)
	}
	if res.ExitCode != 0 {
		if dockerDown(res.Stderr) {
			return nil, errDockerDown
		}
		return nil, commandFailure("docker system df", res)
	}

	byRow := map[string]int64{}
	for _, line := range strings.Split(res.Stdout, "\n") {
		cols := strings.Split(strings.TrimSpace(line), "\t")
		if len(cols) != 3 {
			continue
		}
		if b, ok := parseDockerSize(cols[2]); ok {
			byRow[strings.TrimSpace(cols[0])] = b
		}
	}
	if len(byRow) == 0 && strings.TrimSpace(res.Stdout) != "" {
		return nil, errDockerUnreadable
	}
	out := map[string]int64{}
	for _, k := range dockerKinds {
		out[k.path] = byRow[k.row]
	}
	return out, nil
}

// Plan implements Rule.
func (r *DockerRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	if err := r.idle(ctx, d); err != nil {
		return nil, []Skip{{Reason: err.Error()}}, nil
	}
	use, err := r.usage(ctx, d)
	if err != nil {
		if errors.Is(err, errDockerMissing) {
			return nil, nil, nil
		}
		return nil, []Skip{{Reason: fmt.Sprintf("%s: %v", r.Label, err)}}, nil
	}
	var items []Candidate
	for _, k := range dockerKinds {
		if b := use[k.path]; b > 0 && b >= r.MinBytes {
			items = append(items, Candidate{Rule: r.RuleID, Group: r.Label, Path: k.path, Bytes: b, Tier: r.tier(), Action: ActionCommand, Note: k.note, FreesInside: dockerInside})
		}
	}
	return items, nil, nil
}

// Allows implements Rule: the three action names, and nothing else.
func (r *DockerRule) Allows(_ Deps, p string) bool {
	_, ok := dockerKindFor(p)
	return ok
}

// Recheck implements Rule: Docker must still be idle and running, and it must not now offer to remove much
// more than the plan said (a container stopped since then would be pruned too without the owner having seen it).
func (r *DockerRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	if _, ok := dockerKindFor(c.Path); !ok {
		return fmt.Errorf("%s: %q is not one of Docker's cleanups", r.Label, c.Path)
	}
	if err := r.idle(ctx, d); err != nil {
		return err
	}
	use, err := r.usage(ctx, d)
	if err != nil {
		return fmt.Errorf("%s: %v", r.Label, err)
	}
	if now := use[c.Path]; now > c.Bytes+c.Bytes/10+dockerTolerance {
		return fmt.Errorf("%s: %s would now remove more than was planned (%s instead of %s): plan again", r.Label, c.Path, humanBytes(now), humanBytes(c.Bytes))
	}
	return nil
}

// Execute implements Executor: exactly the prune that belongs to the item, then its exit status. The size Docker
// reports is returned when it says one (0B is an answer too); otherwise -1 tells the engine to use the planned size.
func (r *DockerRule) Execute(ctx context.Context, d Deps, c Candidate) (int64, error) {
	k, ok := dockerKindFor(c.Path)
	if !ok {
		return 0, fmt.Errorf("%s: %q is not one of Docker's cleanups", r.Label, c.Path)
	}
	ctx, cancel := context.WithTimeout(ctx, dockerPruneTimeout)
	defer cancel()
	what := "docker " + strings.Join(k.args, " ")
	res, err := d.Env.Runner.Run(ctx, "docker", k.args...)
	if err != nil {
		return 0, fmt.Errorf("could not run %s (%v)", what, err)
	}
	if res.ExitCode != 0 {
		return 0, commandFailure(what, res)
	}
	if freed, ok := parseDockerReclaimed(res.Stdout); ok {
		return freed, nil
	}
	return -1, nil
}
