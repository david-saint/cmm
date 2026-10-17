package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
)

func TestFormatBytes(t *testing.T) {
	const (
		kb = 1 << 10
		mb = 1 << 20
		gb = 1 << 30
	)
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0 KB"},
		{512, "0 KB"},
		{300 * kb, "300 KB"},
		{50 * mb, "50 MB"},
		{99 * mb, "99 MB"},
		{100 * mb, "0.1 GB"},
		{gb + gb/2, "1.5 GB"},
		{25 * gb, "25.0 GB"},
	}
	for _, c := range cases {
		if got := formatBytes(c.in); got != c.want {
			t.Errorf("formatBytes(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestShortPath(t *testing.T) {
	cases := []struct{ path, home, want string }{
		{"/Users/test/Library/Caches/go-build", "/Users/test", "~/Library/Caches/go-build"},
		{"/Users/test", "/Users/test", "/Users/test"}, // the home directory itself is left alone
		{"/Users/testing/x", "/Users/test", "/Users/testing/x"},
		{"/var/folders/ab/T/jest_dx", "/Users/test", "/var/folders/ab/T/jest_dx"},
		{"homebrew: cleanup", "/Users/test", "homebrew: cleanup"},
		{"/Users/test/x", "", "/Users/test/x"},
	}
	for _, c := range cases {
		if got := shortPath(c.path, c.home); got != c.want {
			t.Errorf("shortPath(%q, %q) = %q, want %q", c.path, c.home, got, c.want)
		}
	}
}

func samplePlan() *engine.Plan {
	items := []rules.Candidate{
		{Rule: "lane-deps", Group: "Idle lane dependencies", Path: "/Users/test/lane-builds/a/node_modules", Bytes: 800 << 20},
		{Rule: "lane-deps", Group: "Idle lane dependencies", Path: "/Users/test/lane-builds/b/node_modules", Bytes: 900 << 20},
		{Rule: "lane-deps", Group: "Idle lane dependencies", Path: "/Users/test/lane-builds/c/node_modules", Bytes: 700 << 20},
		{Rule: "lane-deps", Group: "Idle lane dependencies", Path: "/Users/test/lane-builds/d/node_modules", Bytes: 600 << 20},
		{Rule: "go-build", Group: "Go build cache", Path: "/Users/test/Library/Caches/go-build", Bytes: 3 << 30, Note: "2 entries could not be read"},
	}
	p := &engine.Plan{
		SchemaVersion: engine.SchemaVersion,
		Host:          engine.Host{Volume: "/System/Volumes/Data", FreeBytes: 20 << 30},
		Items:         items,
		Groups:        []engine.Group{{Group: "Idle lane dependencies", Bytes: 3000 << 20, Count: 4}, {Group: "Go build cache", Bytes: 3 << 30, Count: 1}},
		Skipped:       []rules.Skip{{Rule: "uv-cache", Reason: "uv cache: uv is running"}},
		TotalBytes:    (3000 << 20) + (3 << 30),
	}
	return p
}

func TestWritePlan_Layout(t *testing.T) {
	var b bytes.Buffer
	writePlan(&b, samplePlan(), "/Users/test", false)
	out := b.String()

	for _, want := range []string{
		"=== PLAN ===",
		"Idle lane dependencies [4 items]",
		"Go build cache",
		"~/Library/Caches/go-build",
		"2 entries could not be read",
		"TOTAL",
		"=== SKIPPED (guards said no) ===",
		"uv cache: uv is running",
		"Free space now: 20.0 GB",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("plan output should contain %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "/Users/test/") {
		t.Errorf("home paths must be shortened:\n%s", out)
	}
	// 4 items in one group: only the three biggest are listed unless -v is given
	if !strings.Contains(out, "b/node_modules") || strings.Contains(out, "d/node_modules") || !strings.Contains(out, "and 1 more") {
		t.Errorf("a long group should show its three biggest items and a count:\n%s", out)
	}
}

func TestWritePlan_VerboseListsEverything(t *testing.T) {
	var b bytes.Buffer
	writePlan(&b, samplePlan(), "/Users/test", true)
	if out := b.String(); !strings.Contains(out, "d/node_modules") || strings.Contains(out, "and 1 more") {
		t.Errorf("verbose output must list every item:\n%s", out)
	}
}

func TestWritePlan_EmptyPlan(t *testing.T) {
	var b bytes.Buffer
	writePlan(&b, &engine.Plan{}, "/Users/test", false)
	out := b.String()
	if !strings.Contains(out, "nothing to clean right now") || strings.Contains(out, "TOTAL") || strings.Contains(out, "SKIPPED") {
		t.Errorf("an empty plan says so and prints nothing else:\n%s", out)
	}
}
