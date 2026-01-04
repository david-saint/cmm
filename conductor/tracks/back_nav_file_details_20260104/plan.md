# Plan - Back Navigation and File Details

## Phase 1: Navigation Infrastructure [checkpoint: d5e43e9]
- [x] Task: Implement 'Back' navigation state in the UI model (d52af56)
    - [x] Create test for state transition when 'Esc' is pressed
    - [x] Update `Update` function in `pkg/ui/model.go` to handle `esc` key
- [x] Task: Conductor - User Manual Verification 'Phase 1: Navigation Infrastructure' (d5e43e9)

## Phase 2: Data Model and Sorting Logic [checkpoint: 67e2a78]
- [x] Task: Update Module/Scanner data structures to include detailed file info (7e1fd6b)
    - [x] Modify `ModuleResult` or equivalent to store a list of file details (path, size, type)
    - [x] Implement sorting logic to order files by size descending
    - [x] Write unit tests for sorting logic in `pkg/cmm/scanner_test.go`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Data Model and Sorting Logic' (67e2a78)

## Phase 3: TUI Implementation for File Details
- [x] Task: Implement inline toggle logic in the View model (eaeaccc)
    - [x] Add `Expanded` state to category/result items in the UI model
    - [x] Update `Update` function to toggle `Expanded` state on `enter` or `space`
    - [x] Write tests for toggle state changes
- [ ] Task: Implement Detailed File List View
    - [ ] Create a sub-view function to render the list of files under an expanded category
    - [ ] Format file sizes for human readability
    - [ ] Add icons/visual indicators for file types using `Lip Gloss`
    - [ ] Ensure the view handles large lists efficiently (e.g., within a viewport or truncated)
- [ ] Task: Conductor - User Manual Verification 'Phase 3: TUI Implementation for File Details' (Protocol in workflow.md)

## Phase 4: Final Polishing and Integration
- [ ] Task: Refine Styles and Layout
    - [ ] Update `pkg/ui/styles.go` with specific styles for the detailed list
    - [ ] Ensure consistent indentation and visual hierarchy for the accordion view
- [ ] Task: Final End-to-End Verification
    - [ ] Perform a full dry-run scan and verify navigation and detail viewing
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Final Polishing and Integration' (Protocol in workflow.md)
