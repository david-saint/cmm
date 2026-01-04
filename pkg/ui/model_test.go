package ui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
)

type mockModule struct {
	name string
}

func (m mockModule) Name() string                     { return m.name }
func (m mockModule) Description() string              { return "desc" }
func (m mockModule) Category() string                 { return "Recommended" }
func (m mockModule) Scan() ([]cmm.FileItem, error)    { return nil, nil }
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