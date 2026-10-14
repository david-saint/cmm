package engine

import (
	"testing"

	"github.com/david-saint/cmm/pkg/rules"
)

func TestPlan_OnlyKeepsTheNamedRulesAndRecomputesTotals(t *testing.T) {
	p := &Plan{
		SchemaVersion: SchemaVersion,
		Items: []rules.Candidate{
			{Rule: "a", Group: "A", Path: "/p/a1", Bytes: 10},
			{Rule: "b", Group: "B", Path: "/p/b1", Bytes: 20},
			{Rule: "a", Group: "A", Path: "/p/a2", Bytes: 30},
		},
		Groups:     []Group{{Group: "A", Bytes: 40, Count: 2}, {Group: "B", Bytes: 20, Count: 1}},
		Skipped:    []rules.Skip{{Rule: "a", Reason: "x"}, {Rule: "b", Reason: "y"}},
		TotalBytes: 60,
	}

	got := p.Only("a")
	if len(got.Items) != 2 || got.TotalBytes != 40 || len(got.Groups) != 1 || got.Groups[0].Group != "A" || got.Groups[0].Count != 2 {
		t.Errorf("unexpected filtered plan: %+v", got)
	}
	if len(got.Skipped) != 1 || got.Skipped[0].Rule != "a" {
		t.Errorf("skips should be filtered too: %+v", got.Skipped)
	}
	if len(p.Items) != 3 || p.TotalBytes != 60 {
		t.Error("the original plan must not change")
	}
}

func TestPlan_OnlyWithNoIDsReturnsEverything(t *testing.T) {
	p := &Plan{Items: []rules.Candidate{{Rule: "a", Group: "A", Bytes: 1}}, TotalBytes: 1}
	if got := p.Only(); len(got.Items) != 1 || got.TotalBytes != 1 {
		t.Errorf("no ids means no filtering: %+v", got)
	}
}

func TestPlan_OnlyNeverReturnsNilLists(t *testing.T) {
	got := (&Plan{}).Only("nothing")
	if got.Items == nil || got.Groups == nil || got.Skipped == nil {
		t.Errorf("lists must be empty slices, not nil: %+v", got)
	}
}
