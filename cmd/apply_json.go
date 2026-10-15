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
	}
	doneEvent struct {
		Event      string   `json:"event"`
		Deleted    int      `json:"deleted"`
		Skipped    int      `json:"skipped"`
		Failed     int      `json:"failed"`
		FreedBytes int64    `json:"freed_bytes"`
		FreeBefore int64    `json:"free_before"`
		FreeAfter  int64    `json:"free_after"`
		Stopped    bool     `json:"stopped"`
		Warnings   []string `json:"warnings"`
		Log        string   `json:"log,omitempty"`
	}
)

type applyJSONOptions struct {
	only         []string
	selection    []string
	hasSelection bool
	dryRun       bool
}

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

	emit(startEvent{Event: "start", SchemaVersion: engine.SchemaVersion, Selected: selected, Matched: len(plan.Items),
		Bytes: plan.TotalBytes, FreeBytes: plan.Host.FreeBytes})
	for _, m := range missing {
		emit(itemEvent{Event: "item", Path: m, Status: string(engine.StatusSkipped), Reason: reasonNotInPlan})
	}

	rep, stopped := eng.Apply(ctx, plan, engine.ApplyOptions{
		DryRun: o.dryRun,
		Only:   o.only,
		OnResult: func(r engine.Result) {
			emit(itemEvent{Event: "item", Rule: r.Item.Rule, Group: r.Item.Group, Path: r.Item.Path, Status: string(r.Status),
				Reason: r.Reason, Bytes: r.Item.Bytes, FreedBytes: r.FreedBytes})
		},
	})

	done := doneEvent{Event: "done", Deleted: rep.Deleted, Skipped: rep.Skipped + len(missing), Failed: rep.Failed,
		FreedBytes: rep.FreedBytes, FreeBefore: rep.FreeBefore, FreeAfter: rep.FreeAfter, Stopped: stopped != nil,
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
