package cmd

import (
	"bytes"
	"testing"
)

func TestExecute(t *testing.T) {
	rootCmd := NewRootCmd()
	b := bytes.NewBufferString("")
	rootCmd.SetOut(b)
	rootCmd.SetArgs([]string{"--help"})

	err := rootCmd.Execute()
	if err != nil {
		t.Fatalf("Execute() failed: %v", err)
	}

	out := b.String()
	if out == "" {
		t.Errorf("Execute() did not output anything")
	}
}
