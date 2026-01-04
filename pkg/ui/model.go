package ui

import (
	"fmt"
	"strings"

	lipgloss "github.com/charmbracelet/lipgloss"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/david-saint/cmm/pkg/cmm"
)

type state int

type Config struct {
	DryRun bool
	Force  bool
}

const (
	stateSelecting state = iota
	stateScanning
	stateResults
	stateConfirming
	stateExecuting
	stateFinished
)

type Model struct {
	scanner  *cmm.Scanner
	choices  []cmm.Module
	cursor   int
	selected map[int]struct{}
	state    state
	results  []cmm.ModuleResult
	err      error
	config   Config
	freed    int64
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
type executeMsg int64
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

func (m Model) runExecute() tea.Msg {
	engine := cmm.NewExecutionEngine(m.config.DryRun)
	freed, err := engine.Execute(m.results)
	if err != nil {
		return errMsg(err)
	}
	return executeMsg(freed)
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
				if m.config.DryRun {
					return m, tea.Quit
				}
				m.state = stateConfirming
				return m, nil
			}
			if m.state == stateConfirming {
				m.state = stateExecuting
				return m, m.runExecute
			}
			if m.state == stateFinished || m.err != nil {
				return m, tea.Quit
			}

		case "y", "Y":
			if m.state == stateConfirming {
				m.state = stateExecuting
				return m, m.runExecute
			}

		case "n", "N":
			if m.state == stateConfirming {
				m.state = stateResults
				return m, nil
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

	case executeMsg:
		m.freed = int64(msg)
		m.state = stateFinished
		return m, nil

	case errMsg:
		m.err = msg
		// If we were executing, we might want to stay in a state that shows the partial results
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

	if m.err != nil {
		b.WriteString(lipgloss.NewStyle().Foreground(errorColor).Render(fmt.Sprintf("Error: %v", m.err)))
		b.WriteString(helpStyle.Render("\n\nenter/q: quit"))
		return b.String()
	}

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

		b.WriteString(helpStyle.Render("\n↑/↓: move • space: select • enter: scan • q: quit"))

	case stateScanning:
		b.WriteString(headerStyle.Render("Scanning..."))
		b.WriteString("\n\n")
		b.WriteString("Please wait while we look for removable files.")

	case stateResults:
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
		
		if m.config.DryRun {
			b.WriteString(helpStyle.Render("\n\nenter/q: quit"))
		} else {
			b.WriteString(helpStyle.Render("\n\nenter: proceed to cleanup • q: quit"))
		}

	case stateConfirming:
		hasHarsh := false
		for i := range m.selected {
			if m.choices[i].Category() == "Harsh" {
				hasHarsh = true
				break
			}
		}

		if hasHarsh {
			b.WriteString(lipgloss.NewStyle().
				Foreground(lipgloss.Color("#FFFDFE")).
				Background(errorColor).
				Padding(0, 1).
				Bold(true).
				Render("☢️  WARNING: HARSH CLEANUP DETECTED"))
			b.WriteString("\n\n")
			b.WriteString("Some of the selected modules are marked as 'Harsh'.\n")
			b.WriteString("These might delete data that is harder to reconstruct (like local snapshots).\n\n")
		} else {
			b.WriteString(lipgloss.NewStyle().Foreground(accentColor).Bold(true).Render("⚠️  CONFIRMATION REQUIRED"))
			b.WriteString("\n\n")
		}

		b.WriteString("Are you sure you want to delete the files found by the selected modules?\n")
		b.WriteString("This action cannot be undone.\n\n")
		b.WriteString(lipgloss.NewStyle().Foreground(accentColor).Render("Type 'y' to confirm or 'n' to cancel."))
		b.WriteString(helpStyle.Render("\n\ny/n: confirm/cancel • q: quit"))

	case stateExecuting:
		b.WriteString(headerStyle.Render("Executing Cleanup..."))
		b.WriteString("\n\n")
		b.WriteString("Please wait while we delete the files.")

	case stateFinished:
		b.WriteString(headerStyle.Render("Cleanup Complete!"))
		b.WriteString("\n\n")
		b.WriteString(fmt.Sprintf("Successfully reclaimed %s of disk space.", formatSize(m.freed)))
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
