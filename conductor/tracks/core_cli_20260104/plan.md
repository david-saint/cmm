# Track Plan: core_cli_20260104

## Phase 1: Foundation [checkpoint: d90cea9]
- [x] Task: Initialize Go module and setup Cobra CLI structure f951059
- [x] Task: Define the `Module` interface and shared data structures 62027cb
- [x] Task: Implement a basic "Hello World" Cobra command for `cmm` a709689
- [x] Task: Conductor - User Manual Verification 'Foundation' (Protocol in workflow.md) d90cea9

## Phase 2: Scanning Engine & Initial Modules [checkpoint: 170858d]
- [x] Task: Implement the Xcode Derived Data module (Scan logic) 5f5bcfd
- [x] Task: Implement the User Caches module (Scan logic for general caches) 5f953bd
- [x] Task: Implement the Time Machine Snapshots module (Scan logic using `tmutil`) 21f21f2
- [x] Task: Create the Scanner Engine to orchestrate multiple modules 6010cfc
- [x] Task: Conductor - User Manual Verification 'Scanning Engine & Initial Modules' (Protocol in workflow.md) 170858d

## Phase 3: Interactive TUI (Bubble Tea) [checkpoint: ac7af4d]
- [x] Task: Implement a basic Bubble Tea model for module selection c2bdac6
- [x] Task: Add multi-select capability to the TUI c2bdac6
- [x] Task: Style the TUI using Lip Gloss (Headers, semantic coloring) 6d2bc2b
- [x] Task: Connect the Scanning Engine to the TUI to show real-time progress/results 2368c60
- [x] Task: Conductor - User Manual Verification 'Interactive TUI' (Protocol in workflow.md) ac7af4d

## Phase 4: Execution Engine & Safety [checkpoint: 2b42d61]
- [x] Task: Implement "Dry Run" logic to preview deletions 69aef06
- [x] Task: Implement the Execution Engine with safety confirmations b4ea7f5
- [x] Task: Add "Nuclear/Harsh" warning prompts for specific modules b4ea7f5
- [x] Task: Implement the actual deletion logic for the initial modules b4ea7f5
- [x] Task: Conductor - User Manual Verification 'Execution Engine & Safety' (Protocol in workflow.md) 2b42d61

## Phase 5: Final Reporting & Polish
- [ ] Task: Implement the post-cleanup summary report (Space reclaimed, files removed)
- [ ] Task: Add error handling and user-friendly messages for permission issues
- [ ] Task: Final UX pass: Add spinners, progress bars, and keyboard shortcuts
- [ ] Task: Conductor - User Manual Verification 'Final Reporting & Polish' (Protocol in workflow.md)
