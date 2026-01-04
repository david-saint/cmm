/*
Copyright © 2026 NAME HERE <EMAIL ADDRESS>

*/
package cmd

import (
	"fmt"

	"github.com/david-saint/cmm/pkg/cmm"
	"github.com/david-saint/cmm/pkg/modules"
	"github.com/spf13/cobra"
)

// NewRunCmd represents the run command
func NewRunCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the interactive cleanup flow",
		Long:  `Starts the interactive terminal UI to selectively clean up disk space.`,
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintln(cmd.OutOrStdout(), "Scanning for removable files...")
			
			scanner := cmm.NewScanner()
			scanner.Register(modules.NewXcodeModule())
			scanner.Register(modules.NewCachesModule())
			scanner.Register(modules.NewTimeMachineModule())

			results, err := scanner.Scan()
			if err != nil {
				fmt.Fprintf(cmd.OutOrStderr(), "Error during scan: %v\n", err)
				return
			}

			for _, res := range results {
				fmt.Fprintf(cmd.OutOrStdout(), "\nModule: %s (%s)\n", res.Module.Name(), res.Module.Category())
				if len(res.Items) == 0 {
					fmt.Fprintln(cmd.OutOrStdout(), "  No items found.")
					continue
				}
				for _, item := range res.Items {
					fmt.Fprintf(cmd.OutOrStdout(), "  - %s (%d bytes)\n", item.Path, item.Size)
				}
			}
		},
	}
}

func init() {
}
