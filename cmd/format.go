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
	writePlanWithHeld(w, plan, nil, home, verbose)
}

// writePlanWithHeld is writePlan plus a block for the items that were held back because they need a person's
// choice (review tier): they are listed, with how to choose them, but are not part of the plan or its total.
func writePlanWithHeld(w io.Writer, plan *engine.Plan, held []rules.Candidate, home string, verbose bool) {
	fmt.Fprintln(w, "=== PLAN ===")
	if len(plan.Items) == 0 {
		fmt.Fprintln(w, "  nothing to clean right now.")
		writeHeld(w, held, home, verbose)
		writeSkipped(w, plan)
		return
	}

	writeGroupLines(w, plan.Groups, plan.Items, home, verbose)
	fmt.Fprintf(w, "  %9s  TOTAL\n", formatBytes(plan.TotalBytes))
	writeHeld(w, held, home, verbose)
	writeSkipped(w, plan)
	if plan.Host.FreeBytes > 0 {
		fmt.Fprintf(w, "\nFree space now: %s\n", formatBytes(plan.Host.FreeBytes))
	}
}

// writeGroupLines prints one line per group and, below it, its biggest items (all of them when verbose).
func writeGroupLines(w io.Writer, groups []engine.Group, all []rules.Candidate, home string, verbose bool) {
	for _, g := range groups {
		extra := ""
		if g.Count > 1 {
			extra = fmt.Sprintf(" [%d items]", g.Count)
		}
		fmt.Fprintf(w, "  %9s  %s%s\n", formatBytes(g.Bytes), g.Group, extra)

		var items []rules.Candidate
		for _, c := range all {
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
}

// writeHeld lists what needs a person's choice and how to make it. Nothing is printed when nothing is held.
func writeHeld(w io.Writer, held []rules.Candidate, home string, verbose bool) {
	if len(held) == 0 {
		return
	}
	var groups []engine.Group
	var ruleIDs []string
	seenRule := map[string]bool{}
	index := map[string]int{}
	for _, c := range held {
		if !seenRule[c.Rule] {
			seenRule[c.Rule] = true
			ruleIDs = append(ruleIDs, c.Rule)
		}
		i, ok := index[c.Group]
		if !ok {
			i = len(groups)
			index[c.Group] = i
			groups = append(groups, engine.Group{Group: c.Group})
		}
		groups[i].Bytes += c.Bytes
		groups[i].Count++
	}
	fmt.Fprintln(w, "\n=== NEEDS YOUR CHOICE (review first; a plain apply leaves these alone) ===")
	writeGroupLines(w, groups, held, home, verbose)
	fmt.Fprintf(w, "  Choose them on purpose: cmm apply --include-review, cmm apply --only %s, or tick them in cmm run or the app.\n", strings.Join(ruleIDs, ","))
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
