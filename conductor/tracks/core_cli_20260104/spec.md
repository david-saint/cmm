# Track Spec: core_cli_20260104

## Overview
Build the foundation of `cmm`, a macOS cleanup CLI tool. This track focuses on the core architecture, interactive selection via a terminal UI (TUI), and the initial set of cleanup modules.

## User Stories
- As a user, I want to selectively clean my Mac's storage to reclaim disk space safely.
- As a developer, I want a tool that understands specific developer-related bloat like Xcode Derived Data.
- As a user, I want to see a "Dry Run" of what will happen before any files are deleted.

## Technical Design

### CLI Structure (Cobra)
- `cmm`: Main entry point.
- `cmm run`: Starts the interactive cleanup flow.
- Flags:
    - `--dry-run`: (Default: true) Preview changes without deleting.
    - `--force`: Bypass confirmations (use with caution).

### Component Architecture
1. **Module Interface:** Each cleanup task (e.g., Xcode, Time Machine) must implement a common interface.
    ```go
    type Module interface {
        Name() string
        Description() string
        Category() string // Recommended, Harsh
        Scan() ([]FileItem, error)
        Delete([]FileItem) (int64, error) // Returns bytes freed
    }
    ```
2. **Scanner Engine:** Orchestrates modules to find removable files.
3. **TUI (Bubble Tea):** An interactive multi-select list of modules and their findings.
4. **Execution Engine:** Handles the actual deletion with safety checks and confirmations.

### Initial Modules
1. **Time Machine Snapshots:** Uses `tmutil`.
2. **User Caches:** Targets `~/Library/Caches` with specific app targeting (Chrome, Spotify, etc.).
3. **Xcode Derived Data:** Targets `~/Library/Developer/Xcode/DerivedData`.
4. **System Logs:** Targets `/Library/Logs` and `~/Library/Logs`.

## UI/UX Design (Bubble Tea/Lip Gloss)
- **Header:** Branded `cmm` header with semantic coloring.
- **Selection List:** Multi-select menu for categories and modules.
- **Detailed View:** Shows file paths and sizes for selected modules.
- **Footer:** Navigation instructions and action triggers (e.g., `Enter` to scan, `D` to delete).
- **Safety Prompts:** High-visibility warnings for "Harsh" cleanups.

## Safety Requirements
- Dry run by default.
- Explanation for every module describing why it's safe or risky.
- "YES" confirmation for destructive actions.
- Permission check: Inform the user if `sudo` is needed for specific modules.
