# cmm (macOS Cleanup & Maintenance)

## Project Overview
`cmm` is a modern, interactive Go-based command-line tool designed to simplify and automate macOS system maintenance. It leverages the Conductor methodology for structured development and focuses on reclaiming disk space through guided cleanup workflows.

### Main Technologies
- **Language:** Go (Golang)
- **CLI Framework:** Cobra
- **Terminal UI:** Bubble Tea, Lip Gloss, Bubbles
- **System Tools:** `tmutil`, `du`, `rm`, `brew`

### Architecture
The project follows a modular architecture where specific cleanup tasks (e.g., Xcode, Time Machine) are encapsulated into "Modules" implementing a common interface. The "Scanner Engine" orchestrates these modules, and the results are presented through an interactive "Bubble Tea" TUI.

## Building and Running
*Note: The project is in the initial development phase.*

- **Build:** `go build -o cmm main.go` (TODO: Initialize main.go)
- **Run:** `./cmm run` (TODO: Implement run command)
- **Test:** `go test ./...`

## Development Conventions
- **Conductor Methodology:** Project state and tracks are managed in the `conductor/` directory.
- **Workflow:** Strictly follows Test-Driven Development (TDD) as defined in `conductor/workflow.md`.
- **Code Style:** Adheres to the Go and General style guides in `conductor/code_styleguides/`.
- **Quality Gate:** Target >80% code coverage.

## Key Files & Directories
- **`conductor/`**: Contains project vision, tech stack, workflow, and development tracks.
- **`conductor/tracks/`**: Detailed plans and specifications for current and future features.
- **`IDEA.md`**: The original brainstorming document containing manual cleanup commands.
- **`GEMINI.md`**: This file, serving as the primary context for the AI agent.