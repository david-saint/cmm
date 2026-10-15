package cmd

import (
	"context"
	"fmt"

	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
)

// engineModule shows one rule of the engine's plan on the interactive screen. It decides nothing: it lists what
// the engine planned, and whatever is picked is deleted through Engine.Apply, which checks every item again
// (policy, the rule's own claim, symlinks, guards) right before removing it.
type engineModule struct {
	ctx   context.Context
	eng   *engine.Engine
	group string
	items []rules.Candidate // the plan's items for this rule, in plan order
}

// engineModules makes one module per rule that has something in the plan, in plan order.
func engineModules(ctx context.Context, eng *engine.Engine, plan *engine.Plan) []cmm.Module {
	var order []string
	byRule := map[string]*engineModule{}
	for _, c := range plan.Items {
		m, ok := byRule[c.Rule]
		if !ok {
			m = &engineModule{ctx: ctx, eng: eng, group: c.Group}
			byRule[c.Rule] = m
			order = append(order, c.Rule)
		}
		m.items = append(m.items, c)
	}
	mods := make([]cmm.Module, 0, len(order))
	for _, id := range order {
		mods = append(mods, byRule[id])
	}
	return mods
}

func (m *engineModule) Name() string { return m.group }

func (m *engineModule) Description() string {
	return fmt.Sprintf("%d item(s) planned by the engine", len(m.items))
}

// Category is "Recommended" for regenerable (safe) items and "Harsh" for anything else, which the screen
// then asks about with its stronger warning.
func (m *engineModule) Category() string {
	for _, c := range m.items {
		if c.Tier != rules.TierSafe {
			return "Harsh"
		}
	}
	return "Recommended"
}

func (m *engineModule) Scan() ([]cmm.FileItem, error) {
	items := make([]cmm.FileItem, 0, len(m.items))
	for _, c := range m.items {
		kind := "dir"
		if c.Action == rules.ActionCommand {
			kind = "summary"
		}
		items = append(items, cmm.FileItem{Path: c.Path, Size: c.Bytes, Type: kind})
	}
	return items, nil
}

// Delete never trusts the paths it is given: each must be an item of this module's own plan, or nothing at all
// is deleted. The items then go through Engine.Apply, so a guard that no longer holds skips the item, and what
// is reported is what really happened.
func (m *engineModule) Delete(items []cmm.FileItem) (cmm.DeleteResult, error) {
	planned := make(map[string]rules.Candidate, len(m.items))
	for _, c := range m.items {
		planned[c.Path] = c
	}
	chosen := make([]rules.Candidate, 0, len(items))
	for _, it := range items {
		c, ok := planned[it.Path]
		if !ok {
			return cmm.DeleteResult{}, fmt.Errorf("%q is not in the plan for %s: nothing was deleted", it.Path, m.group)
		}
		chosen = append(chosen, c)
	}

	rep, err := m.eng.Apply(m.ctx, &engine.Plan{Items: chosen}, engine.ApplyOptions{})
	res := cmm.DeleteResult{Freed: rep.FreedBytes, Skipped: rep.Skipped, Failed: rep.Failed}
	home := m.eng.Deps.Env.Home
	for _, r := range rep.Results {
		switch r.Status {
		case engine.StatusSkipped:
			res.Notes = append(res.Notes, fmt.Sprintf("skipped: %s: %s", shortPath(r.Item.Path, home), r.Reason))
		case engine.StatusFailed:
			res.Notes = append(res.Notes, fmt.Sprintf("FAILED: %s: %s", shortPath(r.Item.Path, home), r.Reason))
		}
	}
	for _, w := range rep.Warnings {
		res.Notes = append(res.Notes, "warning: "+w)
	}
	return res, err
}
