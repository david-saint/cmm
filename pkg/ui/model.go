package ui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
)

type Model struct {
	choices  []cmm.Module
	cursor   int
	selected map[int]struct{}
}

func NewModel(modules []cmm.Module) Model {
	return Model{
		choices:  modules,
		selected: make(map[int]struct{}),
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			if m.cursor < len(m.choices)-1 {
				m.cursor++
			}

		case "enter", " ":
			_, ok := m.selected[m.cursor]
			if ok {
				delete(m.selected, m.cursor)
			} else {
				m.selected[m.cursor] = struct{}{}
			}
		}
	}

	return m, nil
}

func (m Model) View() string {
	var b strings.Builder

	b.WriteString(titleStyle.Render(" cmm - Clean My Mac CLI "))
	b.WriteString("\n\n")
	b.WriteString(headerStyle.Render("Which modules do you want to run?"))
	b.WriteString("\n\n")

	for i, choice := range m.choices {
		cursor := "  "
		if m.cursor == i {
			cursor = cursorStyle.Render("> ")
		}

		checked := "[ ]"
		if _, ok := m.selected[i]; ok {
			checked = selectedStyle.Render("[x]")
		}

		name := choice.Name()
		if choice.Category() == "Harsh" {
			name += harshStyle.Render(" (Harsh)")
		}

		b.WriteString(fmt.Sprintf("%s %s %s\n", cursor, checked, name))
	}

	b.WriteString(helpStyle.Render("\n↑/↓: move • space: select • q: quit"))

	return b.String()
}
