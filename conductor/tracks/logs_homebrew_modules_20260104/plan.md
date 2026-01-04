# Plan - New Cleanup Modules (Logs & Homebrew)

This plan outlines the implementation of two new cleanup modules for `cmm`: `LogsModule` and `HomebrewModule`.

## Phase 1: System Logs Module
This phase focuses on creating a module to clean up user and system application logs.

- [x] **Task 1.1: Implement LogsModule** [8851374]
- [x] **Task 1.2: Add Unit Tests for LogsModule** [8851374]
- [ ] **Task 1.3: Conductor - User Manual Verification 'Phase 1: System Logs Module' (Protocol in workflow.md)**

## Phase 2: Homebrew Module
This phase adds support for cleaning up Homebrew artifacts.

- [ ] **Task 2.1: Implement HomebrewModule**
    - Create `pkg/modules/homebrew.go`.
    - Implement `cmm.Module` interface.
    - Add logic to detect `brew` in `PATH`.
    - Implement `Scan` using `brew cleanup --dry-run` (if possible) or a summary entry.
    - Implement `Delete` using `brew cleanup --prune=all`.
- [ ] **Task 2.2: Add Unit Tests for HomebrewModule**
    - Create `pkg/modules/homebrew_test.go`.
    - Mock external command execution for `brew`.
    - Test detection and execution logic.
- [ ] **Task 2.3: Conductor - User Manual Verification 'Phase 2: Homebrew Module' (Protocol in workflow.md)**

## Phase 3: Integration and Registration
Register the new modules and ensure they are available in the CLI.

- [ ] **Task 3.1: Register New Modules in CLI**
    - Update `cmd/run.go` to include `LogsModule` and `HomebrewModule` in the `availableModules` list.
    - Ensure `HomebrewModule` is only added if detected.
- [ ] **Task 3.2: Verify Selection UI**
    - Run `cmm run` (in test mode) and verify the new modules appear in the selection list.
- [ ] **Task 3.3: Conductor - User Manual Verification 'Phase 3: Integration and Registration' (Protocol in workflow.md)**
