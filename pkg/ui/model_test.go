package ui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
)

type mockModule struct {
	name string
}

func (m mockModule) Name() string                         { return m.name }
func (m mockModule) Description() string                  { return "desc" }
func (m mockModule) Category() string                     { return "Recommended" }
func (m mockModule) Scan() ([]cmm.FileItem, error)        { return nil, nil }
func (m mockModule) Delete([]cmm.FileItem) (int64, error) { return 0, nil }

func TestInitialModel(t *testing.T) {
	modules := []cmm.Module{
		mockModule{name: "Module 1"},
		mockModule{name: "Module 2"},
	}
	m := NewModel(nil, modules, Config{})

	if len(m.choices) != 2 {
		t.Errorf("expected 2 choices, got %d", len(m.choices))
	}

	if m.cursor != 0 {
		t.Errorf("expected cursor at 0, got %d", m.cursor)
	}
}

func TestModel_Update(t *testing.T) {
	modules := []cmm.Module{
		mockModule{name: "Module 1"},
		mockModule{name: "Module 2"},
	}
	m := NewModel(nil, modules, Config{})

	// Test cursor movement
	msg := tea.KeyMsg{Type: tea.KeyDown}
	newModel, _ := m.Update(msg)
	m = newModel.(Model)

	if m.cursor != 1 {
		t.Errorf("expected cursor at 1 after KeyDown, got %d", m.cursor)
	}

	msg = tea.KeyMsg{Type: tea.KeyUp}
	newModel, _ = m.Update(msg)
	m = newModel.(Model)

	if m.cursor != 0 {
		t.Errorf("expected cursor at 0 after KeyUp, got %d", m.cursor)
	}

	// Test selection
	msg = tea.KeyMsg{Type: tea.KeySpace}
	newModel, _ = m.Update(msg)
	m = newModel.(Model)

	if _, ok := m.selected[0]; !ok {
		t.Errorf("expected item 0 to be selected after space")
	}

	newModel, _ = m.Update(msg)
	m = newModel.(Model)

	if _, ok := m.selected[0]; ok {
		t.Errorf("expected item 0 to be deselected after second space")
	}

}

func TestModel_EscNavigation(t *testing.T) {

	modules := []cmm.Module{
		mockModule{name: "Module 1"},
	}

	m := NewModel(nil, modules, Config{})

	// From stateResults to stateSelecting

	m.state = stateResults

	msg := tea.KeyMsg{Type: tea.KeyEsc}

	newModel, _ := m.Update(msg)

	m = newModel.(Model)

	if m.state != stateSelecting {
		t.Errorf("expected stateSelecting after Esc from stateResults, got %v", m.state)
	}

	// From stateConfirming to stateResults

	m.state = stateConfirming

	newModel, _ = m.Update(msg)

	m = newModel.(Model)

	if m.state != stateResults {
		t.Errorf("expected stateResults after Esc from stateConfirming, got %v", m.state)
	}

	// From stateScanning to stateSelecting

	m.state = stateScanning

	newModel, _ = m.Update(msg)

	m = newModel.(Model)

	if m.state != stateSelecting {
		t.Errorf("expected stateSelecting after Esc from stateScanning, got %v", m.state)
	}

}

func TestModel_ToggleExpanded(t *testing.T) {

	modules := []cmm.Module{
		mockModule{name: "Module 1"},
	}

	m := NewModel(nil, modules, Config{})

	m.state = stateResults

	m.results = []cmm.ModuleResult{
		{Module: modules[0], Items: []cmm.FileItem{{Path: "p1", Size: 10}}},
	}

	// Toggle on space

	msg := tea.KeyMsg{Type: tea.KeySpace}

	newModel, _ := m.Update(msg)

	m = newModel.(Model)

	if !m.expanded[0] {
		t.Errorf("expected module 0 to be expanded after space")
	}

		// Toggle off space

		newModel, _ = m.Update(msg)

		m = newModel.(Model)

		if m.expanded[0] {

			t.Errorf("expected module 0 to be collapsed after second space")

		}

	}

	
