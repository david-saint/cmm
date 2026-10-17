package cmd

import (
	"errors"
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"

	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/ui"
)

// errRunNeedsTerminal is returned when run --apply would need a human but none is attached.
var errRunNeedsTerminal = errors.New("cmm run --apply needs a terminal: nothing deleted (use cmm plan to look, or cmm apply --yes deliberately for unattended runs)")

// NewRunCmd builds `cmm run`: the interactive screen over the engine's plan.
func NewRunCmd(d *deps) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "run",
		Short: "Interactive cleanup (a preview unless --apply)",
		Long: `Opens the interactive screen on the same plan as "cmm plan": pick what to look at, see
the items and their sizes and, with --apply, confirm to clean.

  - Without --apply it is a preview: nothing is ever deleted.
  - With --apply a terminal is required, and nothing is deleted until you type y.
  - Every item is checked again right before it is removed, exactly as in "cmm apply".
  - Time Machine local snapshots (harsh, manual) are offered as well; they are not part of the plan.

--dry-run is accepted for old scripts: it means preview, and wins over --apply.`,
		Args:         cobra.NoArgs,
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			apply, _ := cmd.Flags().GetBool("apply")
			if dry, _ := cmd.Flags().GetBool("dry-run"); dry {
				apply = false // --dry-run never deletes, even together with --apply
			}
			if apply && !d.isTerminal() {
				return errRunNeedsTerminal
			}

			eng, err := d.newEngine()
			if err != nil {
				return err
			}
			ctx := contextOf(cmd)
			printLastCleanup(cmd.ErrOrStderr(), eng)
			fmt.Fprintln(cmd.ErrOrStderr(), "Checking what can safely go (this can take a minute)...")
			plan, err := eng.Plan(ctx)
			if err != nil {
				return err
			}

			mods := engineModules(ctx, eng, plan)
			if len(mods) == 0 {
				fmt.Fprintln(cmd.ErrOrStderr(), "Nothing to clean right now.")
			}
			mods = append(mods, d.timeMachine())
			return d.runUI(cmd, ui.NewModel(cmm.NewScanner(), mods, ui.Config{DryRun: !apply}))
		},
	}
	cmd.Flags().Bool("apply", false, "allow cleaning after a confirmation (default: preview only)")
	cmd.Flags().Bool("dry-run", false, "preview only (the default; wins over --apply)")
	return cmd
}

// runBubbleTea shows the interactive screen on the real terminal.
func runBubbleTea(_ *cobra.Command, m ui.Model) error {
	_, err := tea.NewProgram(m).Run()
	return err
}
