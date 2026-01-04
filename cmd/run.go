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
	return &cobra.Command{
		Use:   "run",
		Short: "Start the interactive cleanup flow",
		Long:  `Starts the interactive terminal UI to selectively clean up disk space.`,
		Run: func(cmd *cobra.Command, args []string) {
			scanner := cmm.NewScanner()
			
			// Register modules
			availableModules := []cmm.Module{
				modules.NewXcodeModule(),
				modules.NewCachesModule(),
				modules.NewTimeMachineModule(),
			}

			p := tea.NewProgram(ui.NewModel(scanner, availableModules))
			if _, err := p.Run(); err != nil {
				fmt.Printf("Error running program: %v\n", err)
			}
		},
	}
}

func init() {
}
