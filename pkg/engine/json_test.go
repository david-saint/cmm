package engine

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/rules"
)

var update = flag.Bool("update", false, "rewrite the golden files")

// samplePlan is deterministic: fixed time, fixed numbers, one delete item, one command item, one skip.
func samplePlan() *Plan {
	return &Plan{
		SchemaVersion: SchemaVersion,
		GeneratedAt:   time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC),
		Host:          Host{Volume: "/System/Volumes/Data", FreeBytes: 27583119360},
		Items: []rules.Candidate{
			{Rule: "go-build", Group: "Go build cache", Path: "/Users/test/Library/Caches/go-build", Bytes: 3715000000, Tier: rules.TierSafe, Action: rules.ActionDelete},
			{Rule: "homebrew", Group: "Homebrew: old versions of installed formulae (brew cleanup)", Path: "homebrew: cleanup", Bytes: 704000000, Tier: rules.TierSafe, Action: rules.ActionCommand, Note: "boost 1.85.0, 0.5 GB; python@3.14 3.14.7, 81 MB"},
		},
		Groups: []Group{
			{Group: "Go build cache", Bytes: 3715000000, Count: 1},
			{Group: "Homebrew: old versions of installed formulae (brew cleanup)", Bytes: 704000000, Count: 1},
		},
		Skipped:    []rules.Skip{{Rule: "uv-cache", Reason: "uv is running"}},
		TotalBytes: 4419000000,
	}
}

// The golden file is the contract with everything that reads `cmm plan --json` (the macOS app, the Claude
// panel). A change here must be a deliberate edit of testdata/plan_v1.golden.json and a schema version bump
// if it breaks readers.
func TestPlanJSON_MatchesGolden(t *testing.T) {
	got, err := samplePlan().JSON()
	if err != nil {
		t.Fatalf("JSON() failed: %v", err)
	}
	golden := filepath.Join("testdata", "plan_v1.golden.json")
	if *update {
		if err := os.WriteFile(golden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("cannot read the golden file (run `go test ./pkg/engine -run Golden -update`): %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("plan JSON differs from %s\n--- got ---\n%s\n--- want ---\n%s", golden, got, want)
	}
}

func TestPlanJSON_TopLevelAndItemKeysAreExactlyTheSchema(t *testing.T) {
	raw, err := samplePlan().JSON()
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("output is not valid JSON: %v", err)
	}
	assertKeys(t, "top level", doc, "schema_version", "generated_at", "host", "items", "groups", "skipped", "total_bytes")
	assertKeys(t, "host", doc["host"].(map[string]any), "volume", "free_bytes")

	item := doc["items"].([]any)[0].(map[string]any)
	assertKeys(t, "delete item (note omitted when empty)", item, "rule", "group", "path", "bytes", "tier", "action")
	withNote := doc["items"].([]any)[1].(map[string]any)
	assertKeys(t, "item with a note", withNote, "rule", "group", "path", "bytes", "tier", "action", "note")
	assertKeys(t, "group", doc["groups"].([]any)[0].(map[string]any), "group", "bytes", "count")
	assertKeys(t, "skip", doc["skipped"].([]any)[0].(map[string]any), "rule", "reason")

	if v := doc["schema_version"].(float64); v != 1 {
		t.Errorf("schema_version = %v, want 1", v)
	}
}

func assertKeys(t *testing.T, what string, m map[string]any, want ...string) {
	t.Helper()
	var got []string
	for k := range m {
		got = append(got, k)
	}
	sort.Strings(got)
	sort.Strings(want)
	if len(got) != len(want) {
		t.Errorf("%s keys = %v, want %v", what, got, want)
		return
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("%s keys = %v, want %v", what, got, want)
			return
		}
	}
}

func TestPlanJSON_EmptyListsAreArrays(t *testing.T) {
	empty := &Plan{SchemaVersion: SchemaVersion, Items: []rules.Candidate{}, Groups: []Group{}, Skipped: []rules.Skip{}}
	raw, err := empty.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"items", "groups", "skipped"} {
		if string(doc[k]) != "[]" {
			t.Errorf("%s should be [] when empty, got %s", k, doc[k])
		}
	}
}

func TestPlanJSON_NilListsStillBecomeArrays(t *testing.T) {
	// a Plan built by hand with nil slices must not leak "null" to readers
	raw, err := (&Plan{SchemaVersion: SchemaVersion}).JSON()
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	_ = json.Unmarshal(raw, &doc)
	for _, k := range []string{"items", "groups", "skipped"} {
		if string(doc[k]) != "[]" {
			t.Errorf("%s should be [] for a nil slice, got %s", k, doc[k])
		}
	}
}

func TestPlanJSON_RoundTrips(t *testing.T) {
	raw, _ := samplePlan().JSON()
	var back Plan
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.TotalBytes != 4419000000 || len(back.Items) != 2 || back.Items[1].Action != rules.ActionCommand || back.Skipped[0].Reason != "uv is running" {
		t.Errorf("round trip lost data: %+v", back)
	}
	if !back.GeneratedAt.Equal(samplePlan().GeneratedAt) {
		t.Errorf("time did not round trip: %v", back.GeneratedAt)
	}
}
