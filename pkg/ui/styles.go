package ui

import "github.com/charmbracelet/lipgloss"

var (
	// Colors
	primaryColor   = lipgloss.Color("#00ADD8") // Go Blue-ish
	secondaryColor = lipgloss.Color("#3DBAFC")
	accentColor    = lipgloss.Color("#FF4081")
	warningColor   = lipgloss.Color("#FFA000")
	errorColor     = lipgloss.Color("#F44336")
	successColor   = lipgloss.Color("#4CAF50")

	// Styles
	titleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#FFFDFE")).
			Background(primaryColor).
			Padding(0, 1).
			Bold(true).
			MarginBottom(1)

	headerStyle = lipgloss.NewStyle().
			Foreground(secondaryColor).
			Bold(true).
			Underline(true).
			MarginBottom(1)

	cursorStyle = lipgloss.NewStyle().
			Foreground(primaryColor).
			Bold(true)

	selectedStyle = lipgloss.NewStyle().
			Foreground(successColor)

	harshStyle = lipgloss.NewStyle().
			Foreground(warningColor).
			Italic(true)

	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#626262")).
			MarginTop(1)
)
