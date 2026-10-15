package cmd

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/rules"
)

// reviewRule plans one real file of tier review: something a person must choose on purpose.
type reviewRule struct{ path string }

func (reviewRule) ID() string    { return "review-thing" }
func (reviewRule) Group() string { return "Review things" }
func (r reviewRule) Plan(context.Context, rules.Deps) ([]rules.Candidate, []rules.Skip, error) {
	return []rules.Candidate{{Path: r.path, Bytes: 70_000, Tier: rules.TierReview, Action: rules.ActionDelete, Note: "think before you delete this"}}, nil, nil
}
func (r reviewRule) Allows(_ rules.Deps, p string) bool                       { return p == r.path }
func (reviewRule) Recheck(context.Context, rules.Deps, rules.Candidate) error { return nil }

// withReview adds the review rule (and its file) to the app, after the real caches.
func withReview(t *testing.T, a *app) string {
	t.Helper()
	p := a.sb.Home("Library/Caches/review-thing")
	a.sb.WriteFile(t, p, 100, 0)
	a.eng.Rules = append(a.eng.Rules, reviewRule{path: p})
	return p
}

const heldHeader = "=== NEEDS YOUR CHOICE"

func TestPlan_ReviewItemsGetTheirOwnBlockAndNeverCountInTheTotal(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "plan")
	if o.err != nil {
		t.Fatal(o.err)
	}
	plan, held, ok := strings.Cut(o.stdout, heldHeader)
	if !ok {
		t.Fatalf("a block for what needs a choice is expected:\n%s", o.stdout)
	}
	if strings.Contains(plan, "Review things") || strings.Contains(plan, "think before") {
		t.Errorf("review items are not part of the plan a plain apply would carry out:\n%s", plan)
	}
	if !strings.Contains(plan, "Go build cache") || !strings.Contains(plan, "TOTAL") {
		t.Errorf("the safe plan is still there:\n%s", plan)
	}
	for _, want := range []string{"Review things", "think before you delete this", "--include-review", "--only review-thing", "cmm run"} {
		if !strings.Contains(held, want) {
			t.Errorf("the choice block should mention %q:\n%s", want, held)
		}
	}
	if !present(review) {
		t.Fatal("plan deletes nothing")
	}
}

func TestPlan_WithNothingForReviewThereIsNoBlock(t *testing.T) {
	a := newApp(t)
	if o := a.run("", "plan"); strings.Contains(o.stdout, heldHeader) {
		t.Errorf("no review items, no block:\n%s", o.stdout)
	}
}

func TestPlanJSON_StillListsEveryItemWithItsTier(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "plan", "--json")
	if o.err != nil || !strings.Contains(o.stdout, `"tier": "review"`) || !strings.Contains(o.stdout, review) {
		t.Errorf("the JSON plan carries every item and its tier (the app decides what to tick): %v\n%s", o.err, o.stdout)
	}
}

func TestApply_APlainApplyLeavesReviewItemsAlone(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	if present(a.goCache) || present(a.npmCache) {
		t.Error("the safe items go")
	}
	if !present(review) {
		t.Fatal("a review item is never taken by a plain apply, even after Return")
	}
	if !strings.Contains(o.stdout, heldHeader) || !strings.Contains(o.stdout, "deleted 2") {
		t.Errorf("it says what it left for the person to choose, and counts only what it did:\n%s", o.stdout)
	}
}

func TestApply_YesAloneStillLeavesReviewItemsAlone(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	if o := a.run("", "apply", "--yes"); o.err != nil || !present(review) || present(a.goCache) {
		t.Errorf("--yes is unattended, and unattended never takes review items: %v review=%v go=%v", o.err, present(review), present(a.goCache))
	}
}

func TestApply_IncludeReviewTakesThemAfterTheReturnGate(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	a.tty = false
	if o := a.run("\n", "apply", "--include-review"); o.err == nil || !present(review) || !a.cachesIntact() {
		t.Fatalf("--include-review is not a confirmation: it still needs a person: %v", o.err)
	}
	a.tty = true
	o := a.run("\n", "apply", "--include-review")
	if o.err != nil || present(review) || present(a.goCache) {
		t.Errorf("review items go when asked for and confirmed: %v review=%v\n%s", o.err, present(review), o.stdout)
	}
	if !strings.Contains(o.stdout, "Review things") || strings.Contains(o.stdout, heldHeader) {
		t.Errorf("they are in the plan that was shown, not in a held-back block:\n%s", o.stdout)
	}
}

func TestApply_NamingTheRuleIsAnExplicitChoice(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "apply", "--yes", "--only", "review-thing")
	if o.err != nil || present(review) {
		t.Errorf("--only names the rule on purpose: %v\n%s", o.err, o.stdout)
	}
	if !a.cachesIntact() {
		t.Error("and only that rule")
	}
}

func TestApply_DryRunShowsTheChoiceBlockAndChangesNothing(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "apply", "--dry-run")
	if o.err != nil || !strings.Contains(o.stdout, heldHeader) || !present(review) || !a.cachesIntact() {
		t.Errorf("dry run: %v\n%s", o.err, o.stdout)
	}
}

func TestApply_OnlyReviewItemsMeansNothingSafeToDo(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	for _, p := range []string{a.goCache, a.npmCache} {
		if err := removeAllForTest(p); err != nil {
			t.Fatal(err)
		}
	}
	o := a.run("", "apply", "--yes")
	if o.err != nil || !present(review) {
		t.Fatalf("nothing safe is a calm success, not a deletion of the rest: %v", o.err)
	}
	if !strings.Contains(o.stdout, "Nothing safe to clean") || !strings.Contains(o.stdout, heldHeader) {
		t.Errorf("it should say that what is left needs a choice:\n%s", o.stdout)
	}
	if strings.Contains(o.stdout, "Press Return") || strings.Contains(o.stdout, "=== deleting ===") {
		t.Errorf("nothing to ask and nothing to do:\n%s", o.stdout)
	}
}

// ---- --json ----

func TestApply_JSONWithoutAChoiceReportsReviewItemsAsSkipped(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "apply", "--yes", "--json")
	if o.err != nil {
		t.Fatal(o.err)
	}
	evs := events(t, o.stdout)
	if evs[0]["selected"] != float64(3) || evs[0]["matched"] != float64(2) {
		t.Errorf("selected counts what the plan holds, matched what will be attempted: %v", evs[0])
	}
	it := itemFor(evs, review)
	if it == nil || it["status"] != "skipped" || !strings.Contains(it["reason"].(string), "needs your choice") ||
		it["rule"] != "review-thing" || it["group"] != "Review things" || it["bytes"] != float64(70_000) || it["freed_bytes"] != float64(0) {
		t.Errorf("the held-back item is reported, with what it is: %v", it)
	}
	if done := evs[len(evs)-1]; done["deleted"] != float64(2) || done["skipped"] != float64(1) {
		t.Errorf("done = %v", done)
	}
	if !present(review) || present(a.goCache) {
		t.Error("only the safe items go")
	}
}

func TestApply_JSONASelectionIsAnExplicitChoiceEvenForReviewItems(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "apply", "--yes", "--json", "--select-file", selection(t, review))
	if o.err != nil {
		t.Fatal(o.err)
	}
	evs := events(t, o.stdout)
	if it := itemFor(evs, review); it == nil || it["status"] != "deleted" {
		t.Errorf("a ticked review item is deleted: %v", it)
	}
	if present(review) || !a.cachesIntact() {
		t.Error("exactly the selected item goes")
	}
}

func TestApply_JSONIncludeReviewTakesEverything(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "apply", "--yes", "--json", "--include-review")
	if o.err != nil {
		t.Fatal(o.err)
	}
	if done := events(t, o.stdout); done[len(done)-1]["deleted"] != float64(3) || present(review) || present(a.goCache) {
		t.Errorf("--include-review is an explicit choice: %v", done[len(done)-1])
	}
}

func removeAllForTest(p string) error { return os.RemoveAll(p) } // the sandbox's own folders

func TestApply_ASelectionIsAnExplicitChoiceInTextModeToo(t *testing.T) {
	a := newApp(t)
	review := withReview(t, a)
	o := a.run("", "apply", "--yes", "--select-file", selection(t, review))
	if o.err != nil || present(review) || !a.cachesIntact() {
		t.Errorf("a selected review item is deleted, and only it: %v review=%v intact=%v\n%s", o.err, present(review), a.cachesIntact(), o.stdout)
	}
}
