package cmd

import (
	"testing"
)

func TestRunFlags(t *testing.T) {
	cmd := NewRunCmd()
	
	dryRun, err := cmd.Flags().GetBool("dry-run")
	if err != nil {
		t.Fatalf("dry-run flag not found: %v", err)
	}
	if dryRun {
		t.Errorf("expected dry-run to be false by default")
	}

	force, err := cmd.Flags().GetBool("force")
	if err != nil {
		t.Fatalf("force flag not found: %v", err)
	}
	if force {
		t.Errorf("expected force to be false by default")
	}
}
