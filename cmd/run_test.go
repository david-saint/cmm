package cmd

import (
	"bytes"
	"testing"
)

func TestRunCommand(t *testing.T) {
	rootCmd := NewRootCmd()
	b := bytes.NewBufferString("")
	rootCmd.SetOut(b)
	rootCmd.SetArgs([]string{"run"})

	err := rootCmd.Execute()
	if err != nil {
		t.Fatalf("Execute() failed: %v", err)
	}

	out := b.String()
	if out == "" {
		t.Errorf("expected non-empty output")
	}
}
