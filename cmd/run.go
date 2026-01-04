/*
Copyright © 2026 NAME HERE <EMAIL ADDRESS>

*/
package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// NewRunCmd represents the run command
func NewRunCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Start the interactive cleanup flow",
		Long:  `Starts the interactive terminal UI to selectively clean up disk space.`,
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprint(cmd.OutOrStdout(), "run called")
		},
	}
}

func init() {
}
