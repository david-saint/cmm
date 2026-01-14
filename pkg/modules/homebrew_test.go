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
	// NewHomebrewModule returns nil if brew is not found.
	// This is expected behavior on systems without Homebrew (like CI linux runners).
	if m == nil {
		t.Skip("Homebrew not found, skipping TestNewHomebrewModule")
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
