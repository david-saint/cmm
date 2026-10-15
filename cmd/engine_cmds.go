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

	"github.com/david-saint/cmm/pkg/engine"
	"github.com/david-saint/cmm/pkg/guard"
	"github.com/david-saint/cmm/pkg/policy"
	"github.com/david-saint/cmm/pkg/rules"
	"github.com/david-saint/cmm/pkg/sys"
	"github.com/spf13/cobra"
)

var (
	// errNoTerminal is returned when apply would need a human but none is attached.
	errNoTerminal = errors.New("not running in a terminal: nothing deleted (use --yes deliberately for unattended runs)")
	// errCancelled is returned when the human at the prompt did not press plain Return.
	errCancelled = errors.New("cancelled: nothing deleted")
	// errItemsFailed is returned when apply finished but some items could not be deleted.
	errItemsFailed = errors.New("some items could not be deleted")
)

// deps is what the engine commands need from the outside world; tests replace it.
type deps struct {
	newEngine  func() (*engine.Engine, error)
	isTerminal func() bool // is stdin a terminal?
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
		isTerminal: func() bool { return guard.IsTerminal(os.Stdin) },
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
			writePlan(cmd.OutOrStdout(), plan, eng.Deps.Env.Home, verbose)
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
    longer hold are skipped, and one failure never stops the others.`,
		Args:         cobra.NoArgs,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			dryRun, _ := cmd.Flags().GetBool("dry-run")
			yes, _ := cmd.Flags().GetBool("yes")
			only, _ := cmd.Flags().GetStringSlice("only")

			eng, err := d.newEngine()
			if err != nil {
				return err
			}
			if err := validateOnly(eng, only); err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(contextOf(cmd), os.Interrupt)
			defer stop()

			out := cmd.OutOrStdout()
			printLastCleanup(cmd.ErrOrStderr(), eng)
			fmt.Fprintln(cmd.ErrOrStderr(), "Checking what can safely go (this can take a minute)...")
			plan, err := eng.Plan(ctx)
			if err != nil {
				return err
			}
			plan = plan.Only(only...)
			writePlan(out, plan, eng.Deps.Env.Home, false)

			if len(plan.Items) == 0 {
				fmt.Fprintln(out, "\nNothing to clean right now.")
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

// legacyRunWarning is printed by the old interactive mode, whose modules have no in-use checks or allow-list.
func legacyRunWarning() string {
	return "WARNING: `cmm run` is the legacy interactive mode. Its modules are unguarded: no in-use checks, no allow-list.\n" +
		"Prefer `cmm plan` to preview and `cmm apply` to clean (see conductor/tracks/engine_v2_20261014).\n\n"
}
