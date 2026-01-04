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
	expected := "run called"
	if out != expected {
		t.Errorf("expected %q, got %q", expected, out)
	}
}
