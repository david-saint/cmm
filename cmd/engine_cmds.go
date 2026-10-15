package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"

	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/modules"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/david-saint/cmm/pkg/ui"
	"github.com/spf13/cobra"
)

var (
	// errNoTerminal is returned when apply would need a human but none is attached.
	errNoTerminal = errors.New("not running in a terminal: nothing deleted (use --yes deliberately for unattended runs)")
	// errCancelled is returned when the human at the prompt did not press plain Return.
	errCancelled = errors.New("cancelled: nothing deleted")
	// errItemsFailed is returned when apply finished but some items could not be deleted.
	errItemsFailed = errors.New("some items could not be deleted")
	// errJSONNeedsYes is returned when --json would have to ask a question it cannot ask.
	errJSONNeedsYes = errors.New("--json needs --yes (the caller has a person's confirmation for exactly this selection) or --dry-run: nothing was planned or deleted")
)

// deps is what the engine commands need from the outside world; tests replace it.
type deps struct {
	newEngine   func() (*engine.Engine, error)
	isTerminal  func() bool                          // is stdin a terminal?
	timeMachine func() cmm.Module                    // the one legacy module cmm run still offers
	runUI       func(*cobra.Command, ui.Model) error // shows the interactive screen
}

func defaultDeps() *deps {
	return &deps{
		newEngine: func() (*engine.Engine, error) {
			env, err := sys.DefaultEnv()
			if err != nil {
				return nil, err
			}
			return newProductionEngine(env), nil
		},
		isTerminal:  func() bool { return guard.IsTerminal(os.Stdin) },
		timeMachine: func() cmm.Module { return modules.NewTimeMachineModule() },
		runUI:       runBubbleTea,
	}
}

// newProductionEngine is the engine for real use: every built-in rule, the real guards and policy, and a
// journal in the user's state folder so every real apply leaves a log and a last-run stamp. This is the one
// place the journal is attached; tests build engines without one unless they are testing the journal.
func newProductionEngine(env *sys.Env) *engine.Engine {
	eng := engine.New(rules.Deps{Env: env, Guard: guard.New(env), Policy: policy.New(env)}, rules.Builtin())
	eng.Journal = engine.NewFileJournal(env.Home, env.Clock)
	return eng
}

// printLastCleanup tells when something was last cleaned, if the stamp says so. It only reads.
func printLastCleanup(w io.Writer, eng *engine.Engine) {
	last, ok := engine.LastRun(eng.Deps.Env.Home)
	if !ok {
		return
	}
	if line := lastCleanupLine(last, eng.Deps.Env.Clock()); line != "" {
		fmt.Fprintln(w, line)
	}
}

func contextOf(cmd *cobra.Command) context.Context {
	if ctx := cmd.Context(); ctx != nil {
		return ctx
	}
	return context.Background()
}

// NewPlanCmd builds `cmm plan`: look, never touch.
func NewPlanCmd(d *deps) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "plan",
		Short: "Show what cmm would clean (deletes nothing)",
		Long: `Checks every built-in rule and prints what could be removed, how much space it
would free, and which guards made a rule skip something. Nothing is ever deleted.

With --json the plan is printed as one JSON document on stdout (schema_version 1),
for other tools to read.`,
		Args:         cobra.NoArgs,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			asJSON, _ := cmd.Flags().GetBool("json")
			verbose, _ := cmd.Flags().GetBool("verbose")

			eng, err := d.newEngine()
			if err != nil {
				return err
			}
			if !asJSON {
				printLastCleanup(cmd.ErrOrStderr(), eng)
				fmt.Fprintln(cmd.ErrOrStderr(), "Checking what can safely go (this can take a minute)...")
			}
			plan, err := eng.Plan(contextOf(cmd))
			if err != nil {
				return err
			}
			if asJSON {
				b, err := plan.JSON()
				if err != nil {
					return err
				}
				_, err = cmd.OutOrStdout().Write(b)
				return err
			}
			shown, held := plan.SafeOnly()
			writePlanWithHeld(cmd.OutOrStdout(), shown, held, eng.Deps.Env.Home, verbose)
			return nil
		},
	}
	cmd.Flags().Bool("json", false, "print the plan as JSON (schema_version 1) on stdout")
	cmd.Flags().BoolP("verbose", "v", false, "list every item, not just the biggest per group")
	return cmd
}

// NewApplyCmd builds `cmm apply`: show the plan, ask a human, then delete.
func NewApplyCmd(d *deps) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "apply",
		Short: "Show the plan, ask for Return, then clean",
		Long: `Builds the same plan as "cmm plan", shows it, and waits for you to press Return
before deleting anything.

  - Without a terminal (a pipe, a script, an agent) it refuses and deletes nothing,
    unless you pass --yes on purpose.
  - Anything other than a plain Return at the prompt cancels.
  - --dry-run shows the plan and stops; it never deletes, even together with --yes.
  - Each item is checked again right before it is removed; items whose guards no
    longer hold are skipped, and one failure never stops the others.
  - Items of tier review (Docker's prunes, for one) are never part of a plain apply, not even with
    --yes: the plan lists them under "needs your choice". Choose them on purpose with --include-review,
    --only <rule> or --select-file (or tick them in "cmm run" or the app).
  - --select-file limits the run to the item paths listed in a JSON file (an array
    of strings taken from "cmm plan --json"). The plan is made again first and a
    selection can only narrow it: a path that is not in it is skipped, never deleted.
  - --json prints one JSON event per line (start, item, done) instead of text, for
    other programs. It needs --yes (the caller has a person's confirmation) or
    --dry-run, because it cannot ask.`,
		Args:         cobra.NoArgs,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			dryRun, _ := cmd.Flags().GetBool("dry-run")
			yes, _ := cmd.Flags().GetBool("yes")
			only, _ := cmd.Flags().GetStringSlice("only")
			asJSON, _ := cmd.Flags().GetBool("json")
			selectFile, _ := cmd.Flags().GetString("select-file")
			includeReview, _ := cmd.Flags().GetBool("include-review")

			if asJSON && !yes && !dryRun {
				return errJSONNeedsYes
			}
			var selected []string
			if selectFile != "" {
				var err error
				if selected, err = readSelection(selectFile); err != nil {
					return err
				}
			}

			eng, err := d.newEngine()
			if err != nil {
				return err
			}
			if err := validateOnly(eng, only); err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(contextOf(cmd), os.Interrupt)
			defer stop()

			if asJSON {
				return runApplyJSON(ctx, cmd, eng, applyJSONOptions{only: only, selection: selected, hasSelection: selectFile != "", includeReview: includeReview, dryRun: dryRun})
			}

			out := cmd.OutOrStdout()
			printLastCleanup(cmd.ErrOrStderr(), eng)
			fmt.Fprintln(cmd.ErrOrStderr(), "Checking what can safely go (this can take a minute)...")
			plan, err := eng.Plan(ctx)
			if err != nil {
				return err
			}
			plan = plan.Only(only...)
			if selectFile != "" {
				var missing []string
				plan, missing = plan.OnlyPaths(selected)
				for _, m := range missing {
					fmt.Fprintf(cmd.ErrOrStderr(), "skipped: %s: %s\n", shortPath(m, eng.Deps.Env.Home), reasonNotInPlan)
				}
			}
			// Items that need a person's choice are taken only when the person chose them: by naming their rule,
			// by selecting them, or with --include-review. Otherwise they are listed and left alone.
			var held []rules.Candidate
			if selectFile == "" && len(only) == 0 && !includeReview {
				plan, held = plan.SafeOnly()
			}
			writePlanWithHeld(out, plan, held, eng.Deps.Env.Home, false)

			if len(plan.Items) == 0 {
				if len(held) > 0 {
					fmt.Fprintln(out, "\nNothing safe to clean right now: what is left needs your choice (see above).")
				} else {
					fmt.Fprintln(out, "\nNothing to clean right now.")
				}
				return nil
			}
			if dryRun {
				fmt.Fprintln(out, "\nDry run: nothing was deleted.")
				return nil
			}
			if !yes {
				if !d.isTerminal() {
					return errNoTerminal
				}
				fmt.Fprint(out, "\nPress Return to delete, Ctrl-C to cancel: ")
				line, err := bufio.NewReader(cmd.InOrStdin()).ReadString('\n')
				if err != nil || strings.TrimSpace(line) != "" {
					fmt.Fprintln(out)
					return errCancelled
				}
			}
			return runApply(ctx, cmd, eng, plan, only)
		},
	}
	cmd.Flags().Bool("dry-run", false, "show the plan and stop; never deletes")
	cmd.Flags().Bool("yes", false, "do not ask for Return (for deliberate unattended runs)")
	cmd.Flags().StringSlice("only", nil, "limit to these rule ids (comma separated)")
	cmd.Flags().String("select-file", "", "limit to the item paths in this JSON file (an array of strings from `cmm plan --json`); can only narrow the plan")
	cmd.Flags().Bool("json", false, "print one JSON event per line instead of text (needs --yes or --dry-run)")
	cmd.Flags().Bool("include-review", false, "also carry out items of tier review (Docker's prunes), which a plain apply leaves alone")
	return cmd
}

func validateOnly(eng *engine.Engine, only []string) error {
	if len(only) == 0 {
		return nil
	}
	known := make([]string, 0, len(eng.Rules))
	set := make(map[string]bool, len(eng.Rules))
	for _, r := range eng.Rules {
		known = append(known, r.ID())
		set[r.ID()] = true
	}
	for _, id := range only {
		if !set[id] {
			return fmt.Errorf("unknown rule id %q (known: %s)", id, strings.Join(known, ", "))
		}
	}
	return nil
}

func runApply(ctx context.Context, cmd *cobra.Command, eng *engine.Engine, plan *engine.Plan, only []string) error {
	out := cmd.OutOrStdout()
	home := eng.Deps.Env.Home
	fmt.Fprintln(out, "\n=== deleting ===")

	lastGroup := ""
	rep, stopped := eng.Apply(ctx, plan, engine.ApplyOptions{
		Only: only,
		OnResult: func(r engine.Result) {
			if r.Item.Group != lastGroup {
				fmt.Fprintf(out, "- %s\n", r.Item.Group)
				lastGroup = r.Item.Group
			}
			switch r.Status {
			case engine.StatusFailed:
				fmt.Fprintf(out, "    FAILED: %s: %s\n", shortPath(r.Item.Path, home), r.Reason)
			case engine.StatusSkipped:
				fmt.Fprintf(out, "    skipped: %s: %s\n", shortPath(r.Item.Path, home), r.Reason)
			}
		},
	})

	fmt.Fprintln(out, "\n=== done ===")
	fmt.Fprintf(out, "deleted %d, skipped %d, failed %d\n", rep.Deleted, rep.Skipped, rep.Failed)
	if rep.FreeBefore > 0 || rep.FreeAfter > 0 {
		fmt.Fprintf(out, "Free space: %s -> %s (+%s)\n", formatBytes(rep.FreeBefore), formatBytes(rep.FreeAfter), formatBytes(maxInt64(rep.FreeAfter-rep.FreeBefore, 0)))
	}
	logWritten := rep.Deleted+rep.Failed > 0
	for _, w := range rep.Warnings {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: %s\n", w)
		if strings.HasPrefix(w, "cleanup log:") {
			logWritten = false
		}
	}
	if lp, ok := eng.Journal.(interface{ LogPath() string }); ok && logWritten {
		fmt.Fprintf(out, "Log: %s\n", shortPath(lp.LogPath(), home))
	}
	if stopped != nil {
		fmt.Fprintln(out, "Stopped early:", stopped)
		return stopped
	}
	if rep.Failed > 0 {
		fmt.Fprintf(out, "%d item(s) failed, see the lines marked FAILED above.\n", rep.Failed)
		return errItemsFailed
	}
	return nil
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
