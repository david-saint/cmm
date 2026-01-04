package ui

import (
	"fmt"
	"strings"

	lipgloss "github.com/charmbracelet/lipgloss"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
)

type state int

const (
	stateSelecting state = iota
	stateScanning
	stateResults
)

type Config struct {
	DryRun bool
	Force  bool
}

type Model struct {
	scanner  *cmm.Scanner
	choices  []cmm.Module
	cursor   int
	selected map[int]struct{}
	state    state
	results  []cmm.ModuleResult
	err      error
	config   Config
}

func NewModel(scanner *cmm.Scanner, modules []cmm.Module, config Config) Model {
	return Model{
		scanner:  scanner,
		choices:  modules,
		selected: make(map[int]struct{}),
		state:    stateSelecting,
		config:   config,
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

type scanMsg []cmm.ModuleResult
type errMsg error

func (m Model) runScan() tea.Msg {
	// Register only selected modules
	s := cmm.NewScanner()
	for i := range m.selected {
		s.Register(m.choices[i])
	}

	results, err := s.Scan()
	if err != nil {
		return errMsg(err)
	}
	return scanMsg(results)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "up", "k":
			if m.state == stateSelecting && m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			if m.state == stateSelecting && m.cursor < len(m.choices)-1 {
				m.cursor++
			}

		case "enter":
			if m.state == stateSelecting && len(m.selected) > 0 {
				m.state = stateScanning
				return m, m.runScan
			}
			if m.state == stateResults {
				return m, tea.Quit
			}

		case " ":
			if m.state == stateSelecting {
				_, ok := m.selected[m.cursor]
				if ok {
					delete(m.selected, m.cursor)
				} else {
					m.selected[m.cursor] = struct{}{}
				}
			}
		}

	case scanMsg:
		m.results = msg
		m.state = stateResults
		return m, nil

	case errMsg:
		m.err = msg
		m.state = stateResults
		return m, nil
	}

	return m, nil
}

func (m Model) View() string {
	var b strings.Builder

	b.WriteString(titleStyle.Render(" cmm - Clean My Mac CLI "))
	b.WriteString("\n")
	if m.config.DryRun {
		b.WriteString(lipgloss.NewStyle().Foreground(warningColor).Render(" (DRY RUN MODE - No files will be deleted) "))
	}
	b.WriteString("\n\n")

	switch m.state {
	case stateSelecting:
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

		if len(m.selected) > 0 {
			b.WriteString(helpStyle.Render("\n↑/↓: move • space: select • enter: scan • q: quit"))
		} else {
			b.WriteString(helpStyle.Render("\n↑/↓: move • space: select • q: quit"))
		}

	case stateScanning:
		b.WriteString(headerStyle.Render("Scanning..."))
		b.WriteString("\n\n")
		b.WriteString("Please wait while we look for removable files.")

	case stateResults:
		if m.err != nil {
			b.WriteString(lipgloss.NewStyle().Foreground(errorColor).Render(fmt.Sprintf("Error: %v", m.err)))
		} else {
			b.WriteString(headerStyle.Render("Scan Results"))
			b.WriteString("\n\n")

			var totalBytes int64
			for _, res := range m.results {
				var moduleBytes int64
				for _, item := range res.Items {
					moduleBytes += item.Size
				}
				totalBytes += moduleBytes
				b.WriteString(fmt.Sprintf("%s: %d items found (%s)\n", res.Module.Name(), len(res.Items), formatSize(moduleBytes)))
			}

			b.WriteString("\n")
			b.WriteString(titleStyle.Render(fmt.Sprintf(" Total Space Reclaimable: %s ", formatSize(totalBytes))))
		}
		b.WriteString(helpStyle.Render("\n\nenter/q: quit"))
	}

	return b.String()
}

func formatSize(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
