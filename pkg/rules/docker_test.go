package rules

import (
	"errors"
	"os/exec"
	"regexp"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/sys/systest"
)

// dfFormat is the format string the rule must pass to `docker system df`.
const dfFormat = "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}"

func stubDockerDF(sb *systest.Sandbox, out string) {
	sb.Runner.Stub(sys.Result{Stdout: out}, nil, "docker", "system", "df", "--format", dfFormat)
}

func dockerIdle(sb *systest.Sandbox) {
	sb.Runner.Stub(sys.Result{ExitCode: 1}, nil, "pgrep", "-f", procDockerWork.Pattern)
}

// dockerSample is what `docker system df` prints; the volumes row must never turn into an item.
const dockerSample = "Images\t12.34GB\t8.1GB (65%)\n" +
	"Containers\t150MB\t150MB (100%)\n" +
	"Local Volumes\t5.2GB\t2.1GB (40%)\n" +
	"Build Cache\t3.4GB\t3.4GB\n"

func dockerRule() *DockerRule { return docker() }

func regexpFor(t *testing.T, pattern string) *regexp.Regexp {
	t.Helper()
	re, err := regexp.Compile(pattern)
	if err != nil {
		t.Fatalf("the guard pattern %q does not compile: %v", pattern, err)
	}
	return re
}

// commandLines is every command the fake runner was asked to run, as "name arg arg".
func commandLines(sb *systest.Sandbox) []string {
	var out []string
	for _, c := range sb.Runner.Calls() {
		out = append(out, c.Name+" "+strings.Join(c.Args, " "))
	}
	return out
}

func TestDocker_Identity(t *testing.T) {
	r := dockerRule()
	if r.ID() != "docker" || r.Group() != "Docker: unused images, stopped containers and build cache (review first)" {
		t.Errorf("identity wrong: %q %q", r.ID(), r.Group())
	}
}

func TestDocker_PlansOneReviewItemPerKindAndNeverVolumes(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	stubDockerDF(sb, dockerSample)

	items, skips, err := dockerRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	want := []struct {
		path  string
		bytes int64
	}{
		{"docker: unused images", 8_100_000_000},
		{"docker: stopped containers", 150_000_000},
		{"docker: build cache", 3_400_000_000},
	}
	if len(items) != len(want) {
		t.Fatalf("one item per kind expected: %+v", items)
	}
	for i, w := range want {
		c := items[i]
		if c.Path != w.path || c.Bytes != w.bytes || c.Tier != TierReview || c.Action != ActionCommand || c.Group != dockerRule().Group() || c.Note == "" {
			t.Errorf("item %d = %+v, want %s %d review command with a note", i, c, w.path, w.bytes)
		}
		if strings.Contains(strings.ToLower(c.Path+c.Note), "volume prune") {
			t.Errorf("volumes are never offered: %+v", c)
		}
		if !strings.Contains(c.Note, "disk image") {
			t.Errorf("the note must say where the space is freed (Docker's disk image): %q", c.Note)
		}
		if len(c.Note) > 170 {
			t.Errorf("a note is read in a plan line: keep it short (%d characters): %q", len(c.Note), c.Note)
		}
		if !strings.Contains(c.Note, "docker "+strings.Split(c.Path, ": ")[0]) && !strings.Contains(c.Note, "prune") {
			t.Errorf("the note should name the command that will run: %q", c.Note)
		}
	}
}

func TestDocker_ParsesDockersSizes(t *testing.T) {
	cases := []struct {
		in   string
		want int64
		ok   bool
	}{
		{"0B", 0, true},
		{"512B", 512, true},
		{"1.5kB", 1500, true},
		{"1.5KB", 1500, true},
		{"150MB", 150_000_000, true},
		{"8.1GB (65%)", 8_100_000_000, true},
		{"3.4GB", 3_400_000_000, true},
		{"2.01GB", 2_010_000_000, true}, // 2.01 * 1e9 in floating point is 2009999999.9999998: round, never truncate
		{"2.09GB (3%)", 2_090_000_000, true},
		{"2TB", 2_000_000_000_000, true},
		{"  7MB  ", 7_000_000, true},
		{"", 0, false},
		{"N/A", 0, false},
		{"MB", 0, false},
		{"-5MB", 0, false},
		{"12 parsecs", 0, false},
		{"1.2.3GB", 0, false},
	}
	for _, c := range cases {
		got, ok := parseDockerSize(c.in)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("parseDockerSize(%q) = %d, %v; want %d, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestDocker_NothingReclaimableIsSilent(t *testing.T) {
	for name, out := range map[string]string{
		"nothing to reclaim": "Images\t1GB\t0B (0%)\nContainers\t0B\t0B\nLocal Volumes\t2GB\t2GB (100%)\nBuild Cache\t0B\t0B\n",
		"empty output":       "",
		"only volumes":       "Local Volumes\t5.2GB\t2.1GB (40%)\n",
	} {
		sb := systest.NewSandbox(t)
		dockerIdle(sb)
		stubDockerDF(sb, out)
		items, skips, err := dockerRule().Plan(ctx, depsFor(sb))
		if err != nil || len(items) != 0 || len(skips) != 0 {
			t.Errorf("%s: want nothing and no noise, got %v %v %v", name, items, skips, err)
		}
	}
}

func TestDocker_PartialOrUnknownRowsAreReadAsFarAsTheyGo(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	stubDockerDF(sb, "Images\t1GB\t500MB (50%)\nSomething New\t1GB\t900MB\nContainers\tgarbage\n\n")
	items, skips, _ := dockerRule().Plan(ctx, depsFor(sb))
	if len(items) != 1 || items[0].Path != "docker: unused images" || items[0].Bytes != 500_000_000 || len(skips) != 0 {
		t.Errorf("only what is understood is planned: %+v %v", items, skips)
	}
}

func TestDocker_AnswerNobodyCanReadIsASkipNotASilentZero(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	stubDockerDF(sb, "this is not what docker prints\nneither is this\n")
	items, skips, _ := dockerRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "not understood") {
		t.Errorf("unreadable output must be reported: %+v %+v", items, skips)
	}
}

func TestDocker_NotInstalledIsSilent(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	sb.Runner.Stub(sys.Result{}, &exec.Error{Name: "docker", Err: exec.ErrNotFound}, "docker", "system", "df", "--format", dfFormat)
	items, skips, err := dockerRule().Plan(ctx, depsFor(sb))
	if err != nil || len(items) != 0 || len(skips) != 0 {
		t.Errorf("no Docker, nothing to say: %v %v %v", items, skips, err)
	}
}

func TestDocker_NotRunningIsASkipThatSaysSo(t *testing.T) {
	for _, stderr := range []string{
		"Cannot connect to the Docker daemon at unix:///Users/x/.docker/run/docker.sock. Is the docker daemon running?\n",
		"error during connect: Get \"http://%2FUsers%2Fx%2F.docker%2Frun%2Fdocker.sock/v1.47/system/df\": dial unix: connect: no such file or directory\n",
	} {
		sb := systest.NewSandbox(t)
		dockerIdle(sb)
		sb.Runner.Stub(sys.Result{ExitCode: 1, Stderr: stderr}, nil, "docker", "system", "df", "--format", dfFormat)
		items, skips, err := dockerRule().Plan(ctx, depsFor(sb))
		if err != nil || len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "Docker is not running") {
			t.Errorf("stderr %q: want one skip saying Docker is not running: %v %v %v", stderr, items, skips, err)
		}
	}
}

func TestDocker_OtherFailuresAreSkipsWithTheEndOfWhatDockerSaid(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	sb.Runner.Stub(sys.Result{ExitCode: 125, Stderr: "permission denied while trying to connect\n"}, nil, "docker", "system", "df", "--format", dfFormat)
	_, skips, _ := dockerRule().Plan(ctx, depsFor(sb))
	if len(skips) != 1 || !strings.Contains(skips[0].Reason, "status 125") || !strings.Contains(skips[0].Reason, "permission denied") {
		t.Errorf("skips = %+v", skips)
	}

	sb = systest.NewSandbox(t)
	dockerIdle(sb)
	sb.Runner.Stub(sys.Result{}, errors.New("timed out"), "docker", "system", "df", "--format", dfFormat)
	_, skips, _ = dockerRule().Plan(ctx, depsFor(sb))
	if len(skips) != 1 || !strings.Contains(skips[0].Reason, "timed out") {
		t.Errorf("a command that cannot run is a skip: %+v", skips)
	}
}

func TestDocker_ABuildOrPullInProgressBlocksPlanningAndAsksNothing(t *testing.T) {
	sb := systest.NewSandbox(t)
	sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-f", procDockerWork.Pattern) // something is running
	items, skips, err := dockerRule().Plan(ctx, depsFor(sb))
	if err != nil || len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "docker build") {
		t.Fatalf("want one skip naming the guard: %v %v %v", items, skips, err)
	}
	for _, call := range commandLines(sb) {
		if strings.HasPrefix(call, "docker ") {
			t.Errorf("docker must not even be asked while the guard says no: %s", call)
		}
	}
}

func TestDocker_AGuardThatCannotAnswerIsASkip(t *testing.T) {
	sb := systest.NewSandbox(t)
	sb.Runner.Stub(sys.Result{ExitCode: 2}, nil, "pgrep", "-f", procDockerWork.Pattern)
	items, skips, _ := dockerRule().Plan(ctx, depsFor(sb))
	if len(items) != 0 || len(skips) != 1 || !strings.Contains(skips[0].Reason, "could not check") {
		t.Errorf("items=%v skips=%v", items, skips)
	}
}

func TestDocker_TheGuardLooksForBuildsPullsAndComposeNotForRunningContainers(t *testing.T) {
	re := regexpFor(t, procDockerWork.Pattern)
	for _, line := range []string{
		"docker build -t app .", "docker buildx build --push .", "docker builder prune -f", "docker pull alpine",
		"docker push me/app", "docker compose up -d", "docker-compose up", "/usr/local/bin/docker image build .",
	} {
		if !re.MatchString(line) {
			t.Errorf("%q should hold the rule back", line)
		}
	}
	for _, line := range []string{"docker run -it alpine sh", "docker ps", "docker system df", "dockerd", "com.docker.backend", "vim docker-notes.txt"} {
		if re.MatchString(line) {
			t.Errorf("%q must not hold the rule back", line)
		}
	}
}

func TestDocker_AllowsOnlyItsThreeCommandNames(t *testing.T) {
	r := dockerRule()
	sb := systest.NewSandbox(t)
	for _, p := range []string{"docker: unused images", "docker: stopped containers", "docker: build cache"} {
		if !r.Allows(depsFor(sb), p) {
			t.Errorf("%q should be allowed", p)
		}
	}
	for _, p := range []string{"", "docker", "docker: volumes", "docker: volume prune", "docker: system prune", "docker: unused images ", "/var/lib/docker", "/Users/x/Library/Containers/com.docker.docker", sb.Env.Home} {
		if r.Allows(depsFor(sb), p) {
			t.Errorf("%q must not be allowed", p)
		}
	}
}

// ---- Recheck ----

func dockerCandidate(t *testing.T, sb *systest.Sandbox, path string) Candidate {
	t.Helper()
	dockerIdle(sb)
	stubDockerDF(sb, dockerSample)
	items, _, _ := dockerRule().Plan(ctx, depsFor(sb))
	for _, c := range items {
		if c.Path == path {
			return c
		}
	}
	t.Fatalf("no item for %s in %+v", path, items)
	return Candidate{}
}

func TestDocker_RecheckPassesWhenNothingChanged(t *testing.T) {
	sb := systest.NewSandbox(t)
	c := dockerCandidate(t, sb, "docker: unused images")
	if err := dockerRule().Recheck(ctx, depsFor(sb), c); err != nil {
		t.Errorf("Recheck() = %v", err)
	}
}

func TestDocker_RecheckRefusesWhenMoreWouldNowGo(t *testing.T) {
	sb := systest.NewSandbox(t)
	c := dockerCandidate(t, sb, "docker: stopped containers") // planned: 150 MB
	// a container was stopped since the plan: 150 MB + 10% + 128 MB tolerance is the limit
	stubDockerDF(sb, "Containers\t900MB\t600MB (66%)\n")
	if err := dockerRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "plan again") {
		t.Errorf("a much bigger reclaimable size must be refused: %v", err)
	}
	// a little growth is within the tolerance
	stubDockerDF(sb, "Containers\t400MB\t290MB (70%)\n")
	if err := dockerRule().Recheck(ctx, depsFor(sb), c); err != nil {
		t.Errorf("growth within the tolerance is fine: %v", err)
	}
	// less than planned is always fine
	stubDockerDF(sb, "Containers\t1MB\t1MB (100%)\n")
	if err := dockerRule().Recheck(ctx, depsFor(sb), c); err != nil {
		t.Errorf("less to remove is fine: %v", err)
	}
}

func TestDocker_RecheckRefusesWhenTheGuardOrDockerNoLongerHolds(t *testing.T) {
	sb := systest.NewSandbox(t)
	c := dockerCandidate(t, sb, "docker: build cache")

	sb.Runner.Stub(sys.Result{ExitCode: 0}, nil, "pgrep", "-f", procDockerWork.Pattern)
	if err := dockerRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "docker build") {
		t.Errorf("a build started since the plan: %v", err)
	}

	dockerIdle(sb)
	sb.Runner.Stub(sys.Result{ExitCode: 1, Stderr: "Cannot connect to the Docker daemon. Is the docker daemon running?"}, nil, "docker", "system", "df", "--format", dfFormat)
	if err := dockerRule().Recheck(ctx, depsFor(sb), c); err == nil || !strings.Contains(err.Error(), "not running") {
		t.Errorf("Docker was quit since the plan: %v", err)
	}

	if err := dockerRule().Recheck(ctx, depsFor(sb), Candidate{Path: "docker: volumes", Bytes: 1}); err == nil {
		t.Error("an unknown action must be refused")
	}
}

// ---- Execute ----

func TestDocker_ExecuteRunsExactlyTheMatchingPruneAndNothingElse(t *testing.T) {
	cases := []struct {
		path string
		args []string
		out  string
		want int64
	}{
		{"docker: unused images", []string{"image", "prune", "-a", "-f"}, "Deleted Images:\nuntagged: x\n\nTotal reclaimed space: 7.9GB\n", 7_900_000_000},
		{"docker: stopped containers", []string{"container", "prune", "-f"}, "Deleted Containers:\nabc\n\nTotal reclaimed space: 150MB\n", 150_000_000},
		{"docker: build cache", []string{"builder", "prune", "-f"}, "abc123\ndef456\nTotal:\t3.4GB\n", 3_400_000_000},
	}
	for _, c := range cases {
		sb := systest.NewSandbox(t) // an unstubbed command fails the test loudly: nothing else may run
		sb.Runner.Stub(sys.Result{Stdout: c.out}, nil, "docker", c.args...)
		freed, err := dockerRule().Execute(ctx, depsFor(sb), Candidate{Path: c.path, Bytes: 1})
		if err != nil || freed != c.want {
			t.Errorf("%s: freed=%d err=%v, want %d", c.path, freed, err, c.want)
		}
		calls := commandLines(sb)
		if len(calls) != 1 || calls[0] != "docker "+strings.Join(c.args, " ") {
			t.Errorf("%s: calls = %q", c.path, calls)
		}
	}
}

func TestDocker_ExecuteNeverRunsAVolumeOrSystemPrune(t *testing.T) {
	sb := systest.NewSandbox(t)
	for _, p := range []string{"docker: volumes", "docker: volume prune", "docker: system prune", "docker", "/var/lib/docker", ""} {
		if _, err := dockerRule().Execute(ctx, depsFor(sb), Candidate{Path: p}); err == nil {
			t.Errorf("%q must not be carried out", p)
		}
	}
	if calls := commandLines(sb); len(calls) != 0 {
		t.Errorf("nothing may be started for an unknown action: %q", calls)
	}
}

func TestDocker_ExecuteReportsFailuresAndUnknownOutput(t *testing.T) {
	sb := systest.NewSandbox(t)
	sb.Runner.Stub(sys.Result{ExitCode: 1, Stderr: "Error response from daemon: a prune operation is already running\n"}, nil, "docker", "image", "prune", "-a", "-f")
	if _, err := dockerRule().Execute(ctx, depsFor(sb), Candidate{Path: "docker: unused images", Bytes: 1}); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Errorf("a failing prune is an error with Docker's words: %v", err)
	}

	sb = systest.NewSandbox(t)
	sb.Runner.Stub(sys.Result{}, errors.New("could not start"), "docker", "container", "prune", "-f")
	if _, err := dockerRule().Execute(ctx, depsFor(sb), Candidate{Path: "docker: stopped containers", Bytes: 1}); err == nil {
		t.Error("a command that cannot start is an error")
	}

	sb = systest.NewSandbox(t)
	sb.Runner.Stub(sys.Result{Stdout: "done\n"}, nil, "docker", "builder", "prune", "-f")
	freed, err := dockerRule().Execute(ctx, depsFor(sb), Candidate{Path: "docker: build cache", Bytes: 5})
	if err != nil || freed != -1 {
		t.Errorf("no size in the output means -1, so the engine uses the planned size: %d %v", freed, err)
	}

	sb = systest.NewSandbox(t)
	sb.Runner.Stub(sys.Result{Stdout: "Total reclaimed space: 0B\n"}, nil, "docker", "container", "prune", "-f")
	freed, err = dockerRule().Execute(ctx, depsFor(sb), Candidate{Path: "docker: stopped containers", Bytes: 5})
	if err != nil || freed != 0 {
		t.Errorf("Docker saying it reclaimed 0B is believed, not replaced by the plan's figure: %d %v", freed, err)
	}
}

// What `docker system df` really printed on the owner's Mac (Docker 29.8.2): note the kB unit, the row that
// reclaims almost nothing, and the build cache row without a percentage.
const dockerReal = "Images\t28.82GB\t19.35GB (67%)\n" +
	"Containers\t117.7MB\t57.34kB (0%)\n" +
	"Local Volumes\t1.001GB\t881.6MB (88%)\n" +
	"Build Cache\t11.95GB\t411.8MB\n"

func TestDocker_PlansFromRealDockerOutputAndSkipsWhatIsNotWorthAnItem(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	stubDockerDF(sb, dockerReal)

	items, skips, err := dockerRule().Plan(ctx, depsFor(sb))
	if err != nil || len(skips) != 0 {
		t.Fatalf("Plan() = %v, %v, %v", items, skips, err)
	}
	if len(items) != 2 || items[0].Path != "docker: unused images" || items[0].Bytes != 19_350_000_000 ||
		items[1].Path != "docker: build cache" || items[1].Bytes != 411_800_000 {
		t.Errorf("images and build cache are worth an item; 57 kB of containers and the volumes are not: %+v", items)
	}
}

func TestDocker_TheSizeThresholdIsTheRulesOwn(t *testing.T) {
	sb := systest.NewSandbox(t)
	dockerIdle(sb)
	stubDockerDF(sb, "Images\t1GB\t900MB (90%)\nContainers\t10MB\t10MB (100%)\nBuild Cache\t5MB\t5MB\n")

	r := dockerRule()
	r.MinBytes = 10_000_000 // exactly the containers: the threshold itself counts
	items, _, _ := r.Plan(ctx, depsFor(sb))
	if len(items) != 2 || items[1].Path != "docker: stopped containers" {
		t.Errorf("an item of exactly the minimum is listed, one below it is not: %+v", items)
	}
	r.MinBytes = 1
	if items, _, _ = r.Plan(ctx, depsFor(sb)); len(items) != 3 {
		t.Errorf("with a tiny minimum everything is listed: %+v", items)
	}
}
