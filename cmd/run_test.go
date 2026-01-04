package cmd

import (
	"testing"
)

func TestRunCommand(t *testing.T) {
	runCmd := NewRunCmd()

	if runCmd.Use != "run" {
		t.Errorf("expected Use 'run', got %q", runCmd.Use)
	}

	if runCmd.Short == "" {
		t.Errorf("expected Short description to be set")
	}

	if runCmd.Long == "" {
		t.Errorf("expected Long description to be set")
	}
}
