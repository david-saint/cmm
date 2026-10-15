package cmd

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/rules"
)

// insideRule plans commands that free space inside another program's own storage (as Docker's prunes do): 2 GiB
// each that the volume will not see at once. With fail set, every command fails.
type insideRule struct {
	two  bool
	fail bool
}

const insideWhere = "the thing's own storage"
const insidePath = "inside: thing"
const insidePath2 = "inside: other thing"

func (insideRule) ID() string    { return "inside-thing" }
func (insideRule) Group() string { return "Inside things" }
func (r insideRule) Plan(context.Context, rules.Deps) ([]rules.Candidate, []rules.Skip, error) {
	c := rules.Candidate{Path: insidePath, Bytes: 2 << 30, Tier: rules.TierSafe, Action: rules.ActionCommand, FreesInside: insideWhere, Note: "frees space inside the thing"}
	out := []rules.Candidate{c}
	if r.two {
		c.Path = insidePath2
		out = append(out, c)
	}
	return out, nil, nil
}
func (insideRule) Allows(_ rules.Deps, p string) bool {
	return p == insidePath || p == insidePath2
}
func (insideRule) Recheck(context.Context, rules.Deps, rules.Candidate) error { return nil }
func (r insideRule) Execute(context.Context, rules.Deps, rules.Candidate) (int64, error) {
	if r.fail {
		return 0, errors.New("the thing refused")
	}
	return 2 << 30, nil
}

func withInside(a *app, r ...insideRule) {
	rule := insideRule{}
	if len(r) > 0 {
		rule = r[0]
	}
	a.eng.Rules = append(a.eng.Rules, rule)
}

func TestApplyJSON_SaysWhereSpaceWasFreedAndKeepsItOutOfTheVolumesFigure(t *testing.T) {
	a := newApp(t)
	withInside(a)
	o := a.run("", "apply", "--yes", "--json")
	if o.err != nil {
		t.Fatal(o.err)
	}
	evs := events(t, o.stdout)
	it := itemFor(evs, insidePath)
	if it == nil || it["status"] != "deleted" || it["frees_inside"] != insideWhere || it["freed_bytes"] != float64(2<<30) {
		t.Errorf("the item says what it freed and where: %v", it)
	}
	var onVolume float64
	for _, e := range evs {
		if e["event"] != "item" || e["status"] != "deleted" {
			continue
		}
		if _, inside := e["frees_inside"]; inside {
			continue
		}
		if e["path"] == a.goCache || e["path"] == a.npmCache {
			if _, has := e["frees_inside"]; has {
				t.Errorf("a cache frees space on the volume itself: %v", e)
			}
		}
		onVolume += e["freed_bytes"].(float64)
	}
	done := evs[len(evs)-1]
	if done["freed_inside_bytes"] != float64(2<<30) || done["freed_bytes"] != onVolume || onVolume <= 0 {
		t.Errorf("done: freed_bytes is what the volume got back (%v), freed_inside_bytes what went inside: %v", onVolume, done)
	}
}

func TestApplyJSON_WithNothingInsideTheFieldsAreZeroAndAbsent(t *testing.T) {
	a := newApp(t)
	o := a.run("", "apply", "--yes", "--json")
	if o.err != nil {
		t.Fatal(o.err)
	}
	evs := events(t, o.stdout)
	if _, has := itemFor(evs, a.goCache)["frees_inside"]; has {
		t.Errorf("frees_inside is only there when it is true: %v", itemFor(evs, a.goCache))
	}
	if done := evs[len(evs)-1]; done["freed_inside_bytes"] != float64(0) {
		t.Errorf("freed_inside_bytes is always there: %v", done)
	}
}

func TestApplyText_ExplainsWhyTheFreeSpaceDidNotGrowByThatMuch(t *testing.T) {
	a := newApp(t)
	withInside(a)
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatalf("apply failed: %v\n%s", o.err, o.stdout)
	}
	if !strings.Contains(o.stdout, "Freed inside "+insideWhere+": 2.0 GB") || !strings.Contains(o.stdout, "free space") {
		t.Errorf("the summary says what went where, so the free space line is not a mystery:\n%s", o.stdout)
	}
}

func TestApplyText_NothingInsideNothingSaid(t *testing.T) {
	a := newApp(t)
	if o := a.run("\n", "apply"); strings.Contains(o.stdout, "Freed inside") {
		t.Errorf("no such line when everything went to the volume:\n%s", o.stdout)
	}
}

func TestEngineModule_TheInteractiveScreenCountsOnlyWhatTheVolumeGotBackAndSaysTheRest(t *testing.T) {
	a := newApp(t)
	withInside(a)
	mods := engineModules(context.Background(), a.eng, planOf(t, a))
	var inside int
	for i, m := range mods {
		if m.Name() == "Inside things" {
			inside = i
		}
	}
	items, _ := mods[inside].Scan()
	res, err := mods[inside].Delete(items)
	if err != nil || res.Failed != 0 {
		t.Fatalf("Delete() = %+v, %v", res, err)
	}
	if res.Freed != 0 {
		t.Errorf("nothing was freed on the volume by this module: %d", res.Freed)
	}
	if len(res.Notes) != 1 || !strings.Contains(res.Notes[0], "2.0 GB") || !strings.Contains(res.Notes[0], insideWhere) {
		t.Errorf("the screen is told what went where: %v", res.Notes)
	}
}

func TestApplyText_TwoItemsInTheSameStorageAreOneLineWithTheirSum(t *testing.T) {
	a := newApp(t)
	withInside(a, insideRule{two: true})
	o := a.run("\n", "apply")
	if o.err != nil {
		t.Fatal(o.err)
	}
	if n := strings.Count(o.stdout, "Freed inside "+insideWhere); n != 1 || !strings.Contains(o.stdout, "Freed inside "+insideWhere+": 4.0 GB") {
		t.Errorf("one line per storage, with the total:\n%s", o.stdout)
	}
}

func TestApplyText_AFailedItemInsideSaysNothingWasFreed(t *testing.T) {
	a := newApp(t)
	withInside(a, insideRule{fail: true})
	o := a.run("\n", "apply")
	if strings.Contains(o.stdout, "Freed inside") {
		t.Errorf("a prune that failed freed nothing, and says nothing about it here:\n%s", o.stdout)
	}
	j := a.run("", "apply", "--yes", "--json")
	evs := events(t, j.stdout)
	if done := evs[len(evs)-1]; done["freed_inside_bytes"] != float64(0) {
		t.Errorf("done = %v", done)
	}
}

func TestHistoryText_ARunThatFreedSpaceInsideSaysSoInsteadOfLookingLikeAFailure(t *testing.T) {
	a := newApp(t)
	a.withHistory()
	withInside(a)
	if o := a.run("", "apply", "--yes", "--only", "inside-thing"); o.err != nil {
		t.Fatal(o.err)
	}
	o := a.run("", "history")
	if o.err != nil {
		t.Fatal(o.err)
	}
	if !strings.Contains(o.stdout, "freed 0 KB") || !strings.Contains(o.stdout, "+ 2.0 GB inside "+insideWhere) {
		t.Errorf("the disk got nothing back, and the line says where the 2.0 GB went:\n%s", o.stdout)
	}
}

func TestHistoryText_NoInsideNoSuffix(t *testing.T) {
	a := newApp(t)
	a.withHistory()
	if o := a.run("", "apply", "--yes"); o.err != nil {
		t.Fatal(o.err)
	}
	if o := a.run("", "history"); strings.Contains(o.stdout, "inside") {
		t.Errorf("nothing was freed inside anything:\n%s", o.stdout)
	}
}

func TestHistoryText_TwoItemsInTheSameStorageNameItOnce(t *testing.T) {
	a := newApp(t)
	a.withHistory()
	withInside(a, insideRule{two: true})
	if o := a.run("", "apply", "--yes", "--only", "inside-thing"); o.err != nil {
		t.Fatal(o.err)
	}
	o := a.run("", "history")
	if !strings.Contains(o.stdout, "+ 4.0 GB inside "+insideWhere+"\n") || strings.Contains(o.stdout, insideWhere+" and") {
		t.Errorf("one mention, with the total:\n%s", o.stdout)
	}
}
