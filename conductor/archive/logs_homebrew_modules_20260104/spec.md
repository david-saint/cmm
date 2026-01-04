# Specification - New Cleanup Modules (Logs & Homebrew)

## Overview
This track introduces two new cleanup modules to `cmm` to expand its capabilities:
1.  **System Logs Module:** Targets application and system logs in user and global directories.
2.  **Homebrew Module:** Cleans up stale lock files, outdated downloads, and old versions using Homebrew's native cleanup tools.

## Functional Requirements

### 1. System Logs Module
- **Name:** `System Logs`
- **Description:** `Application and system logs from user and global directories.`
- **Category:** `Recommended`
- **Target Paths:**
    - `~/Library/Logs` (User-specific logs)
    - `/Library/Logs` (Global application logs)
- **Behavior:**
    - Recursively scan the target paths to identify log files and directories.
    - Calculate the total size for each top-level entry to display in the `cmm` file preview.
    - Delete selected items upon user confirmation.

### 2. Homebrew Module
- **Name:** `Homebrew`
- **Description:** `Stale lock files, outdated downloads, and old versions of formulae.`
- **Category:** `Recommended`
- **Conditional Activation:** This module must only be available and visible if the `brew` executable is found in the system's `PATH`.
- **Scanning:**
    - Attempt to use `brew cleanup --dry-run` (or similar) to list items that will be removed, allowing them to be displayed in the UI.
    - If a detailed list is unavailable, provide a summary entry representing the potential cleanup.
- **Cleanup Action:** Execute `brew cleanup --prune=all`.

### 3. CLI Integration
- **Selection Menu:** Both modules must be added to the interactive "Select Cleanup Modules" list.
- **Deep Clean Flow:** Both modules must be included in the predefined "Deep Clean" maintenance flow.

## Acceptance Criteria
- [ ] `System Logs` module correctly identifies and calculates sizes for logs in both `~/Library/Logs` and `/Library/Logs`.
- [ ] `Homebrew` module is hidden if `brew` is not installed.
- [ ] `Homebrew` module successfully executes `brew cleanup --prune=all` when selected.
- [ ] Both modules are automatically included and executed as part of the `Deep Clean` flow.
- [ ] Space reclaimed by both modules is accurately reported in the final execution summary.

## Out of Scope
- Cleaning `/var/log` (which often requires root permissions and may have SIP restrictions).
- Updating Homebrew formulae or managing `brew bundle`.
