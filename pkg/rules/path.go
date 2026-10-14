package rules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/sizer"
)

// PathRule removes fixed directories that rebuild on demand (caches, build output).
//
// Targets are templates that must start with "~/" (the home directory) or "{tmp}/" (the per-user temp
// directory); anything else is ignored, so a rule can never name a path outside those two roots. The rule
// only ever claims the exact targets, never their parents, siblings or children.
type PathRule struct {
	RuleID     string
	Label      string           // group label shown to the user
	Targets    []string         // path templates, see above
	MinBytes   int64            // targets smaller than this are left out silently
	Block      []guard.ProcSpec // if any of these processes runs, the rule skips itself
	BlockedMsg string           // why, in words ("a go command is running")
	CheckInUse bool             // also skip a target that has files open
	Tier       Tier             // empty means TierSafe
}

// ID implements Rule.
func (r *PathRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *PathRule) Group() string { return r.Label }

func (r *PathRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

func (r *PathRule) resolved(d Deps) []string {
	out := make([]string, 0, len(r.Targets))
	for _, t := range r.Targets {
		if p, ok := expand(d, t); ok {
			out = append(out, p)
		}
	}
	return out
}

// Allows implements Rule: only the exact targets.
func (r *PathRule) Allows(d Deps, path string) bool {
	if path == "" || filepath.Clean(path) != path {
		return false
	}
	return slices.Contains(r.resolved(d), path)
}

// processGuard returns an error with the reason if a blocking process runs or cannot be checked.
func (r *PathRule) processGuard(ctx context.Context, d Deps) error {
	return blockedBy(ctx, d, r.Label, r.Block, r.BlockedMsg)
}

func (r *PathRule) inUseGuard(ctx context.Context, d Deps, path string) error {
	if !r.CheckInUse {
		return nil
	}
	inUse, err := d.Guard.InUse(ctx, path)
	if err != nil {
		return fmt.Errorf("%s: could not check whether anything has files open in it (%v)", r.Label, err)
	}
	if inUse {
		return fmt.Errorf("%s: something has files open in it", r.Label)
	}
	return nil
}

// Plan implements Rule.
func (r *PathRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	var skips []Skip
	var existing []string
	for _, p := range r.resolved(d) {
		if _, err := os.Lstat(p); err != nil {
			continue // nothing there, nothing to say
		}
		if err := d.Policy.CheckNoSymlinks(p); err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s: %v", r.Label, err)})
			continue
		}
		existing = append(existing, p)
	}
	if len(existing) == 0 {
		return nil, skips, nil
	}
	if err := r.processGuard(ctx, d); err != nil {
		return nil, append(skips, Skip{Reason: err.Error()}), nil
	}

	var items []Candidate
	for _, p := range existing {
		if err := r.inUseGuard(ctx, d, p); err != nil {
			skips = append(skips, Skip{Reason: err.Error()})
			continue
		}
		res, err := sizer.Measure(p)
		if err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s: could not measure %s (%v)", r.Label, p, err)})
			continue
		}
		if res.Bytes < r.MinBytes {
			continue
		}
		c := Candidate{Rule: r.RuleID, Group: r.Label, Path: p, Bytes: res.Bytes, Tier: r.tier(), Action: ActionDelete}
		if res.Unreadable > 0 {
			c.Note = fmt.Sprintf("%d entries could not be read, so the size is a lower bound", res.Unreadable)
		}
		items = append(items, c)
	}
	return items, skips, nil
}

// Recheck implements Rule: the same guards, asked again right before deletion.
func (r *PathRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	if err := r.processGuard(ctx, d); err != nil {
		return err
	}
	return r.inUseGuard(ctx, d, c.Path)
}
