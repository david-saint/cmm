package engine

import (
	"slices"

	"github.com/david-saint/cmm/pkg/rules"
)

// Only returns a copy of the plan restricted to the named rules, with groups and totals recomputed, so what is
// shown to the user is exactly what Apply will do with the same filter. No ids means no filtering.
func (p *Plan) Only(ids ...string) *Plan {
	keep := func(rule string) bool { return len(ids) == 0 || slices.Contains(ids, rule) }
	var skips []rules.Skip
	for _, s := range p.Skipped {
		if keep(s.Rule) {
			skips = append(skips, s)
		}
	}
	return p.restrict(func(c rules.Candidate) bool { return keep(c.Rule) }, skips)
}

// OnlyPaths returns a copy of the plan restricted to the items whose path is exactly one of paths, with groups
// and totals recomputed, plus the requested paths that are not an item of the plan (each once, in the order
// asked). A selection can only narrow a plan, never widen it: nothing that is not already planned can be added.
// An empty selection keeps nothing (unlike Only, where no ids means no filtering). What the guards skipped is
// information about the plan and is kept.
func (p *Plan) OnlyPaths(paths []string) (*Plan, []string) {
	want := make(map[string]bool, len(paths))
	for _, s := range paths {
		want[s] = true
	}
	found := make(map[string]bool, len(paths))
	out := p.restrict(func(c rules.Candidate) bool {
		if want[c.Path] {
			found[c.Path] = true
			return true
		}
		return false
	}, p.Skipped)

	missing := []string{}
	seen := make(map[string]bool, len(paths))
	for _, s := range paths {
		if !found[s] && !seen[s] {
			seen[s] = true
			missing = append(missing, s)
		}
	}
	return out, missing
}

// restrict copies the plan with the items keep accepts, the given skips, and groups and totals recomputed.
func (p *Plan) restrict(keep func(rules.Candidate) bool, skips []rules.Skip) *Plan {
	out := *p
	out.Items = []rules.Candidate{}
	out.Groups = []Group{}
	out.Skipped = append([]rules.Skip{}, skips...)
	out.TotalBytes = 0

	index := make(map[string]int)
	for _, c := range p.Items {
		if !keep(c) {
			continue
		}
		out.Items = append(out.Items, c)
		i, ok := index[c.Group]
		if !ok {
			i = len(out.Groups)
			index[c.Group] = i
			out.Groups = append(out.Groups, Group{Group: c.Group})
		}
		out.Groups[i].Bytes += c.Bytes
		out.Groups[i].Count++
		out.TotalBytes += c.Bytes
	}
	return &out
}

// SafeOnly returns a copy of the plan with only the items of tier safe, and the items it held back (every other
// tier, and a missing or unknown one). Safe items are the regenerable ones a plain apply may take; anything else
// needs a person's explicit choice. Groups and totals are recomputed for what stays.
func (p *Plan) SafeOnly() (*Plan, []rules.Candidate) {
	held := []rules.Candidate{}
	out := p.restrict(func(c rules.Candidate) bool {
		if c.Tier == rules.TierSafe {
			return true
		}
		held = append(held, c)
		return false
	}, p.Skipped)
	return out, held
}
