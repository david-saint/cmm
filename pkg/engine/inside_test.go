package engine

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/david-saint/cmm/pkg/rules"
)

// ---- space freed inside another program's own storage ----

// insideFixture plans one real file (5 bytes freed on the volume) and one command that frees 40 bytes inside Docker's disk image.
func insideFixture(t *testing.T) (*fixture, *fakeRunLog) {
	t.Helper()
	f := newFixture(t)
	p := filepath.Dir(f.laneFile(t, "a", "node_modules/x", 10))
	inside := rules.Candidate{Group: "Docker", Path: "docker: unused images", Bytes: 50, Tier: rules.TierReview, Action: rules.ActionCommand, FreesInside: "Docker's disk image"}
	cr := commandRule{&fakeRule{id: "docker", group: "Docker", items: []rules.Candidate{inside}}}
	cr.execFreed = 40
	f.eng.Rules = []rules.Rule{
		&fakeRule{id: "deps", group: "Deps", items: []rules.Candidate{cand("", "Deps", p, 5)}},
		cr,
	}
	log := &fakeRunLog{}
	f.eng.History = log
	return f, log
}

func TestPlan_KeepsWhereTheSpaceIsFreed(t *testing.T) {
	f, _ := insideFixture(t)
	plan, err := f.eng.Plan(ctx)
	if err != nil || len(plan.Items) != 2 {
		t.Fatalf("Plan: %v %+v", err, plan)
	}
	if plan.Items[0].FreesInside != "" || plan.Items[1].FreesInside != "Docker's disk image" {
		t.Errorf("only the command item frees space elsewhere: %+v", plan.Items)
	}
}

func TestApply_SpaceFreedInsideAnotherProgramIsCountedApart(t *testing.T) {
	f, _ := insideFixture(t)
	plan, _ := f.eng.Plan(ctx)
	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil || rep.Deleted != 2 {
		t.Fatalf("setup: %v %+v", err, rep)
	}
	if rep.FreedBytes != 5 {
		t.Errorf("FreedBytes is what the volume got back, and Docker's 40 bytes stay out of it: %d", rep.FreedBytes)
	}
	if rep.FreedInsideBytes != 40 {
		t.Errorf("what was freed inside Docker is told apart: %d", rep.FreedInsideBytes)
	}
	if rep.Results[1].FreedBytes != 40 || rep.Results[1].Item.FreesInside == "" {
		t.Errorf("each item still says what it freed, and where: %+v", rep.Results[1])
	}
}

func TestApply_AnItemThatFailedFreedNothingAnywhere(t *testing.T) {
	f, _ := insideFixture(t)
	f.eng.Rules[1].(commandRule).executeErr = errors.New("docker: boom")
	plan, _ := f.eng.Plan(ctx)
	rep, _ := f.eng.Apply(ctx, plan, ApplyOptions{})
	if rep.Failed != 1 || rep.FreedBytes != 5 || rep.FreedInsideBytes != 0 {
		t.Errorf("a failed prune adds nothing to either figure: %+v", rep)
	}
}

func TestApply_TheHistoryKeepsTheSplitToo(t *testing.T) {
	f, log := insideFixture(t)
	plan, _ := f.eng.Plan(ctx)
	if _, err := f.eng.Apply(ctx, plan, ApplyOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(log.runs) != 1 {
		t.Fatalf("one run: %+v", log.runs)
	}
	r := log.runs[0]
	if r.FreedBytes != 5 || r.FreedInsideBytes != 40 {
		t.Errorf("the run keeps both figures: %+v", r)
	}
	if r.Items[1].FreesInside != "Docker's disk image" || r.Items[0].FreesInside != "" {
		t.Errorf("and which item freed space where: %+v", r.Items)
	}
}
