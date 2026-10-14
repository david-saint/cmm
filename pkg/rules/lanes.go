package rules

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/sizer"
)

// laneAwayFrom names the folders whose contents say nothing about whether someone works in a lane: what is
// installed (node_modules, Pods) and git's own bookkeeping.
var laneAwayFrom = []string{"node_modules", "Pods", ".git"}

// LaneRule removes the heavy, regenerable folders of a project checkout (a "lane") once nobody has worked in
// the lane for IdleFor. A lane is a direct child folder of Root that has a package.json at its top; a folder
// without one, a link, or a project one level further down is not a lane and is never touched.
//
// A lane counts as used when any regular file in it was modified within IdleFor, ignoring what is installed
// and git's files (laneAwayFrom). Build output counts: a build is work. Only the exact folders in Subs
// directly below a lane are ever claimed.
type LaneRule struct {
	RuleID   string
	Label    string
	Root     string        // "~/lane-builds"
	Subs     []string      // folders below a lane to remove, slash separated: "node_modules", "ios/Pods"
	IdleFor  time.Duration // a lane unused for this long is idle
	MinBytes int64         // folders smaller than this are left out silently
	Tier     Tier          // empty means TierSafe
}

// ID implements Rule.
func (r *LaneRule) ID() string { return r.RuleID }

// Group implements Rule.
func (r *LaneRule) Group() string { return r.Label }

func (r *LaneRule) tier() Tier {
	if r.Tier == "" {
		return TierSafe
	}
	return r.Tier
}

// isLane reports whether dir is a project checkout: a real folder with a package.json file at its top.
func isLane(dir string) bool {
	if st, err := os.Lstat(dir); err != nil || !st.IsDir() {
		return false
	}
	st, err := os.Stat(filepath.Join(dir, "package.json"))
	return err == nil && st.Mode().IsRegular()
}

// usedWithin reports whether anyone worked in the lane within the idle limit. An answer that cannot be given
// (part of the lane cannot be read) is an error.
func (r *LaneRule) usedWithin(d Deps, lane string) (bool, error) {
	return d.Guard.RecentlyModified(lane, guard.Recent{Within: r.IdleFor, MaxDepth: -1, FilesOnly: true, Prune: laneAwayFrom})
}

func (r *LaneRule) idleWords() string {
	return fmt.Sprintf("untouched for %d+ days", int(r.IdleFor/(24*time.Hour)))
}

// laneRef is a path this rule claims, taken apart.
type laneRef struct {
	dir  string // the lane's folder
	name string // the lane's name
	sub  string // the folder below the lane, slash separated
}

// locate takes apart a path this rule may claim: a listed folder directly below a direct child of Root.
func (r *LaneRule) locate(d Deps, p string) (laneRef, bool) {
	root, ok := expandRoot(d, r.Root)
	if !ok || p == "" || filepath.Clean(p) != p || !strings.HasPrefix(p, root+string(filepath.Separator)) {
		return laneRef{}, false
	}
	name, sub, found := strings.Cut(p[len(root)+1:], string(filepath.Separator))
	sub = filepath.ToSlash(sub)
	if !found || name == "" || !slices.Contains(r.Subs, sub) {
		return laneRef{}, false
	}
	return laneRef{dir: filepath.Join(root, name), name: name, sub: sub}, true
}

// Allows implements Rule: only the listed folders directly below a direct child of Root. It is about the shape
// of the path; whether the child really is a lane is decided when planning and again when re-checking.
func (r *LaneRule) Allows(d Deps, p string) bool {
	_, ok := r.locate(d, p)
	return ok
}

// Plan implements Rule.
func (r *LaneRule) Plan(ctx context.Context, d Deps) ([]Candidate, []Skip, error) {
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
	if err := d.Policy.CheckNoSymlinks(root); err != nil {
		return nil, []Skip{{Reason: fmt.Sprintf("%s: %v", r.Label, err)}}, nil
	}

	var items []Candidate
	var skips []Skip
	for _, e := range entries {
		if !e.IsDir() { // files and links are not lanes
			continue
		}
		name := e.Name()
		lane := filepath.Join(root, name)
		if !isLane(lane) {
			continue
		}
		var present []string
		for _, sub := range r.Subs {
			if _, err := os.Lstat(filepath.Join(lane, filepath.FromSlash(sub))); err == nil {
				present = append(present, sub)
			}
		}
		if len(present) == 0 {
			continue // nothing to remove, so there is no need to walk the lane
		}
		used, err := r.usedWithin(d, lane)
		if err != nil {
			skips = append(skips, Skip{Reason: fmt.Sprintf("lane %s: could not check when it was last used (%v)", name, err)})
			continue
		}
		if used {
			continue
		}

		for _, sub := range present {
			p := filepath.Join(lane, filepath.FromSlash(sub))
			if err := d.Policy.CheckNoSymlinks(p); err != nil {
				skips = append(skips, Skip{Reason: fmt.Sprintf("lane %s: %s: %v", name, sub, err)})
				continue
			}
			inUse, err := d.Guard.InUse(ctx, p)
			if err != nil {
				skips = append(skips, Skip{Reason: fmt.Sprintf("lane %s: could not check whether %s is in use (%v)", name, sub, err)})
				continue
			}
			if inUse {
				skips = append(skips, Skip{Reason: fmt.Sprintf("lane %s: %s is in use", name, sub)})
				continue
			}
			res, err := sizer.Measure(p)
			if err != nil {
				skips = append(skips, Skip{Reason: fmt.Sprintf("lane %s: could not measure %s (%v)", name, sub, err)})
				continue
			}
			if res.Bytes < r.MinBytes {
				continue
			}
			c := Candidate{
				Rule: r.RuleID, Group: r.Label, Path: p, Bytes: res.Bytes, Tier: r.tier(), Action: ActionDelete,
				Note: fmt.Sprintf("lane %s: %s", name, r.idleWords()),
			}
			if res.Unreadable > 0 {
				c.Note += fmt.Sprintf("; %d entries could not be read, so the size is a lower bound", res.Unreadable)
			}
			items = append(items, c)
		}
	}
	return items, skips, nil
}

// Recheck implements Rule: the lane is judged again, because work can start between planning and applying.
func (r *LaneRule) Recheck(ctx context.Context, d Deps, c Candidate) error {
	ref, ok := r.locate(d, c.Path)
	if !ok {
		return fmt.Errorf("%s: %s is not a folder this rule removes", r.Label, c.Path)
	}
	if !isLane(ref.dir) {
		return fmt.Errorf("lane %s: is no longer a lane (no package.json)", ref.name)
	}
	used, err := r.usedWithin(d, ref.dir)
	if err != nil {
		return fmt.Errorf("lane %s: could not check when it was last used (%v)", ref.name, err)
	}
	if used {
		return fmt.Errorf("lane %s: used again since the plan was made", ref.name)
	}
	if err := d.Policy.CheckNoSymlinks(c.Path); err != nil {
		return fmt.Errorf("lane %s: %s: %v", ref.name, ref.sub, err)
	}
	inUse, err := d.Guard.InUse(ctx, c.Path)
	if err != nil {
		return fmt.Errorf("lane %s: could not check whether %s is in use (%v)", ref.name, ref.sub, err)
	}
	if inUse {
		return fmt.Errorf("lane %s: %s is in use", ref.name, ref.sub)
	}
	return nil
}
