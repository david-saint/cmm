package engine

import (
	"context"
	"errors"
	"io/fs"
	"os"

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
}

// OK reports whether nothing failed. Skipped items are not failures.
func (r *Report) OK() bool { return r.Failed == 0 }

// Apply carries out a plan, one item at a time. Before each item it asks again whether the item is still
// permitted and still safe; an item that fails is reported and the run goes on. If the context ends, the
// report so far is returned together with the context's error.
func (e *Engine) Apply(ctx context.Context, plan *Plan, opts ApplyOptions) (*Report, error) {
	rep := &Report{DryRun: opts.DryRun, Results: []Result{}}
	_, rep.FreeBefore, _ = e.free()

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
		if opts.OnResult != nil {
			opts.OnResult(res)
		}
	}
	_, rep.FreeAfter, _ = e.free()
	return rep, stopped
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
		if freed <= 0 {
			freed = c.Bytes
		}
		res.FreedBytes = freed
	}
	res.Status = StatusDeleted
	return res
}
