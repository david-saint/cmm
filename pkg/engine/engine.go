// Package engine turns rules into a plan and a plan into deletions, and is the only place cmm deletes anything.
//
// The safety invariants live here, not in the rules: a path is acted on only if the policy accepts it, the
// rule that planned it still allows it, it is not a symlink and the rule's own guards still hold. A rule that
// breaks those expectations while planning is a bug and fails the whole plan instead of being ignored.
package engine

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"syscall"
	"time"

	"github.com/david-saint/cmm/pkg/rules"
)

// SchemaVersion is the version of the JSON plan format.
const SchemaVersion = 1

// ErrRuleBug marks a rule that planned something it is not allowed to. It is returned from Plan and never
// swallowed: fixing the rule is the only correct response.
var ErrRuleBug = errors.New("engine: rule bug")

// Host describes the volume cmm cleans.
type Host struct {
	Volume        string `json:"volume"`
	FreeBytes     int64  `json:"free_bytes"`
	CapacityBytes int64  `json:"capacity_bytes,omitempty"` // how big the volume is; left out when that is not known
}

// Group is one labelled block of items in a plan.
type Group struct {
	Group string `json:"group"`
	Bytes int64  `json:"bytes"`
	Count int    `json:"count"`
}

// Plan is everything cmm would do, as metadata only (paths, sizes, tiers, reasons).
type Plan struct {
	SchemaVersion int               `json:"schema_version"`
	GeneratedAt   time.Time         `json:"generated_at"`
	Host          Host              `json:"host"`
	Items         []rules.Candidate `json:"items"`
	Groups        []Group           `json:"groups"`
	Skipped       []rules.Skip      `json:"skipped"`
	TotalBytes    int64             `json:"total_bytes"`
}

// Engine runs rules against Deps. Free and Remove can be replaced in tests.
type Engine struct {
	Deps  rules.Deps
	Rules []rules.Rule

	// Free reports the volume cmm cleans and its free bytes. Nil uses statfs.
	Free func() (volume string, freeBytes int64, err error)
	// Capacity reports how big that volume is (0 when unknown). Nil uses statfs, unless Free is replaced: then the
	// size is unknown too, so a test never reads the real disk.
	Capacity func() int64
	// Remove deletes a path. Nil uses os.RemoveAll. Either way, while a test is running, anything outside a
	// temporary directory makes the engine panic instead of deleting.
	Remove func(path string) error
	// Journal keeps the audit trail of real applies (a dry run never touches it). Nil keeps none; the
	// commands set it where the engine is built for real use.
	Journal Journal
	// History keeps a structured record of each real apply that deleted or failed something. Nil keeps none; the
	// commands set it where the engine is built for real use. It is only ever written by Apply, and nothing that
	// decides what may be deleted reads it.
	History RunLog
}

// New returns an Engine for the given rules.
func New(deps rules.Deps, rs []rules.Rule) *Engine {
	return &Engine{Deps: deps, Rules: rs}
}

func (e *Engine) free() (string, int64, error) {
	if e.Free != nil {
		return e.Free()
	}
	return realFree(e.Deps.Env.Home)
}

func (e *Engine) capacity() int64 {
	switch {
	case e.Capacity != nil:
		return e.Capacity()
	case e.Free != nil:
		return 0
	}
	return realCapacity(e.Deps.Env.Home)
}

// Host describes the volume now: its name, its free space and (when known) its size. Unlike Plan it reports
// when the free space cannot be read, so a caller never takes a failure for an empty disk.
func (e *Engine) Host() (Host, error) {
	vol, free, err := e.free()
	if err != nil {
		return Host{}, err
	}
	return Host{Volume: vol, FreeBytes: free, CapacityBytes: e.capacity()}, nil
}

// statVolume reads the Data volume (or the home directory's volume as a fallback).
func statVolume(home string) (string, syscall.Statfs_t, error) {
	for _, v := range []string{"/System/Volumes/Data", home} {
		var st syscall.Statfs_t
		if err := syscall.Statfs(v, &st); err == nil {
			return v, st, nil
		}
	}
	return "", syscall.Statfs_t{}, errors.New("engine: cannot read the volume")
}

// realFree reads the free bytes of the Data volume (or the home directory's volume as a fallback).
func realFree(home string) (string, int64, error) {
	v, st, err := statVolume(home)
	if err != nil {
		return "", 0, errors.New("engine: cannot read the free space")
	}
	return v, int64(st.Bavail) * int64(st.Bsize), nil
}

// realCapacity reads how big that same volume is, or 0 when it cannot be read.
func realCapacity(home string) int64 {
	_, st, err := statVolume(home)
	if err != nil {
		return 0
	}
	return int64(st.Blocks) * int64(st.Bsize)
}

// permit is the one question asked both when planning and again right before acting.
func (e *Engine) permit(r rules.Rule, c rules.Candidate) error {
	if !c.Tier.Valid() {
		return fmt.Errorf("unknown tier %q", c.Tier)
	}
	switch c.Action {
	case rules.ActionDelete:
	case rules.ActionCommand:
		if _, ok := r.(rules.Executor); !ok {
			return fmt.Errorf("rule %s plans a command but has no Executor", r.ID())
		}
	default:
		return fmt.Errorf("unknown action %q", c.Action)
	}

	// Anything that names a filesystem path is checked, whatever the action: a rule cannot dodge the policy
	// by calling a deletion a "command". Pseudo-paths (such as "homebrew: cleanup") are command-only.
	if filepath.IsAbs(c.Path) || c.Action == rules.ActionDelete {
		if err := e.Deps.Policy.ValidateTarget(c.Path); err != nil {
			return err
		}
		if err := e.Deps.Policy.CheckNoSymlinks(c.Path); err != nil {
			return err
		}
	}
	if !r.Allows(e.Deps, c.Path) {
		return fmt.Errorf("rule %s does not allow %q", r.ID(), c.Path)
	}
	return nil
}

// Allowed reports whether cmm could ever delete path: some rule claims it, the policy accepts it and no folder
// between the home folder (or temp dir) and it is a symbolic link. It never plans, re-checks or acts; it is the
// allow-list question on its own, so the limits of the rules can be tested without a machine to clean. The
// action names of command rules ("homebrew: cleanup") are not paths and are never allowed here.
func (e *Engine) Allowed(path string) bool {
	if e.Deps.Policy.ValidateTarget(path) != nil || e.Deps.Policy.CheckNoSymlinks(path) != nil {
		return false
	}
	for _, r := range e.Rules {
		if r.Allows(e.Deps, path) {
			return true
		}
	}
	return false
}

// Plan asks every rule what it would remove. A rule that cannot run becomes a skip; a rule that plans
// something it is not allowed to is a bug and fails the whole plan.
func (e *Engine) Plan(ctx context.Context) (*Plan, error) {
	vol, free, _ := e.free()
	plan := &Plan{
		SchemaVersion: SchemaVersion,
		GeneratedAt:   e.Deps.Env.Clock(),
		Host:          Host{Volume: vol, FreeBytes: free, CapacityBytes: e.capacity()},
		Items:         []rules.Candidate{},
		Groups:        []Group{},
		Skipped:       []rules.Skip{},
	}
	owner := make(map[string]string)

	for _, r := range e.Rules {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		items, skips, err := r.Plan(ctx, e.Deps)
		if err != nil {
			if ctxErr := ctx.Err(); ctxErr != nil {
				return nil, ctxErr
			}
			plan.Skipped = append(plan.Skipped, rules.Skip{Rule: r.ID(), Reason: "could not plan: " + err.Error()})
			continue
		}
		for _, c := range items {
			c.Rule = r.ID()
			if c.Group == "" {
				c.Group = r.Group()
			}
			if err := e.permit(r, c); err != nil {
				return nil, fmt.Errorf("%w: rule %s planned %q: %w", ErrRuleBug, r.ID(), c.Path, err)
			}
			if prev, dup := owner[c.Path]; dup {
				return nil, fmt.Errorf("%w: %q is planned by both %s and %s", ErrRuleBug, c.Path, prev, r.ID())
			}
			owner[c.Path] = r.ID()
			plan.Items = append(plan.Items, c)
		}
		for _, s := range skips {
			s.Rule = r.ID()
			plan.Skipped = append(plan.Skipped, s)
		}
	}

	index := make(map[string]int)
	for _, c := range plan.Items {
		i, ok := index[c.Group]
		if !ok {
			i = len(plan.Groups)
			index[c.Group] = i
			plan.Groups = append(plan.Groups, Group{Group: c.Group})
		}
		plan.Groups[i].Bytes += c.Bytes
		plan.Groups[i].Count++
		plan.TotalBytes += c.Bytes
	}
	return plan, nil
}
