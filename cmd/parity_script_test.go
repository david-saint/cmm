package cmd

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// scripts/parity.sh compares cmm's plan with dev-cleanup's on a real machine. These tests drive it with a fake
// dev-cleanup (same shape: arrays, the plan marker, a delete step) and a fake cmm, entirely inside a temp dir.

const (
	lblGo      = "Go build cache"
	lblNPM     = "npm download cache"
	lblDD      = "Stale Xcode build output (DerivedData)"
	lblDeps    = "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)"
	lblSim     = "Simulators whose runtime was removed"
	lblBrew    = "Homebrew: old versions of installed formulae (brew cleanup)"
	planMarker = "# ---------- plan ----------"
	mib        = 1 << 20
)

type dcItem struct {
	path  string
	kb    int64
	label string
}

type fakeDC struct {
	items            []dcItem
	sims             map[string]int64 // udid -> kb
	brewKB           int64
	skips            []string
	markers          int // how many plan marker lines the script has (default 1)
	exit             int // exit status at the very end
	exitBeforeMarker bool
	noMarkerLine     bool
}

type cmmItem struct {
	Rule  string `json:"rule"`
	Group string `json:"group"`
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
	Tier  string `json:"tier"`
	Act   string `json:"action"`
}

type cmmSkip struct {
	Rule   string `json:"rule"`
	Reason string `json:"reason"`
}

type parity struct {
	t                     *testing.T
	dir, home, out        string
	devPath, cmmPath      string
	ran, deleted, argFile string
}

func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func newParity(t *testing.T) *parity {
	t.Helper()
	dir := t.TempDir()
	p := &parity{t: t, dir: dir, home: filepath.Join(dir, "home"), out: filepath.Join(dir, "out"),
		devPath: filepath.Join(dir, "dev-cleanup"), cmmPath: filepath.Join(dir, "cmm"),
		ran: filepath.Join(dir, "dc-ran"), deleted: filepath.Join(dir, "dc-deleted"), argFile: filepath.Join(dir, "dc-args")}
	if err := os.MkdirAll(p.home, 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func (p *parity) writeDevCleanup(f fakeDC) {
	p.t.Helper()
	var b strings.Builder
	b.WriteString("#!/bin/bash\nMODE_DRY=0\nfor a in \"$@\"; do case \"$a\" in --dry-run) MODE_DRY=1 ;; esac; done\n")
	fmt.Fprintf(&b, "echo \"$@\" > %s\ntouch %s\n", shq(p.argFile), shq(p.ran))
	if f.exitBeforeMarker {
		b.WriteString("exit 0\n")
	}
	b.WriteString("H=\"$HOME\"\nSIMDIR=\"$H/Library/Developer/CoreSimulator/Devices\"\n")
	var labels, paths, kbs, notes []string
	for _, it := range f.items {
		labels, paths, kbs, notes = append(labels, shq(it.label)), append(paths, shq(it.path)), append(kbs, fmt.Sprint(it.kb)), append(notes, shq("note"))
	}
	fmt.Fprintf(&b, "P_LABEL=(%s)\nP_PATH=(%s)\nP_KB=(%s)\nP_NOTE=(%s)\n", strings.Join(labels, " "), strings.Join(paths, " "), strings.Join(kbs, " "), strings.Join(notes, " "))
	var ud, uk, un []string
	for u, kb := range f.sims {
		ud, uk, un = append(ud, shq(u)), append(uk, fmt.Sprint(kb)), append(un, shq("iPhone ("+u+")"))
	}
	fmt.Fprintf(&b, "S_UDID=(%s)\nS_KB=(%s)\nS_NAME=(%s)\nBREW_KB=%d\n", strings.Join(ud, " "), strings.Join(uk, " "), strings.Join(un, " "), f.brewKB)
	var sk []string
	for _, s := range f.skips {
		sk = append(sk, shq(s))
	}
	fmt.Fprintf(&b, "SKIPS=(%s)\n", strings.Join(sk, " "))
	n := f.markers
	if n == 0 && !f.noMarkerLine {
		n = 1
	}
	for i := 0; i < n; i++ {
		b.WriteString(planMarker + "\n")
	}
	b.WriteString("echo \"=== PLAN (the real script prints it here) ===\"\n")
	fmt.Fprintf(&b, "touch %s\n", shq(p.deleted)) // the delete phase: the patched copy must never get here
	fmt.Fprintf(&b, "exit %d\n", f.exit)
	if err := os.WriteFile(p.devPath, []byte(b.String()), 0o755); err != nil {
		p.t.Fatal(err)
	}
}

// writeCmm installs a fake cmm that answers `plan --json` with the given items (or raw output / an exit status).
func (p *parity) writeCmm(items []cmmItem, skips []cmmSkip, exit int, raw string) {
	p.t.Helper()
	body := raw
	if body == "" {
		for i := range items {
			items[i].Tier, items[i].Act = "safe", "delete"
		}
		if items == nil {
			items = []cmmItem{}
		}
		if skips == nil {
			skips = []cmmSkip{}
		}
		enc, err := json.Marshal(map[string]any{
			"schema_version": 1, "generated_at": "2026-10-14T12:00:00Z",
			"host": map[string]any{"volume": "/", "free_bytes": 1}, "items": items, "groups": []any{}, "skipped": skips, "total_bytes": 0,
		})
		if err != nil {
			p.t.Fatal(err)
		}
		body = string(enc)
	}
	jsonFile := filepath.Join(p.dir, "cmm.json")
	if err := os.WriteFile(jsonFile, []byte(body), 0o644); err != nil {
		p.t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/bash\n[ \"$1\" = plan ] && [ \"$2\" = --json ] || exit 64\ncat %s\nexit %d\n", shq(jsonFile), exit)
	if err := os.WriteFile(p.cmmPath, []byte(script), 0o755); err != nil {
		p.t.Fatal(err)
	}
}

func (p *parity) run(extraEnv ...string) (int, string) {
	p.t.Helper()
	cmd := exec.Command("bash", filepath.Join("..", "scripts", "parity.sh"))
	cmd.Env = append(os.Environ(), "HOME="+p.home, "PARITY_DEV_CLEANUP="+p.devPath, "PARITY_CMM="+p.cmmPath, "PARITY_OUT="+p.out)
	cmd.Env = append(cmd.Env, extraEnv...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0, out.String()
	case errors.As(err, &ee):
		return ee.ExitCode(), out.String()
	}
	p.t.Fatalf("cannot run the script: %v", err)
	return -1, ""
}

func (p *parity) sum() [32]byte {
	b, err := os.ReadFile(p.devPath)
	if err != nil {
		p.t.Fatal(err)
	}
	return sha256.Sum256(b)
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func agreeing(p *parity) {
	home := p.home
	items := []dcItem{
		{"/h/Library/Caches/go-build", 2 * 1024 * 1024, lblGo},
		{"/h/.npm/_cacache", 700 * 1024, lblNPM},
		{"/h/lane-builds/a/node_modules", 300 * 1024, lblDeps},
	}
	p.writeDevCleanup(fakeDC{items: items, sims: map[string]int64{"1C7EE994-6898-4D40-883D-0EF75816C39A": 6 * 1024 * 1024}, brewKB: 1024 * 1024,
		skips: []string{"Xcode build folder X: in use"}})
	p.writeCmm([]cmmItem{
		{Rule: "go-build", Group: lblGo, Path: "/h/Library/Caches/go-build", Bytes: 2 * 1024 * mib},
		{Rule: "npm-cache", Group: lblNPM, Path: "/h/.npm/_cacache", Bytes: 700 * mib},
		{Rule: "lane-deps", Group: lblDeps, Path: "/h/lane-builds/a/node_modules", Bytes: 300 * mib},
		{Rule: "simulators", Group: lblSim, Path: home + "/Library/Developer/CoreSimulator/Devices/1C7EE994-6898-4D40-883D-0EF75816C39A", Bytes: 6 * 1024 * mib},
		{Rule: "homebrew", Group: lblBrew, Path: "homebrew: cleanup", Bytes: 1024 * mib},
	}, []cmmSkip{{Rule: "deriveddata-stale", Reason: "Xcode build folder X: in use"}}, 0, "")
}

func TestParity_AgreeingPlansPassWithoutRunningTheDeletePhase(t *testing.T) {
	p := newParity(t)
	agreeing(p)
	before := p.sum()

	code, out := p.run()
	if code != 0 || !strings.Contains(out, "PARITY OK") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
	if !exists(p.ran) {
		t.Error("the patched copy of dev-cleanup should have run")
	}
	if exists(p.deleted) {
		t.Fatal("the patched copy reached the delete phase")
	}
	if args, _ := os.ReadFile(p.argFile); !strings.Contains(string(args), "--dry-run") {
		t.Errorf("dev-cleanup must be run with --dry-run, got %q", args)
	}
	if p.sum() != before {
		t.Error("the installed dev-cleanup was modified")
	}
	if !strings.Contains(out, "Nothing to compare in") || !strings.Contains(out, "xcode-module-cache") {
		t.Errorf("the categories that had nothing on either side must be named:\n%s", out)
	}
	if strings.Contains(out, "Nothing to compare in: go-build") {
		t.Errorf("go-build had something to compare:\n%s", out)
	}
}

func TestParity_SizeTolerance(t *testing.T) {
	for name, c := range map[string]struct {
		dcKB     int64
		cmmBytes int64
		ok       bool
	}{
		"1.5% of a gigabyte":        {1024 * 1024, 1024*mib + 15*mib, true},
		"3% of a gigabyte":          {1024 * 1024, 1024*mib + 31*mib, false},
		"under 5 MB on a small one": {1024, 1*mib + 4*mib, true},
		"over 5 MB on a small one":  {1024, 1*mib + 6*mib, false},
		"cmm smaller is judged too": {1024 * 1024, 1024*mib - 31*mib, false},
		"identical":                 {123456, 123456 * 1024, true},
	} {
		t.Run(name, func(t *testing.T) {
			p := newParity(t)
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/Library/Caches/go-build", c.dcKB, lblGo}}})
			p.writeCmm([]cmmItem{{Rule: "go-build", Group: lblGo, Path: "/h/Library/Caches/go-build", Bytes: c.cmmBytes}}, nil, 0, "")
			code, out := p.run()
			if c.ok && code != 0 || !c.ok && code != 1 {
				t.Fatalf("exit %d, want ok=%v:\n%s", code, c.ok, out)
			}
			if !c.ok && !strings.Contains(out, "size differs") {
				t.Errorf("the size difference must be named:\n%s", out)
			}
		})
	}
}

func TestParity_EveryKindOfDifferenceIsNamed(t *testing.T) {
	p := newParity(t)
	p.writeDevCleanup(fakeDC{items: []dcItem{
		{"/h/only-dc", 10 * 1024, lblGo},
		{"/h/both-same", 10 * 1024, lblNPM},
		{"/h/both-rule", 10 * 1024, lblNPM},
	}, brewKB: 500 * 1024})
	p.writeCmm([]cmmItem{
		{Rule: "go-build", Group: lblGo, Path: "/h/only-cmm", Bytes: 10 * mib},
		{Rule: "npm-cache", Group: lblNPM, Path: "/h/both-same", Bytes: 10 * mib},
		{Rule: "go-build", Group: lblGo, Path: "/h/both-rule", Bytes: 10 * mib},
	}, nil, 0, "")
	code, out := p.run()
	if code != 1 || !strings.Contains(out, "PARITY MISMATCH") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
	for _, want := range []string{
		"only in dev-cleanup: /h/only-dc",
		"only in cmm: /h/only-cmm",
		"rule differs: /h/both-rule",
		"only in dev-cleanup: homebrew: cleanup", // dev-cleanup had a brew total, cmm none
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "/h/both-same") && strings.Contains(out, "differs: /h/both-same") {
		t.Errorf("an agreeing path must not be reported:\n%s", out)
	}
}

func TestParity_AGroupLabelThatDoesNotMatchTheRuleIsReported(t *testing.T) {
	p := newParity(t)
	p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 10 * 1024, lblGo}}})
	p.writeCmm([]cmmItem{{Rule: "go-build", Group: "Go cache, renamed", Path: "/h/a", Bytes: 10 * mib}}, nil, 0, "")
	code, out := p.run()
	if code != 1 || !strings.Contains(out, "group differs: /h/a") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestParity_SetupProblemsFailClosed(t *testing.T) {
	cases := map[string]struct {
		setup  func(p *parity)
		want   string
		dcRuns bool // whether the (patched) dev-cleanup may have run at all
	}{
		"no plan marker in dev-cleanup": {func(p *parity) {
			p.writeDevCleanup(fakeDC{noMarkerLine: true})
			p.writeCmm(nil, nil, 0, "")
		}, "marker", false},
		"two plan markers": {func(p *parity) {
			p.writeDevCleanup(fakeDC{markers: 2})
			p.writeCmm(nil, nil, 0, "")
		}, "marker", false},
		"dev-cleanup missing": {func(p *parity) {
			p.writeCmm(nil, nil, 0, "")
		}, "dev-cleanup", false},
		"dev-cleanup fails": {func(p *parity) {
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 1, lblGo}}})
			p.writeCmm([]cmmItem{{Rule: "go-build", Group: lblGo, Path: "/h/a", Bytes: 1024}}, nil, 0, "")
			// a script that dies before it reaches the marker
			if err := os.WriteFile(p.devPath, []byte("#!/bin/bash\ntouch "+shq(p.ran)+"\nexit 7\n"+planMarker+"\n"), 0o755); err != nil {
				t.Fatal(err)
			}
		}, "dev-cleanup", true},
		"dev-cleanup ends without writing a dump": {func(p *parity) {
			p.writeDevCleanup(fakeDC{exitBeforeMarker: true})
			p.writeCmm(nil, nil, 0, "")
		}, "dump", true},
		"cmm fails": {func(p *parity) {
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 1, lblGo}}})
			p.writeCmm(nil, nil, 3, `{"items":[]}`)
		}, "cmm", true},
		"cmm prints a good plan but exits with an error": {func(p *parity) {
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 1, lblGo}}})
			p.writeCmm([]cmmItem{{Rule: "go-build", Group: lblGo, Path: "/h/a", Bytes: 1024}}, nil, 3, "")
		}, "cmm", true},
		"cmm prints something that is not json": {func(p *parity) {
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 1, lblGo}}})
			p.writeCmm(nil, nil, 0, "not json at all")
		}, "cmm", true},
		"cmm json of another schema": {func(p *parity) {
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 1, lblGo}}})
			p.writeCmm(nil, nil, 0, `{"schema_version": 2, "items": []}`)
		}, "schema", true},
		"cmm binary missing": {func(p *parity) {
			p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 1, lblGo}}})
		}, "cmm", true},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			p := newParity(t)
			c.setup(p)
			var before [32]byte
			if exists(p.devPath) {
				before = p.sum()
			}
			code, out := p.run()
			if code != 2 {
				t.Fatalf("exit %d, want 2 (could not compare):\n%s", code, out)
			}
			if strings.Contains(out, "PARITY OK") || !strings.Contains(out, "PARITY ERROR") || !strings.Contains(strings.ToLower(out), c.want) {
				t.Errorf("the failure must say so and say what (%q):\n%s", c.want, out)
			}
			if !c.dcRuns && exists(p.ran) {
				t.Errorf("dev-cleanup must not be started when the patch cannot be made safely:\n%s", out)
			}
			if exists(p.deleted) {
				t.Error("the delete phase was reached")
			}
			if exists(p.devPath) && p.sum() != before {
				t.Error("the installed dev-cleanup was modified")
			}
		})
	}
}

func TestParity_NothingToCompareIsNotAPass(t *testing.T) {
	p := newParity(t)
	p.writeDevCleanup(fakeDC{})
	p.writeCmm(nil, nil, 0, "")
	code, out := p.run()
	if code != 3 || !strings.Contains(out, "NOTHING TO COMPARE") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
	code, out = p.run("PARITY_ALLOW_EMPTY=1")
	if code != 0 || !strings.Contains(out, "NOTHING TO COMPARE") {
		t.Fatalf("with PARITY_ALLOW_EMPTY=1: exit %d:\n%s", code, out)
	}
}

func TestParity_PathsWithOddCharactersSurvive(t *testing.T) {
	p := newParity(t)
	odd := "/h/Library/Application Support/It's (v2) $HOME `x`/cache"
	p.writeDevCleanup(fakeDC{items: []dcItem{{odd, 10 * 1024, lblGo}}})
	p.writeCmm([]cmmItem{{Rule: "go-build", Group: lblGo, Path: odd, Bytes: 10 * mib}}, nil, 0, "")
	if code, out := p.run(); code != 0 {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestParity_APathWithATabOrNewlineStopsTheRun(t *testing.T) {
	p := newParity(t)
	p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a\tb", 10 * 1024, lblGo}}})
	p.writeCmm(nil, nil, 0, "")
	code, out := p.run()
	if code != 2 || !strings.Contains(out, "PARITY ERROR") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestParity_DoesNotDeleteItsOwnArtifacts(t *testing.T) {
	p := newParity(t)
	agreeing(p)
	if code, out := p.run(); code != 0 {
		t.Fatalf("exit %d:\n%s", code, out)
	}
	for _, f := range []string{"dev-cleanup.patched", "dump.tsv", "cmm.json"} {
		if !exists(filepath.Join(p.out, f)) {
			t.Errorf("%s should be kept for inspection in %s", f, p.out)
		}
	}
}

func TestParity_NoticesIfTheInstalledScriptChangesDuringTheRun(t *testing.T) {
	p := newParity(t)
	agreeing(p)
	// a cmm that, besides answering, appends to the installed dev-cleanup
	body, err := os.ReadFile(p.cmmPath)
	if err != nil {
		t.Fatal(err)
	}
	tampering := strings.Replace(string(body), "cat ", "echo '# changed' >> "+shq(p.devPath)+"\ncat ", 1)
	if err := os.WriteFile(p.cmmPath, []byte(tampering), 0o755); err != nil {
		t.Fatal(err)
	}
	code, out := p.run()
	if code != 2 || !strings.Contains(out, "changed during the run") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestParity_AnUnknownLabelOrRuleStopsOrFlagsTheComparison(t *testing.T) {
	t.Run("dev-cleanup grew a group this script does not know", func(t *testing.T) {
		p := newParity(t)
		p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 10, "Something brand new"}}})
		p.writeCmm(nil, nil, 0, "")
		code, out := p.run()
		if code != 2 || !strings.Contains(out, "group label") {
			t.Fatalf("exit %d:\n%s", code, out)
		}
	})
	t.Run("cmm grew a rule this script does not know", func(t *testing.T) {
		p := newParity(t)
		p.writeDevCleanup(fakeDC{items: []dcItem{{"/h/a", 10 * 1024, lblGo}}})
		p.writeCmm([]cmmItem{{Rule: "go-build", Group: lblGo, Path: "/h/a", Bytes: 10 * mib}, {Rule: "brand-new", Group: "New", Path: "/h/b", Bytes: 10 * mib}}, nil, 0, "")
		code, out := p.run()
		if code != 1 || !strings.Contains(out, "unknown rule: /h/b") {
			t.Fatalf("exit %d:\n%s", code, out)
		}
	})
}

func TestParity_ADumpLeftByAnEarlierRunIsNeverReused(t *testing.T) {
	p := newParity(t)
	agreeing(p)
	if code, out := p.run(); code != 0 {
		t.Fatalf("setup: exit %d:\n%s", code, out)
	}
	// same artifacts folder, but now dev-cleanup stops before it can write a dump
	p.writeDevCleanup(fakeDC{exitBeforeMarker: true})
	code, out := p.run()
	if code != 2 || strings.Contains(out, "PARITY OK") {
		t.Fatalf("a leftover dump must not stand in for a missing one: exit %d:\n%s", code, out)
	}
}
