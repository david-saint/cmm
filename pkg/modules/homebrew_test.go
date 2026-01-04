package modules

import (
	"testing"

	"github.com/david-saint/cmm/pkg/cmm"
)

func TestHomebrewModule_Metadata(t *testing.T) {
	m := &HomebrewModule{}
	if m.Name() != "Homebrew" {
		t.Errorf("unexpected name: %s", m.Name())
	}
	if m.Category() != "Recommended" {
		t.Errorf("unexpected category: %s", m.Category())
	}
	if m.Description() == "" {
		t.Errorf("description should not be empty")
	}
}

func TestNewHomebrewModule(t *testing.T) {
	m := NewHomebrewModule()
	// Since brew is installed on the agent system, it should be non-nil.
	if m == nil {
		t.Errorf("expected HomebrewModule to be initialized")
	}
}

func TestHomebrewModule_Scan(t *testing.T) {
	m := &HomebrewModule{}
	items, err := m.Scan()
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(items) != 1 {
		t.Errorf("expected 1 summary item, got %d", len(items))
	}
	if items[0].Type != "summary" {
		t.Errorf("expected summary item, got %s", items[0].Type)
	}
}

// We will need to mock the command execution for deeper tests.
// For now, let's just test that it implements the interface.
func TestHomebrewModule_Interface(t *testing.T) {
	var _ cmm.Module = &HomebrewModule{}
}
