package modules

import (
	"testing"

	"github.com/david-saint/cmm/pkg/cmm"
)

type mockRunner struct {
	output string
	err    error
}

func (r *mockRunner) Run(name string, arg ...string) (string, error) {
	return r.output, r.err
}

func TestTimeMachineModule_Scan(t *testing.T) {
	mockOutput := "com.apple.TimeMachine.2026-01-01-120000.local\ncom.apple.TimeMachine.2026-01-02-120000.local"
	runner := &mockRunner{output: mockOutput}

	m := &TimeMachineModule{
		runner: runner,
	}

	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan() failed: %v", err)
	}

	if len(items) != 2 {
		t.Errorf("expected 2 items, got %d", len(items))
	}

	if items[0].Path != "com.apple.TimeMachine.2026-01-01-120000.local" {
		t.Errorf("expected path %q, got %q", "com.apple.TimeMachine.2026-01-01-120000.local", items[0].Path)
	}
}

func TestTimeMachineModule_Delete(t *testing.T) {
	runner := &mockRunner{output: ""}
	m := &TimeMachineModule{
		runner: runner,
	}

	items := []cmm.FileItem{
		{Path: "com.apple.TimeMachine.2026-01-01-120000.local", Size: 100},
	}

	freed, err := m.Delete(items)
	if err != nil {
		t.Fatalf("Delete() failed: %v", err)
	}

	if freed != 100 {
		t.Errorf("expected 100 freed, got %d", freed)
	}
}
