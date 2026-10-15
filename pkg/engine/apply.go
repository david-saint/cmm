package engine

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"time"

	"github.com/david-saint/cmm/pkg/rules"
)

// Status is what happened to one item.
type Status string

const (
	StatusDeleted Status = "deleted"
	StatusDryRun  Status = "dry-run"
	StatusSkipped Status = "skipped"
	StatusFailed  Status = "failed"
)

// ApplyOptions tunes Apply.
type ApplyOptions struct {
	DryRun   bool         // look at every item, change nothing
	Only     []string     // rule ids to act on; empty means all
	OnResult func(Result) // called after each item, in plan order
}

// Result is the outcome for one item.
type Result struct {
	Item       rules.Candidate `json:"item"`
	Status     Status          `json:"status"`
	Reason     string          `json:"reason,omitempty"`
	FreedBytes int64           `json:"freed_bytes"`
}

// Report summarises an Apply.
type Report struct {
	DryRun     bool     `json:"dry_run"`
	Results    []Result `json:"results"`
	Deleted    int      `json:"deleted"`
	Skipped    int      `json:"skipped"`
	Failed     int      `json:"failed"`
	FreedBytes int64    `json:"freed_bytes"`
	FreeBefore int64    `json:"free_before"`
	FreeAfter  int64    `json:"free_after"`
	// Warnings are problems with the record of the run (the cleanup log or the stamp could not be written),
	// each reported once. They never count as failures: the cleanup itself did what it says.
	Warnings []string `json:"warnings,omitempty"`
}

// OK reports whether nothing failed. Skipped items are not failures.
func (r *Report) OK() bool { return r.Failed == 0 }

func (r *Report) warn(msg string) {
	for _, w := range r.Warnings {
		if w == msg {
			return
		}
	}
	r.Warnings = append(r.Warnings, msg)
}

// Apply carries out a plan, one item at a time. Before each item it asks again whether the item is still
// permitted and still safe; an item that fails is reported and the run goes on. If the context ends, the
// report so far is returned together with the context's error.
func (e *Engine) Apply(ctx context.Context, plan *Plan, opts ApplyOptions) (*Report, error) {
	rep := &Report{DryRun: opts.DryRun, Results: []Result{}}
	started := e.Deps.Env.Clock()
	_, rep.FreeBefore, _ = e.free()

	journal := e.Journal
	if opts.DryRun {
		journal = nil // a dry run changes nothing, so it leaves no trace either
	}

	only := make(map[string]bool, len(opts.Only))
	for _, id := range opts.Only {
		only[id] = true
	}
	byID := make(map[string]rules.Rule, len(e.Rules))
	for _, r := range e.Rules {
		byID[r.ID()] = r
	}

	var stopped error
	for _, c := range plan.Items {
		if len(only) > 0 && !only[c.Rule] {
			continue
		}
		if err := ctx.Err(); err != nil {
			stopped = err
			break
		}
		res := e.applyOne(ctx, byID, c, opts.DryRun)
		switch res.Status {
		case StatusDeleted:
			rep.Deleted++
			rep.FreedBytes += res.FreedBytes
		case StatusSkipped:
			rep.Skipped++
		case StatusFailed:
			rep.Failed++
		}
		rep.Results = append(rep.Results, res)
		if journal != nil && (res.Status == StatusDeleted || res.Status == StatusFailed) {
			// applyOne has already checked that a deleted path is gone, so a line is never written for
			// something that is still there. Skipped items changed nothing and are not recorded. A journal
			// error is a warning: it must not stop the run.
			if err := journal.Record(res); err != nil {
				rep.warn("cleanup log: " + err.Error())
			}
		}
		if opts.OnResult != nil {
			opts.OnResult(res)
		}
	}
	if journal != nil && rep.Deleted > 0 {
		if err := journal.Stamp(); err != nil {
			rep.warn("last-run stamp: " + err.Error())
		}
	}
	_, rep.FreeAfter, _ = e.free()
	if !opts.DryRun && e.History != nil && (rep.Deleted > 0 || rep.Failed > 0) {
		if err := e.History.Append(e.run(rep, started, stopped != nil)); err != nil {
			rep.warn("history: " + err.Error())
		}
	}
	return rep, stopped
}

// run turns a finished report into the record kept in the history: the totals, and the items that were deleted or
// failed (skipped ones changed nothing and are only counted).
func (e *Engine) run(rep *Report, started time.Time, stopped bool) Run {
	r := Run{
		StartedAt: started, FinishedAt: e.Deps.Env.Clock(),
		Deleted: rep.Deleted, Skipped: rep.Skipped, Failed: rep.Failed, FreedBytes: rep.FreedBytes,
		FreeBefore: rep.FreeBefore, FreeAfter: rep.FreeAfter, CapacityBytes: e.capacity(),
		Stopped: stopped, Items: []RunItem{},
	}
	for _, res := range rep.Results {
		if res.Status != StatusDeleted && res.Status != StatusFailed {
			continue
		}
		r.Items = append(r.Items, RunItem{
			Rule: res.Item.Rule, Group: res.Item.Group, Path: res.Item.Path, Status: res.Status,
			Bytes: res.Item.Bytes, FreedBytes: res.FreedBytes, Reason: res.Reason,
		})
	}
	return r
}

func (e *Engine) applyOne(ctx context.Context, byID map[string]rules.Rule, c rules.Candidate, dryRun bool) Result {
	res := Result{Item: c}
	fail := func(status Status, reason string) Result { res.Status, res.Reason = status, reason; return res }

	r, ok := byID[c.Rule]
	if !ok {
		return fail(StatusFailed, "unknown rule "+c.Rule)
	}
	if err := e.permit(r, c); err != nil {
		return fail(StatusSkipped, "no longer permitted: "+err.Error())
	}
	if c.Action == rules.ActionDelete {
		if _, err := os.Lstat(c.Path); errors.Is(err, fs.ErrNotExist) {
			return fail(StatusSkipped, "already gone")
		}
	}
	if err := r.Recheck(ctx, e.Deps, c); err != nil {
		return fail(StatusSkipped, err.Error())
	}
	if dryRun {
		return fail(StatusDryRun, "")
	}

	switch c.Action {
	case rules.ActionDelete:
		if err := e.remove(c.Path); err != nil {
			return fail(StatusFailed, err.Error())
		}
		if _, err := os.Lstat(c.Path); err == nil {
			return fail(StatusFailed, "still exists after deletion")
		}
		res.FreedBytes = c.Bytes
	case rules.ActionCommand:
		ex := r.(rules.Executor) // guaranteed by permit
		freed, err := ex.Execute(ctx, e.Deps, c)
		if err != nil {
			return fail(StatusFailed, err.Error())
		}
		if freed < 0 { // the rule cannot tell: use the planned size. 0 is an answer and is believed.
			freed = c.Bytes
		}
		res.FreedBytes = freed
	}
	res.Status = StatusDeleted
	return res
}
