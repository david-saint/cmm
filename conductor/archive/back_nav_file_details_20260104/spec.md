# Specification - Back Navigation and File Details

## Overview
This track introduces enhanced navigation and transparency features to the `cmm` CLI. Users will be able to navigate back to previous screens and view a detailed, sorted list of files targeted for deletion within the interactive TUI.

## Functional Requirements
- **Back Navigation:**
    - Implement a mechanism to return to the previous view from any sub-view (e.g., from the Scanning/Summary view back to the Module Selection view).
    - Trigger: `Esc` key.
- **Detailed File Listing:**
    - Provide a "human-readable" list of files identified for deletion within a specific category.
    - View Style: Inline toggle (accordion-like) that expands/collapses under the selected category.
    - Trigger: `Enter` or `Space` key when a category is highlighted.
    - Information per file:
        - Full file path.
        - Formatted file size (e.g., 2.4 MB, 500 KB).
        - Visual indicator/icon based on file type.
    - **Sorting:** The list of files must be sorted by size, descending (largest to smallest) by default.

## Non-Functional Requirements
- **TUI Responsiveness:** The UI should remain responsive while expanding/collapsing and sorting large lists of files.
- **Consistency:** Navigation and detail toggling should follow established `Bubble Tea` patterns in the project.

## Acceptance Criteria
- Pressing `Esc` in the Scanning/Summary view returns the user to the Module Selection screen.
- Pressing `Enter` or `Space` on a scan result category toggles a list of specific files.
- The file list displays the path, size, and a relevant icon for each file.
- The displayed file list is sorted by file size in descending order.
- The file list is easily readable and integrated into the existing `Lip Gloss` styles.

## Out of Scope
- Permanent file exclusion (whitelisting) via the UI in this track.
- Advanced filtering options (e.g., by date or extension) beyond the default sort.
