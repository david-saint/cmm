package engine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/david-saint/cmm/pkg/rules"
)

// untouchable is a rule whose Plan and Recheck must never be called by a plain "is this allowed" question.
type untouchable struct {
	*fakeRule
	t *testing.T
}

func (u untouchable) Plan(context.Context, rules.Deps) ([]rules.Candidate, []rules.Skip, error) {
	u.t.Error("Allowed must not plan")
	return nil, nil, nil
}

func (u untouchable) Recheck(context.Context, rules.Deps, rules.Candidate) error {
	u.t.Error("Allowed must not re-check")
	return nil
}

func TestAllowed_ARuleThePolicyAndNoSymlinksMustAllAgree(t *testing.T) {
	f := newFixture(t, untouchable{&fakeRule{id: "caches", allow: func(p string) bool { return strings.HasSuffix(p, "/cache") }}, t})
	ok := f.sb.Home("Library", "Caches", "tool", "cache")

	if !f.eng.Allowed(ok) {
		t.Errorf("a path a rule claims, the policy accepts and that has no link on the way must be allowed")
	}

	for name, p := range map[string]string{
		"no rule claims it":           f.sb.Home("Library", "Caches", "tool", "other"),
		"the policy forbids it":       f.sb.Home("Documents", "tool", "cache"),
		"directly in the home folder": f.sb.Home("cache"),
		"the home folder":             f.sb.Home(),
		"outside home and temp":       filepath.Join(f.sb.Root, "elsewhere", "tool", "cache"),
		"empty":                       "",
		"relative":                    "tool/cache",
		"not clean":                   f.sb.Home("Library", "Caches", "tool") + "/x/../cache",
	} {
		if f.eng.Allowed(p) {
			t.Errorf("%s (%q) must not be allowed", name, p)
		}
	}
}

func TestAllowed_ALinkAnywhereBelowTheRootRefuses(t *testing.T) {
	f := newFixture(t, &fakeRule{id: "all", allow: func(string) bool { return true }})
	real := f.sb.Home("projects", "real")
	if err := os.MkdirAll(filepath.Join(real, "node_modules"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := f.sb.Home("lane-builds", "linked")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}

	if !f.eng.Allowed(real + "/node_modules") {
		t.Error("the same folder reached without a link is fine")
	}
	for name, p := range map[string]string{
		"through a linked parent": filepath.Join(link, "node_modules"),
		"the link itself":         link,
	} {
		if f.eng.Allowed(p) {
			t.Errorf("%s (%q) must not be allowed", name, p)
		}
	}
}

func TestAllowed_AnyOneRuleIsEnoughAndNoRulesMeansNo(t *testing.T) {
	p := "/placeholder"
	f := newFixture(t,
		&fakeRule{id: "no", allow: func(string) bool { return false }},
		&fakeRule{id: "yes", allow: func(q string) bool { return q == p }},
	)
	p = f.sb.Home("Library", "Caches", "tool", "cache")
	if !f.eng.Allowed(p) {
		t.Error("one rule claiming the path is enough")
	}
	f.eng.Rules = nil
	if f.eng.Allowed(p) {
		t.Error("without rules nothing is allowed")
	}
}

func TestAllowed_PseudoPathsOfCommandRulesAreNotPaths(t *testing.T) {
	f := newFixture(t, &fakeRule{id: "homebrew", allow: func(p string) bool { return p == "homebrew: cleanup" }})
	if f.eng.Allowed("homebrew: cleanup") {
		t.Error("an action name is not a path anyone may delete")
	}
}
