package cmd

import (
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/rules"
)

// lastCleanupLine says when cmm last cleaned something, e.g. "Last cleanup: 2026-10-14 (3 days ago)". A stamp
// more than a day in the future cannot be right (a little clock skew is fine), so it is not shown.
func lastCleanupLine(last, now time.Time) string {
	if last.After(now.Add(24 * time.Hour)) {
		return ""
	}
	ago := "less than a day ago"
	switch days := int(now.Sub(last) / (24 * time.Hour)); {
	case days == 1:
		ago = "1 day ago"
	case days > 1:
		ago = fmt.Sprintf("%d days ago", days)
	}
	return fmt.Sprintf("Last cleanup: %s (%s)", last.In(now.Location()).Format("2006-01-02"), ago)
}

// formatBytes renders a size the way the dev-cleanup script did: GB with one decimal from 100 MB up,
// whole MB below that, KB for tiny things.
func formatBytes(b int64) string {
	const (
		kb = 1 << 10
		mb = 1 << 20
		gb = 1 << 30
	)
	switch {
	case b >= 100*mb:
		return fmt.Sprintf("%.1f GB", float64(b)/gb)
	case b >= mb:
		return fmt.Sprintf("%d MB", b/mb)
	default:
		return fmt.Sprintf("%d KB", b/kb)
	}
}

// shortPath shows a path under the home directory as ~/...
func shortPath(path, home string) string {
	if home != "" && strings.HasPrefix(path, home+"/") {
		return "~" + path[len(home):]
	}
	return path
}

// maxItemsPerGroup is how many items a group lists before "and N more" (unless -v).
const maxItemsPerGroup = 3

// writePlan prints a plan for people: one line per group, its biggest items below it, a total, and the
// guards that made rules skip things.
func writePlan(w io.Writer, plan *engine.Plan, home string, verbose bool) {
	if len(plan.Items) == 0 {
		fmt.Fprintln(w, "=== PLAN ===")
		fmt.Fprintln(w, "  nothing to clean right now.")
		writeSkipped(w, plan)
		return
	}

	fmt.Fprintln(w, "=== PLAN ===")
	for _, g := range plan.Groups {
		extra := ""
		if g.Count > 1 {
			extra = fmt.Sprintf(" [%d items]", g.Count)
		}
		fmt.Fprintf(w, "  %9s  %s%s\n", formatBytes(g.Bytes), g.Group, extra)

		var items []rules.Candidate
		for _, c := range plan.Items {
			if c.Group == g.Group {
				items = append(items, c)
			}
		}
		sort.SliceStable(items, func(i, j int) bool { return items[i].Bytes > items[j].Bytes })
		shown := items
		if !verbose && len(shown) > maxItemsPerGroup {
			shown = shown[:maxItemsPerGroup]
		}
		for _, c := range shown {
			line := fmt.Sprintf("%s, %s", shortPath(c.Path, home), formatBytes(c.Bytes))
			if c.Note != "" {
				line += " (" + c.Note + ")"
			}
			fmt.Fprintf(w, "             - %s\n", line)
		}
		if len(items) > len(shown) {
			fmt.Fprintf(w, "             - ... and %d more (use -v to list them)\n", len(items)-len(shown))
		}
	}
	fmt.Fprintf(w, "  %9s  TOTAL\n", formatBytes(plan.TotalBytes))
	writeSkipped(w, plan)
	if plan.Host.FreeBytes > 0 {
		fmt.Fprintf(w, "\nFree space now: %s\n", formatBytes(plan.Host.FreeBytes))
	}
}

func writeSkipped(w io.Writer, plan *engine.Plan) {
	if len(plan.Skipped) == 0 {
		return
	}
	fmt.Fprintln(w, "\n=== SKIPPED (guards said no) ===")
	for _, s := range plan.Skipped {
		fmt.Fprintf(w, "  - %s\n", s.Reason)
	}
}
