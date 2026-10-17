package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/spf13/cobra"
)

// reasonNotInPlan is why a selected path was left alone: a selection can only narrow the fresh plan.
const reasonNotInPlan = "not in the current plan"

// maxSelectionBytes bounds the selection file; a plan lists a few hundred paths at most.
const maxSelectionBytes = 16 << 20

// readSelection reads a selection file: a JSON array of strings (the paths of items from `cmm plan --json`).
// Anything else is an error, and nothing has been planned or deleted yet.
func readSelection(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the selection file: %w", err)
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxSelectionBytes+1))
	if err != nil {
		return nil, fmt.Errorf("cannot read the selection file: %w", err)
	}
	if len(b) > maxSelectionBytes {
		return nil, fmt.Errorf("the selection file is larger than %d MB", maxSelectionBytes>>20)
	}
	if bytes.Equal(bytes.TrimSpace(b), []byte("null")) {
		return nil, fmt.Errorf("the selection file must be a JSON array of paths (strings), not null")
	}
	var paths []string
	if err := json.Unmarshal(b, &paths); err != nil {
		return nil, fmt.Errorf("the selection file must be a JSON array of paths (strings): %w", err)
	}
	return paths, nil
}

// The events of `cmm apply --json`: one JSON object per line on stdout, nothing else.
type (
	startEvent struct {
		Event         string `json:"event"`
		SchemaVersion int    `json:"schema_version"`
		Selected      int    `json:"selected"`
		Matched       int    `json:"matched"`
		Bytes         int64  `json:"bytes"`
		FreeBytes     int64  `json:"free_bytes"`
	}
	itemEvent struct {
		Event      string `json:"event"`
		Rule       string `json:"rule"`
		Group      string `json:"group"`
		Path       string `json:"path"`
		Status     string `json:"status"`
		Reason     string `json:"reason"`
		Bytes      int64  `json:"bytes"`
		FreedBytes int64  `json:"freed_bytes"`
		// FreesInside is where the space went when it was not the volume ("Docker's disk image"): the item's
		// freed_bytes is then not part of done's freed_bytes. Left out when the volume got the space.
		FreesInside string `json:"frees_inside,omitempty"`
	}
	doneEvent struct {
		Event   string `json:"event"`
		Deleted int    `json:"deleted"`
		Skipped int    `json:"skipped"`
		Failed  int    `json:"failed"`
		// FreedBytes is what the volume got back; FreedInsideBytes what was freed inside another program's own
		// storage (Docker's disk image), which the volume's free space shows later or not at all.
		FreedBytes       int64    `json:"freed_bytes"`
		FreedInsideBytes int64    `json:"freed_inside_bytes"`
		FreeBefore       int64    `json:"free_before"`
		FreeAfter        int64    `json:"free_after"`
		Stopped          bool     `json:"stopped"`
		Warnings         []string `json:"warnings"`
		Log              string   `json:"log,omitempty"`
	}
)

type applyJSONOptions struct {
	only          []string
	selection     []string
	hasSelection  bool
	includeReview bool
	dryRun        bool
}

// reasonNeedsChoice is why an item of tier review was not attempted: nobody chose it.
const reasonNeedsChoice = "needs your choice (review): choose it with --select-file, --only or --include-review"

// runApplyJSON is `cmm apply --json`: plan again, narrow the fresh plan to the selection (when there is one),
// apply, and report every step as an event. The caller has already checked that --yes or --dry-run was given.
func runApplyJSON(ctx context.Context, cmd *cobra.Command, eng *engine.Engine, o applyJSONOptions) error {
	// A reader that goes away (the app quitting) must not kill a cleaning half way, leaving items undone and no
	// record of the run. With SIGPIPE ignored a failed write is an error that is noted and returned at the end;
	// stopping a run is what SIGINT is for.
	signal.Ignore(syscall.SIGPIPE)

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetEscapeHTML(false) // paths and reasons are data, not HTML
	var writeErr error
	emit := func(v any) {
		if err := enc.Encode(v); err != nil && writeErr == nil {
			writeErr = err
		}
	}

	plan, err := eng.Plan(ctx)
	if err != nil {
		return err
	}
	plan = plan.Only(o.only...)
	selected := len(plan.Items)
	var missing []string
	if o.hasSelection {
		selected = len(unique(o.selection))
		plan, missing = plan.OnlyPaths(o.selection)
	}

	// Items that need a person's choice are attempted only when chosen: by a selection, by naming their rule, or
	// with --include-review. Otherwise they are reported as skipped.
	var held []rules.Candidate
	if !o.hasSelection && len(o.only) == 0 && !o.includeReview {
		plan, held = plan.SafeOnly()
	}

	emit(startEvent{Event: "start", SchemaVersion: engine.SchemaVersion, Selected: selected, Matched: len(plan.Items),
		Bytes: plan.TotalBytes, FreeBytes: plan.Host.FreeBytes})
	for _, m := range missing {
		emit(itemEvent{Event: "item", Path: m, Status: string(engine.StatusSkipped), Reason: reasonNotInPlan})
	}
	for _, c := range held {
		emit(itemEvent{Event: "item", Rule: c.Rule, Group: c.Group, Path: c.Path, Status: string(engine.StatusSkipped), Reason: reasonNeedsChoice, Bytes: c.Bytes})
	}

	rep, stopped := eng.Apply(ctx, plan, engine.ApplyOptions{
		DryRun: o.dryRun,
		Only:   o.only,
		OnResult: func(r engine.Result) {
			emit(itemEvent{Event: "item", Rule: r.Item.Rule, Group: r.Item.Group, Path: r.Item.Path, Status: string(r.Status),
				Reason: r.Reason, Bytes: r.Item.Bytes, FreedBytes: r.FreedBytes, FreesInside: r.Item.FreesInside})
		},
	})

	done := doneEvent{Event: "done", Deleted: rep.Deleted, Skipped: rep.Skipped + len(missing) + len(held), Failed: rep.Failed,
		FreedBytes: rep.FreedBytes, FreedInsideBytes: rep.FreedInsideBytes, FreeBefore: rep.FreeBefore, FreeAfter: rep.FreeAfter, Stopped: stopped != nil,
		Warnings: append([]string{}, rep.Warnings...)}
	logWritten := rep.Deleted+rep.Failed > 0
	for _, w := range rep.Warnings {
		if strings.HasPrefix(w, "cleanup log:") {
			logWritten = false
		}
	}
	if lp, ok := eng.Journal.(interface{ LogPath() string }); ok && logWritten {
		done.Log = lp.LogPath()
	}
	emit(done)

	switch {
	case stopped != nil:
		return stopped
	case rep.Failed > 0:
		return errItemsFailed
	}
	return writeErr
}

// unique returns the distinct strings, in order.
func unique(ss []string) []string {
	seen := make(map[string]bool, len(ss))
	out := make([]string, 0, len(ss))
	for _, s := range ss {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
