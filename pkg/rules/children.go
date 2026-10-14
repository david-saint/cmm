package rules

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/sizer"
)

// ChildrenRule removes direct children of a folder whose names match a pattern (temporary output, a staged
// update). It only ever claims those children, never the folder itself or anything nested deeper.
type ChildrenRule struct {
	RuleID     string
	Label      string
	Root       string           // "~/folder" or "{tmp}"; see expandRoot
	Pattern    string           // path.Match pattern for a child's name
	Also       []string         // exact child names planned too, but only when at least one Pattern child exists
	OlderThan  time.Duration    // Pattern children must be strictly older than this (zero: no age filter)
	MinBytes   int64            // children smaller than this are left out silently
	Block      []guard.ProcSpec // if any of these processes runs, the rule skips itself
	BlockedMsg string           // why, in words
	Tier       Tier             // empty means TierSafe
}

// ID implements Rule.
func (r *ChildrenRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *ChildrenRule) Group() string { return r.Label }

func (r *ChildrenRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

func (r *ChildrenRule) matches(name string) bool {
	if r.Pattern == "" {
		return false
	}
	ok, _ := path.Match(r.Pattern, name)
	return ok
}

func (r *ChildrenRule) isAlso(name string) bool { return slices.Contains(r.Also, name) }

// olderThanLimit reports whether a modification time is far enough in the past (strictly older).
func (r *ChildrenRule) olderThanLimit(now, mtime time.Time) bool {
	return r.OlderThan <= 0 || now.Sub(mtime) > r.OlderThan
}

// Plan implements Rule.
func (r *ChildrenRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
	root, ok := expandRoot(d, r.Root)
	if !ok {
		return nil, nil, nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, nil
		}
		return nil, []Skip{{Reason: fmt.Sprintf("%s: cannot read %s (%v)", r.Label, root, err)}}, nil
	}

	now := d.Env.Clock()
	var skips []Skip
	var paths []string
	hasMatch := false
	for _, e := range entries {
		if !r.matches(e.Name()) {
			continue
		}
		hasMatch = true
		p := filepath.Join(root, e.Name())
		if err := d.Policy.CheckNoSymlinks(p); err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("%s: %v", r.Label, err)})
			continue
		}
		info, err := os.Lstat(p)
		if err != nil || !r.olderThanLimit(now, info.ModTime()) {
			continue
		}
		paths = append(paths, p)
	}
	if hasMatch {
		for _, name := range r.Also {
			p := filepath.Join(root, name)
			if _, err := os.Lstat(p); err != nil {
				continue
			}
			if err := d.Policy.CheckNoSymlinks(p); err != nil {
				skips = append(skips, Skip{Reason: fmt.Sprintf("%s: %v", r.Label, err)})
				continue
			}
			paths = append(paths, p)
		}
	}
	if len(paths) == 0 {
		return nil, skips, nil
	}
	if err := blockedBy(ctx, d, r.Label, r.Block, r.BlockedMsg); err != nil {
		return nil, append(skips, Skip{Reason: err.Error()}), nil
	}

	var items []Candidate
	for _, p := range paths {
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

// Allows implements Rule: only direct children that match the pattern or are named in Also.
func (r *ChildrenRule) Allows(d Deps, p string) bool {
	root, ok := expandRoot(d, r.Root)
	if !ok || p == "" || filepath.Clean(p) != p || !policy.ChildOf(p, root) {
		return false
	}
	name := filepath.Base(p)
	return r.matches(name) || r.isAlso(name)
}

// Recheck implements Rule: the guards again, and the age again for pattern children.
func (r *ChildrenRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	if err := blockedBy(ctx, d, r.Label, r.Block, r.BlockedMsg); err != nil {
		return err
	}
	if r.OlderThan > 0 && r.matches(filepath.Base(c.Path)) {
		info, err := os.Lstat(c.Path)
		if err == nil && !r.olderThanLimit(d.Env.Clock(), info.ModTime()) {
			return fmt.Errorf("%s: %s changed within the last %v", r.Label, c.Path, r.OlderThan)
		}
	}
	return nil
}
