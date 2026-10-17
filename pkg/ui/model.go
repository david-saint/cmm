package ui

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	lipgloss "github.com/charmbracelet/lipgloss"
	"github.com/david-saint/cmm/pkg/cmm"
)

type state int

type Config struct {
	DryRun bool // preview only: nothing is ever deleted
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
	expanded map[int]bool
	state    state
	results  []cmm.ModuleResult
	err      error
	config   Config
	outcomes []cmm.Outcome
	freed    int64
	spinner  spinner.Model
}

func NewModel(scanner *cmm.Scanner, modules []cmm.Module, config Config) Model {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(primaryColor)

	return Model{
		scanner:  scanner,
		choices:  modules,
		selected: make(map[int]struct{}),
		expanded: make(map[int]bool),
		state:    stateSelecting,
		config:   config,
		spinner:  s,
	}
}

func (m Model) Init() tea.Cmd {
	return m.spinner.Tick
}

type scanMsg []cmm.ModuleResult
type executeMsg []cmm.Outcome
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
	// Every module is tried and each outcome carries its own error, so the screen shows what happened to each.
	outcomes, _ := engine.Execute(m.results)
	return executeMsg(outcomes)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "esc":
			if m.state == stateScanning || m.state == stateResults {
				m.state = stateSelecting
				return m, nil
			}
			if m.state == stateConfirming {
				m.state = stateResults
				return m, nil
			}

		case "up", "k":
			if (m.state == stateSelecting || m.state == stateResults) && m.cursor > 0 {
				m.cursor--
			}

		case "down", "j":
			if m.state == stateSelecting && m.cursor < len(m.choices)-1 {
				m.cursor++
			}
			if m.state == stateResults && m.cursor < len(m.results)-1 {
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
			// Return does not answer the question: holding it down must never delete. Only "y" does.
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
			if m.state == stateResults {
				m.expanded[m.cursor] = !m.expanded[m.cursor]
				return m, nil
			}
		}

	case scanMsg:
		m.results = msg
		m.state = stateResults
		m.cursor = 0 // Reset cursor for results view
		return m, nil

	case executeMsg:
		m.outcomes = []cmm.Outcome(msg)
		m.freed = cmm.TotalFreed(m.outcomes)
		m.state = stateFinished
		return m, nil

	case errMsg:
		m.err = msg
		return m, nil

	case spinner.TickMsg:
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd
	}

	return m, nil
}

func (m Model) View() string {
	var b strings.Builder

	b.WriteString(titleStyle.Render(" cmm - Clean My Mac CLI "))
	b.WriteString("\n")
	if m.config.DryRun {
		b.WriteString(lipgloss.NewStyle().Foreground(warningColor).Render(" (PREVIEW ONLY - nothing will be deleted; run `cmm run --apply` to clean) "))
	}
	b.WriteString("\n\n")

	if m.err != nil {
		errorTitle := " Error "
		errorMessage := m.err.Error()
		if os.IsPermission(m.err) {
			errorTitle = " Permission Denied "
			errorMessage = "cmm needs additional permissions to clean some areas. Try running with 'sudo' or check System Settings > Privacy & Security > Full Disk Access."
		}

		b.WriteString(lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFDFE")).
			Background(errorColor).
			Padding(0, 1).
			Bold(true).
			Render(errorTitle))
		b.WriteString("\n\n")
		b.WriteString(errorMessage)
		b.WriteString("\n\n")
		b.WriteString(helpStyle.Render("enter/q: quit"))
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
			b.WriteString(fmt.Sprintf("%s Please wait while we look for removable files.", m.spinner.View()))
			b.WriteString(helpStyle.Render("\n\nesc: back"))
	
			case stateResults:
				b.WriteString(headerStyle.Render("Scan Results"))
				b.WriteString("\n\n")
		
				var totalBytes int64
				for i, res := range m.results {
					var moduleBytes int64
					for _, item := range res.Items {
						moduleBytes += item.Size
					}
					totalBytes += moduleBytes
		
					cursor := "  "
					if m.cursor == i {
						cursor = cursorStyle.Render("> ")
					}
		
								// Accordion indicator
								arrow := "▶ "
								if m.expanded[i] {
									arrow = "▼ "
								}
					
								b.WriteString(fmt.Sprintf("%s%s%s: %d items found (%s)\n", 
									cursor, 
									arrowStyle.Render(arrow),
									res.Module.Name(), 
									len(res.Items), 
									formatSize(moduleBytes)))
					
								if m.expanded[i] {
									for _, item := range res.Items {
										icon := "📄"
										if item.Type == "dir" {
											icon = "📁"
										} else if item.Type == "snapshot" {
											icon = "📸"
										}
										
										// Truncate long paths
										displayPath := item.Path
										if len(displayPath) > 60 {
											displayPath = "..." + displayPath[len(displayPath)-57:]
										}
					
										b.WriteString(fmt.Sprintf("      %s %-60s %10s\n", 
											icon, 
											detailPathStyle.Render(displayPath), 
											detailSizeStyle.Render(formatSize(item.Size))))
									}
								}
							}
											b.WriteString("\n")
		
						b.WriteString(titleStyle.Render(fmt.Sprintf(" Total Space Reclaimable: %s ", formatSize(totalBytes))))
		
						
		
						if m.config.DryRun {
		
							b.WriteString(helpStyle.Render("\n\n↑/↓: move • space: toggle • enter/q: quit • esc: back"))
		
						} else {
		
							b.WriteString(helpStyle.Render("\n\n↑/↓: move • space: toggle • enter: proceed • esc: back • q: quit"))
		
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
			b.WriteString(helpStyle.Render("\n\ny/n: confirm/cancel • q: quit • esc: back"))
		case stateExecuting:
		b.WriteString(headerStyle.Render("Executing Cleanup..."))
		b.WriteString("\n\n")
		b.WriteString(fmt.Sprintf("%s Please wait while we delete the files.", m.spinner.View()))

	case stateFinished:
		b.WriteString(m.finishedView())
	}

	return b.String()
}

// maxNotes is how many skipped or failed items a module lists on the finished screen before "and N more".
const maxNotes = 5

// finishedView says what really happened: per module, the bytes actually freed out of what was planned, how
// many items were skipped or failed and why, and the total that was really freed. It never presents the
// planned size as the result.
func (m Model) finishedView() string {
	var b strings.Builder
	problems := false
	for _, o := range m.outcomes {
		if o.Err != nil || o.Result.Failed > 0 || o.Result.Skipped > 0 {
			problems = true
		}
	}
	if problems {
		b.WriteString(headerStyle.Render("Cleanup finished, with problems"))
	} else {
		b.WriteString(headerStyle.Render("Cleanup Complete!"))
	}
	b.WriteString("\n\n")

	for i, o := range m.outcomes {
		if o.Err != nil {
			fmt.Fprintf(&b, "%s: FAILED: %v\n", o.Module.Name(), o.Err)
		} else {
			var planned int64
			if i < len(m.results) { // Execute reports one outcome per result, in order
				for _, item := range m.results[i].Items {
					planned += item.Size
				}
			}
			line := fmt.Sprintf("%s: freed %s of %s", o.Module.Name(), formatSize(o.Result.Freed), formatSize(planned))
			if o.Result.Skipped > 0 {
				line += fmt.Sprintf(", %d skipped", o.Result.Skipped)
			}
			if o.Result.Failed > 0 {
				line += fmt.Sprintf(", %d failed", o.Result.Failed)
			}
			fmt.Fprintln(&b, line)
		}
		for j, note := range o.Result.Notes {
			if j == maxNotes {
				fmt.Fprintf(&b, "    ... and %d more\n", len(o.Result.Notes)-maxNotes)
				break
			}
			fmt.Fprintf(&b, "    %s\n", note)
		}
	}

	b.WriteString("\n")
	b.WriteString(titleStyle.Render(fmt.Sprintf(" Reclaimed %s in total. ", formatSize(m.freed))))
	b.WriteString(helpStyle.Render("\n\nenter/q: quit"))
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
