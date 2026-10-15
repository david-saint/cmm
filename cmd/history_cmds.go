package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/spf13/cobra"
)

// sampleDoc is what `cmm sample --json` prints.
type sampleDoc struct {
	Recorded      bool      `json:"recorded"`
	T             time.Time `json:"t"`
	FreeBytes     int64     `json:"free_bytes"`
	CapacityBytes int64     `json:"capacity_bytes,omitempty"`
}

// NewSampleCmd builds `cmm sample`: note how much room the disk has, if a note is due. It reads the free space
// of the volume and nothing else (no scan), so a menu bar item or a login item can call it often.
func NewSampleCmd(d *deps) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "sample",
		Short: "Note the free space for the history (no scan, deletes nothing)",
		Long: `Reads how much free space the disk has and adds it to the free-space history in
~/.local/state/cmm, unless the last note is less than 30 minutes old and the free space has
moved by less than 256 MiB since. It takes well under a second and changes nothing else.

With --json it prints {"recorded": true|false, "t", "free_bytes", "capacity_bytes"}.`,
		Args:         cobra.NoArgs,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			asJSON, _ := cmd.Flags().GetBool("json")
			eng, err := d.newEngine()
			if err != nil {
				return err
			}
			host, err := eng.Host()
			if err != nil {
				return fmt.Errorf("cannot read the free space: %w", err)
			}
			h := engine.NewFileHistory(eng.Deps.Env.Home, eng.Deps.Env.Clock)
			recorded, err := h.Sample(host.FreeBytes, host.CapacityBytes)
			if err != nil {
				return fmt.Errorf("cannot record the free space: %w", err)
			}
			if asJSON {
				return writeJSONLine(cmd.OutOrStdout(), sampleDoc{
					Recorded: recorded, T: eng.Deps.Env.Clock().UTC().Truncate(time.Second),
					FreeBytes: host.FreeBytes, CapacityBytes: host.CapacityBytes,
				})
			}
			if recorded {
				fmt.Fprintf(cmd.OutOrStdout(), "Recorded: %s free.\n", formatBytes(host.FreeBytes))
			} else {
				fmt.Fprintf(cmd.OutOrStdout(), "Not due: a note was taken a short while ago and the free space (%s) has not moved much.\n", formatBytes(host.FreeBytes))
			}
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "print the result as JSON on stdout")
	return cmd
}

func writeJSONLine(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

// NewHistoryCmd builds `cmm history`: what past cleanups freed, and how free space has moved. It only reads.
func NewHistoryCmd(d *deps) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "history",
		Short: "Show past cleanups and how free space has moved (reads only)",
		Long: `Shows the cleanups cmm has done (newest first) and how the free space of the disk has
moved, from the files cmm keeps in ~/.local/state/cmm. Nothing is scanned and nothing is changed.

With --json the same is printed as one JSON document on stdout (schema_version 1): "runs"
(newest first, with the items that were deleted or failed) and "samples", the free-space
timeline (oldest first), made of the notes taken by "cmm sample" and the two ends of every
cleanup. --limit caps the runs, --days the timeline (0 means everything).`,
		Args:         cobra.NoArgs,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			asJSON, _ := cmd.Flags().GetBool("json")
			limit, _ := cmd.Flags().GetInt("limit")
			days, _ := cmd.Flags().GetInt("days")
			if limit < 0 || days < 0 {
				return fmt.Errorf("--limit and --days cannot be negative")
			}
			eng, err := d.newEngine()
			if err != nil {
				return err
			}
			host, _ := eng.Host() // an unreadable free space shows as an empty host, as in a plan
			h := engine.NewFileHistory(eng.Deps.Env.Home, eng.Deps.Env.Clock)
			rep, err := h.Report(host, limit, days)
			if err != nil {
				return fmt.Errorf("cannot read the history: %w", err)
			}
			if asJSON {
				b, err := rep.JSON()
				if err != nil {
					return err
				}
				_, err = cmd.OutOrStdout().Write(b)
				return err
			}
			writeHistory(cmd.OutOrStdout(), rep, days, eng.Deps.Env.Clock().Location())
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "print the history as JSON (schema_version 1) on stdout")
	cmd.Flags().Int("limit", 20, "how many cleanups to show (0 means all)")
	cmd.Flags().Int("days", 90, "how many days of free-space history to use (0 means all)")
	return cmd
}

// writeHistory prints the report for people: the disk now, the cleanups, the free space over the period.
func writeHistory(w io.Writer, rep *engine.HistoryReport, days int, loc *time.Location) {
	if rep.Host.FreeBytes > 0 {
		if rep.Host.CapacityBytes > 0 {
			fmt.Fprintf(w, "Free now: %s of %s.\n", formatBytes(rep.Host.FreeBytes), formatBytes(rep.Host.CapacityBytes))
		} else {
			fmt.Fprintf(w, "Free now: %s.\n", formatBytes(rep.Host.FreeBytes))
		}
	}
	if rep.UnreadableLines > 0 {
		noun := "lines"
		if rep.UnreadableLines == 1 {
			noun = "line"
		}
		fmt.Fprintf(w, "(%d %s of the history could not be read and were left out.)\n", rep.UnreadableLines, noun)
	}

	fmt.Fprintln(w)
	if len(rep.Runs) == 0 {
		fmt.Fprintln(w, "No cleanups recorded yet.")
	} else {
		fmt.Fprintln(w, "Cleanups, newest first:")
		for _, r := range rep.Runs {
			stopped := ""
			if r.Stopped {
				stopped = ", stopped early"
			}
			fmt.Fprintf(w, "  %s  freed %-8s %d deleted, %d skipped, %d failed%s\n",
				r.FinishedAt.In(loc).Format("2006-01-02 15:04"), formatBytes(r.FreedBytes), r.Deleted, r.Skipped, r.Failed, stopped)
		}
	}

	fmt.Fprintln(w)
	period := "over all time"
	if days > 0 {
		period = fmt.Sprintf("last %d days", days)
	}
	if len(rep.Samples) == 0 {
		fmt.Fprintf(w, "No free-space samples yet (cmm sample notes one).\n")
		return
	}
	first, last := rep.Samples[0], rep.Samples[len(rep.Samples)-1]
	low := first
	for _, s := range rep.Samples {
		if s.FreeBytes < low.FreeBytes {
			low = s
		}
	}
	fmt.Fprintf(w, "Free space, %s (%d points): from %s on %s to %s on %s; lowest %s on %s.\n", period, len(rep.Samples),
		formatBytes(first.FreeBytes), first.T.In(loc).Format("2006-01-02"),
		formatBytes(last.FreeBytes), last.T.In(loc).Format("2006-01-02"),
		formatBytes(low.FreeBytes), low.T.In(loc).Format("2006-01-02"))
}
