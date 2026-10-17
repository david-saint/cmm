# cmm (macOS Cleanup & Maintenance)

## Project Overview
`cmm` is a modern, interactive Go-based command-line tool designed to simplify and automate macOS system maintenance. It leverages the Conductor methodology for structured development and focuses on reclaiming disk space through guided cleanup workflows.

### Main Technologies
- **Language:** Go (Golang)
- **CLI Framework:** Cobra
- **Terminal UI:** Bubble Tea, Lip Gloss, Bubbles
- **System Tools:** `lsof`, `pgrep`, `xcrun simctl`, `plutil`, `brew`, `getconf` (all through `pkg/sys.Runner`) and, for the manual Time Machine module, `tmutil`

### Architecture
Cleanups are **rules** (`pkg/rules`) run by an engine (`pkg/engine`) that plans, re-checks and applies them: a path is deletable only if a rule claims it and the policy accepts it, every item is checked again right before deletion, and nothing is deleted without a person at a terminal. `cmm plan` (and `--json`), `cmm apply` and `cmm run` (a preview unless `--apply`) are thin commands on top. The interactive screen (`pkg/ui`, `pkg/cmm`) shows the engine's groups through an adapter in `cmd`; the manual Time Machine module is the only legacy module left. Tests run in a sandbox and must never touch real files. See `README.md` and `conductor/tracks/engine_v2_20261014/spec.md`.

## Building and Running
- **Build:** `go build -o /tmp/cmm-dev .` (never `go install`: it would overwrite the installed `cmm`)
- **Look:** `/tmp/cmm-dev plan` (read-only); **interactive preview:** `/tmp/cmm-dev run`
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