// Package rules defines what a cleanup rule is and holds the built-in rules.
//
// A rule decides which paths are worth deleting (Plan), which paths it is willing to be responsible for
// (Allows) and whether a planned item is still safe right before it is deleted (Recheck). The engine
// never deletes anything a rule does not Allow.
package rules

import (
	"context"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/sys"
)

// Tier says how much thought an item deserves.
type Tier string

const (
	// TierSafe is regenerable (caches, build output): the owner loses nothing but rebuild time.
	TierSafe Tier = "safe"
	// TierReview is something the owner might want back; reserved for later milestones.
	TierReview Tier = "review"
	// TierManual needs administrator rights or a hand-run script; reserved for later milestones.
	TierManual Tier = "manual"
)

// Valid reports whether t is a known tier.
func (t Tier) Valid() bool { return t == TierSafe || t == TierReview || t == TierManual }

// Action says how an item is removed.
type Action string

const (
	// ActionDelete removes the path from disk.
	ActionDelete Action = "delete"
	// ActionCommand is carried out by the rule's Executor (Homebrew cleanup, simulator delete, ...).
	ActionCommand Action = "command"
)

// Valid reports whether a is a known action.
func (a Action) Valid() bool { return a == ActionDelete || a == ActionCommand }

// Candidate is one thing a rule proposes to remove.
type Candidate struct {
	Rule   string `json:"rule"`
	Group  string `json:"group"`
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	Tier   Tier   `json:"tier"`
	Action Action `json:"action"`
	Note   string `json:"note,omitempty"`
}

// Skip explains why a rule left something out. Skips are information, not errors.
type Skip struct {
	Rule   string `json:"rule"`
	Reason string `json:"reason"`
}

// Deps is what a rule may use from the world. Tests fill it from a sandbox.
type Deps struct {
	Env    *sys.Env
	Guard  *guard.Guard
	Policy *policy.Policy
}

// Rule is one cleanup rule.
type Rule interface {
	// ID is the stable machine name, e.g. "go-build".
	ID() string
	// Group is the human label items are listed under.
	Group() string
	// Plan inspects the machine and proposes candidates. A returned error means the rule could not run at all;
	// reasons to leave individual items out belong in the Skip list.
	Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error)
	// Allows reports whether this rule claims path as something it may delete. It is a structural check only.
	Allows(d Deps, path string) bool
	// Recheck is called right before an item is removed and must return an error if anything that made the
	// item safe at planning time (a guard, a process, an age) no longer holds.
	Recheck(ctx context.Context, d Deps, c Candidate) error
}

// Executor is implemented by rules whose items have ActionCommand.
type Executor interface {
	// Execute carries the item out and returns the bytes it freed. A negative number means the rule cannot
	// tell, and the engine then uses the planned size; 0 means it freed nothing, and is believed.
	Execute(ctx context.Context, d Deps, c Candidate) (freed int64, err error)
}
