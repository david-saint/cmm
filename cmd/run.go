/*
Copyright © 2026 NAME HERE <EMAIL ADDRESS>

*/
package cmd

import (
	"fmt"
	"os"
	"path/filepath"

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
			testMode, _ := cmd.Flags().GetBool("test-mode")

			var xcodePath, cachesPath string
			if testMode {
				cwd, _ := os.Getwd()
				testDir := filepath.Join(cwd, "cmm_test_data")
				fmt.Printf("⚠️  RUNNING IN TEST MODE ⚠️\nUsing test directory: %s\n", testDir)
				
				// Create dummy files
				xcodePath = filepath.Join(testDir, "DerivedData")
				cachesPath = filepath.Join(testDir, "Caches")
				_ = os.MkdirAll(xcodePath, 0755)
				_ = os.MkdirAll(cachesPath, 0755)
				
				_ = os.WriteFile(filepath.Join(xcodePath, "dummy_project"), []byte("dummy data"), 0644)
				_ = os.WriteFile(filepath.Join(cachesPath, "dummy_cache"), []byte("dummy cache data"), 0644)
			}

			scanner := cmm.NewScanner()
			
			// Register modules
			rawModules := []cmm.Module{
				modules.NewXcodeModule(xcodePath),
				modules.NewCachesModule(cachesPath),
				modules.NewLogsModule(),
				modules.NewTimeMachineModule(),
				modules.NewDockerModule(),
			}

			if hb := modules.NewHomebrewModule(); hb != nil {
				rawModules = append(rawModules, hb)
			}
			
			// Filter out modules that are not available on this system
			var availableModules []cmm.Module
			for _, m := range rawModules {
				if m.Available() {
					availableModules = append(availableModules, m)
				}
			}

			config := ui.Config{
				DryRun:   dryRun,
				Force:    force,
				TestMode: testMode,
			}

			model := ui.NewModel(scanner, availableModules, config)
			
			p := tea.NewProgram(model)
			if _, err := p.Run(); err != nil {
				fmt.Printf("Error running program: %v\n", err)
			}
		},
	}

	cmd.Flags().Bool("dry-run", false, "Preview changes without deleting")
	cmd.Flags().Bool("force", false, "Bypass confirmations")
	cmd.Flags().Bool("test-mode", false, "Use a local temporary directory for safe testing")

	return cmd
}

func init() {
}
