/*
Copyright © 2026 NAME HERE <EMAIL ADDRESS>

*/
package cmd

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/modules"
	"github.com/david-saint/cmm/pkg/ui"
	"github.com/spf13/cobra"
)

// NewRunCmd represents the run command
func NewRunCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "run",
		Short: "Start the interactive cleanup flow",
		Long:  `Starts the interactive terminal UI to selectively clean up disk space.`,
		Run: func(cmd *cobra.Command, args []string) {
			dryRun, _ := cmd.Flags().GetBool("dry-run")
			force, _ := cmd.Flags().GetBool("force")

			scanner := cmm.NewScanner()
			
			// Register modules
			availableModules := []cmm.Module{
				modules.NewXcodeModule(),
				modules.NewCachesModule(),
				modules.NewTimeMachineModule(),
			}

			config := ui.Config{
				DryRun: dryRun,
				Force:  force,
			}

			model := ui.NewModel(scanner, availableModules, config)
			
			p := tea.NewProgram(model)
			if _, err := p.Run(); err != nil {
				fmt.Printf("Error running program: %v\n", err)
			}
		},
	}

	cmd.Flags().Bool("dry-run", true, "Preview changes without deleting")
	cmd.Flags().Bool("force", false, "Bypass confirmations")

	return cmd
}

func init() {
}
