package engine

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/david-saint/cmm/pkg/rules"
)

// ---- Apply and the history of runs ----

type fakeRunLog struct {
	runs []Run
	err  error
}

func (l *fakeRunLog) Append(r Run) error { l.runs = append(l.runs, r); return l.err }

func TestApply_ARealRunLeavesOneRecordWithEveryNumber(t *testing.T) {
	f, fail, skip, ok := threeItems(t)
	plan, _ := f.eng.Plan(ctx)
	log := &fakeRunLog{}
	f.eng.History = log
	f.eng.Capacity = func() int64 { return 9000 }
	removed := false
	f.eng.Free = func() (string, int64, error) {
		if removed {
			return "/sandbox", 5000, nil
		}
		return "/sandbox", 1000, nil
	}
	f.eng.Remove = func(p string) error {
		removed = true
		f.sb.Advance(30 * time.Second) // each removal takes half a minute on this machine
		if p == fail {
			return errors.New("permission denied")
		}
		return os.RemoveAll(p)
	}
	start := f.sb.Env.Clock()

	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil || rep.Deleted != 1 || rep.Failed != 1 || rep.Skipped != 1 {
		t.Fatalf("setup: %v %+v", err, rep)
	}
	if len(log.runs) != 1 {
		t.Fatalf("one real run leaves one record, got %d", len(log.runs))
	}
	r := log.runs[0]
	if !r.StartedAt.Equal(start) || r.FinishedAt.Sub(r.StartedAt) != time.Minute {
		t.Errorf("start and end come from the clock: %v to %v", r.StartedAt, r.FinishedAt)
	}
	if r.Deleted != 1 || r.Skipped != 1 || r.Failed != 1 || r.FreedBytes != 4 || r.FreeBefore != 1000 || r.FreeAfter != 5000 || r.CapacityBytes != 9000 || r.Stopped {
		t.Errorf("the numbers of the run: %+v", r)
	}
	if len(r.Items) != 2 {
		t.Fatalf("what was deleted or failed is listed, in plan order (skips are only counted): %+v", r.Items)
	}
	if got := r.Items[0]; got != (RunItem{Rule: "deps", Group: "Deps", Path: fail, Status: StatusFailed, Bytes: 1, Reason: "permission denied"}) {
		t.Errorf("the failed item: %+v", got)
	}
	if got := r.Items[1]; got != (RunItem{Rule: "deps", Group: "Deps", Path: ok, Status: StatusDeleted, Bytes: 4, FreedBytes: 4}) {
		t.Errorf("the deleted item: %+v", got)
	}
	for _, it := range r.Items {
		if it.Path == skip {
			t.Error("a skipped item changed nothing and is not listed")
		}
	}
}

func TestApply_NothingDoneLeavesNoRecord(t *testing.T) {
	f, _, skip, _ := threeItems(t)
	plan, _ := f.eng.Plan(ctx)
	plan.Items = []rules.Candidate{cand("deps", "Deps", skip, 2)} // the one a re-check refuses
	log := &fakeRunLog{}
	f.eng.History = log
	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil || rep.Skipped != 1 || rep.Deleted != 0 || rep.Failed != 0 {
		t.Fatalf("setup: %v %+v", err, rep)
	}
	if len(log.runs) != 0 {
		t.Errorf("a run in which everything was skipped changed nothing and leaves no record: %+v", log.runs)
	}
}

func TestApply_AFailureAloneIsStillARecord(t *testing.T) {
	f, fail, _, _ := threeItems(t)
	plan, _ := f.eng.Plan(ctx)
	plan.Items = []rules.Candidate{cand("deps", "Deps", fail, 1)}
	log := &fakeRunLog{}
	f.eng.History = log
	if _, err := f.eng.Apply(ctx, plan, ApplyOptions{}); err != nil {
		t.Fatal(err)
	}
	if len(log.runs) != 1 || log.runs[0].Failed != 1 || log.runs[0].Deleted != 0 || log.runs[0].FreedBytes != 0 || len(log.runs[0].Items) != 1 {
		t.Errorf("a run that only failed is worth knowing about: %+v", log.runs)
	}
}

func TestApply_ADryRunLeavesNoRecord(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	log := &fakeRunLog{}
	f.eng.History = log
	plan.Items = append(plan.Items, cand("no-such-rule", "X", a, 1)) // fails even in a dry run
	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{DryRun: true})
	if err != nil || rep.Failed != 1 {
		t.Fatalf("setup: %v %+v", err, rep)
	}
	if len(log.runs) != 0 || !exists(a) || !exists(b) {
		t.Errorf("a dry run writes nothing, not even a failure: %+v", log.runs)
	}
}

func TestApply_ARunCutShortIsRecordedAsStopped(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	log := &fakeRunLog{}
	f.eng.History = log
	cctx, cancel := context.WithCancel(ctx)
	f.eng.Remove = func(path string) error {
		err := os.RemoveAll(path)
		cancel()
		return err
	}
	rep, err := f.eng.Apply(cctx, plan, ApplyOptions{})
	if !errors.Is(err, context.Canceled) || rep.Deleted != 1 || exists(a) || !exists(b) {
		t.Fatalf("setup: %v %+v", err, rep)
	}
	if len(log.runs) != 1 || !log.runs[0].Stopped || log.runs[0].Deleted != 1 {
		t.Errorf("what was done before Stop is recorded, and says it was stopped: %+v", log.runs)
	}
}

func TestApply_AHistoryThatFailsIsAWarningNotAFailure(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	f.eng.History = &fakeRunLog{err: errors.New("disk full")}
	rep, err := f.eng.Apply(ctx, plan, ApplyOptions{})
	if err != nil || exists(a) || exists(b) || !rep.OK() {
		t.Fatalf("the cleanup itself did what it says: %v %+v", err, rep)
	}
	if len(rep.Warnings) != 1 || !strings.Contains(rep.Warnings[0], "history") || !strings.Contains(rep.Warnings[0], "disk full") {
		t.Errorf("the problem is reported once: %q", rep.Warnings)
	}
}

func TestApply_TheFileHistoryReceivesTheRunAndTheJournalIsLeftAlone(t *testing.T) {
	f, _, a, b := twoItemPlan(t)
	plan, _ := f.eng.Plan(ctx)
	h := NewFileHistory(f.sb.Env.Home, f.sb.Env.Clock)
	f.eng.History = h
	j := &fakeJournal{}
	f.eng.Journal = j
	if _, err := f.eng.Apply(ctx, plan, ApplyOptions{}); err != nil {
		t.Fatal(err)
	}
	runs, bad, err := h.Runs(5)
	if err != nil || bad != 0 || len(runs) != 1 || runs[0].Deleted != 2 || len(runs[0].Items) != 2 {
		t.Errorf("the run is on file: %+v bad=%d err=%v", runs, bad, err)
	}
	if len(j.records) != 2 || j.stamps != 1 || exists(a) || exists(b) {
		t.Errorf("and the journal still does its own job: %+v", j)
	}
}
