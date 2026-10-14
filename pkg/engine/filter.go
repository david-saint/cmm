package engine

import (
	"slices"

	"github.com/david-saint/cmm/pkg/rules"
)

// Only returns a copy of the plan restricted to the named rules, with groups and totals recomputed, so what is
// shown to the user is exactly what Apply will do with the same filter. No ids means no filtering.
func (p *Plan) Only(ids ...string) *Plan {
	out := *p
	out.Items = []rules.Candidate{}
	out.Groups = []Group{}
	out.Skipped = []rules.Skip{}
	out.TotalBytes = 0

	keep := func(rule string) bool { return len(ids) == 0 || slices.Contains(ids, rule) }
	index := make(map[string]int)
	for _, c := range p.Items {
		if !keep(c.Rule) {
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
	for _, s := range p.Skipped {
		if keep(s.Rule) {
			out.Skipped = append(out.Skipped, s)
		}
	}
	return &out
}
