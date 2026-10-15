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

func selectionPlan() *Plan {
	return &Plan{
		SchemaVersion: SchemaVersion,
		Items: []rules.Candidate{
			{Rule: "a", Group: "A", Path: "/p/a1", Bytes: 10},
			{Rule: "b", Group: "B", Path: "/p/b1", Bytes: 20},
			{Rule: "a", Group: "A", Path: "/p/a2", Bytes: 30},
		},
		Groups:     []Group{{Group: "A", Bytes: 40, Count: 2}, {Group: "B", Bytes: 20, Count: 1}},
		Skipped:    []rules.Skip{{Rule: "a", Reason: "x"}},
		TotalBytes: 60,
	}
}

func TestPlan_OnlyPathsKeepsTheSelectedItemsAndNamesWhatIsMissing(t *testing.T) {
	p := selectionPlan()

	got, missing := p.OnlyPaths([]string{"/p/a2", "/p/zzz", "/p/b1", "/p/a2", "/p/zzz", "/p/yyy"})
	if len(got.Items) != 2 || got.Items[0].Path != "/p/b1" || got.Items[1].Path != "/p/a2" {
		t.Fatalf("selected items keep the plan's order: %+v", got.Items)
	}
	if got.TotalBytes != 50 || len(got.Groups) != 2 || got.Groups[0] != (Group{Group: "B", Bytes: 20, Count: 1}) || got.Groups[1] != (Group{Group: "A", Bytes: 30, Count: 1}) {
		t.Errorf("groups and totals are recomputed for the selection: %+v total=%d", got.Groups, got.TotalBytes)
	}
	if len(missing) != 2 || missing[0] != "/p/zzz" || missing[1] != "/p/yyy" {
		t.Errorf("paths that are not in the plan are named once, in the order asked: %q", missing)
	}
	if len(got.Skipped) != 1 {
		t.Errorf("what the guards skipped is information about the plan and stays: %+v", got.Skipped)
	}
	if len(p.Items) != 3 || p.TotalBytes != 60 || len(p.Groups) != 2 {
		t.Error("the original plan must not change")
	}
}

func TestPlan_OnlyPathsCanOnlyNarrowAPlan(t *testing.T) {
	p := selectionPlan()
	got, missing := p.OnlyPaths([]string{"/etc", "/p", "/p/a1/..", "/p/a1/", "p/a1"})
	if len(got.Items) != 0 || got.TotalBytes != 0 || len(missing) != 5 {
		t.Errorf("a path that is not exactly an item of the plan adds nothing: %+v missing=%q", got.Items, missing)
	}
}

func TestPlan_OnlyPathsWithAnEmptySelectionKeepsNothing(t *testing.T) {
	for _, sel := range [][]string{nil, {}} {
		got, missing := selectionPlan().OnlyPaths(sel)
		if len(got.Items) != 0 || len(missing) != 0 || got.Items == nil || got.Groups == nil || got.Skipped == nil || missing == nil {
			t.Errorf("an empty selection is nothing, not everything (unlike Only): %+v missing=%v", got, missing)
		}
	}
}

func tieredPlan() *Plan {
	return &Plan{
		SchemaVersion: SchemaVersion,
		Items: []rules.Candidate{
			{Rule: "a", Group: "A", Path: "/p/a1", Bytes: 10, Tier: rules.TierSafe},
			{Rule: "d", Group: "D", Path: "docker: x", Bytes: 500, Tier: rules.TierReview},
			{Rule: "a", Group: "A", Path: "/p/a2", Bytes: 30, Tier: rules.TierSafe},
			{Rule: "m", Group: "M", Path: "/p/m1", Bytes: 7, Tier: rules.TierManual},
		},
		Skipped:    []rules.Skip{{Rule: "a", Reason: "x"}},
		TotalBytes: 547,
	}
}

func TestPlan_SafeOnlyKeepsSafeItemsAndHandsBackTheRest(t *testing.T) {
	p := tieredPlan()
	got, held := p.SafeOnly()
	if len(got.Items) != 2 || got.Items[0].Path != "/p/a1" || got.Items[1].Path != "/p/a2" || got.TotalBytes != 40 {
		t.Errorf("only safe items stay, totals recomputed: %+v total=%d", got.Items, got.TotalBytes)
	}
	if len(got.Groups) != 1 || got.Groups[0] != (Group{Group: "A", Bytes: 40, Count: 2}) {
		t.Errorf("groups follow the items: %+v", got.Groups)
	}
	if len(held) != 2 || held[0].Path != "docker: x" || held[1].Path != "/p/m1" {
		t.Errorf("review and manual items are handed back, in plan order: %+v", held)
	}
	if len(got.Skipped) != 1 {
		t.Errorf("skips are information about the plan and stay: %+v", got.Skipped)
	}
	if len(p.Items) != 4 || p.TotalBytes != 547 {
		t.Error("the original plan must not change")
	}
}

func TestPlan_SafeOnlyTreatsAnUnknownTierAsNeedingAChoice(t *testing.T) {
	p := &Plan{Items: []rules.Candidate{{Path: "/x", Bytes: 1, Tier: ""}, {Path: "/y", Bytes: 1, Tier: "whatever"}}}
	got, held := p.SafeOnly()
	if len(got.Items) != 0 || len(held) != 2 {
		t.Errorf("only an explicit safe tier is applied unasked: %+v held=%+v", got.Items, held)
	}
}

func TestPlan_SafeOnlyOfAnAllSafePlanHoldsNothingBack(t *testing.T) {
	got, held := selectionPlan().SafeOnly() // selectionPlan items have no tier set: not safe
	if len(got.Items) != 0 || len(held) != 3 {
		t.Fatalf("items without a tier are not safe: %+v", got.Items)
	}
	p := &Plan{Items: []rules.Candidate{{Path: "/a", Bytes: 5, Tier: rules.TierSafe}}}
	got, held = p.SafeOnly()
	if len(got.Items) != 1 || len(held) != 0 || held == nil {
		t.Errorf("an all-safe plan is unchanged and holds nothing (an empty list, never nil): %+v %v", got.Items, held)
	}
}
