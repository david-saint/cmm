# Specification: Docker Cleanup Module

## Overview
Add a new module to `cmm` that allows users to reclaim disk space used by unused Docker artifacts (containers, volumes, networks, and images). This module will only be visible if Docker is installed on the system.

## User Goals
- Reclaim space from unused Docker resources.
- See an estimate of how much space can be reclaimed before performing the action.
- Control whether to proceed with Docker cleanup separately from other modules.

## Functional Requirements
1. **Docker Installation Check:** The module must verify if the `docker` command is available in the system PATH. If not, the module should not be active or should return no items during scan.
2. **Space Estimation:** Use `docker system df` to estimate the reclaimable space for different categories (Images, Containers, Local Volumes, Build Cache).
3. **Information Display:** Display the reclaimable items in the TUI, showing the category and the estimated size.
4. **Cleanup Execution:** 
   - Execute `docker system prune -f` to remove unused containers, networks, and dangling images.
   - Execute `docker volume prune -f` to remove unused local volumes.
5. **Categorization:** The module will be categorized as "Advanced/Optional".

## Non-Functional Requirements
- **Safety:** Ensure the `-f` (force) flag is used to avoid interactive prompts during execution, as `cmm` handles the confirmation UI.
- **Performance:** Scanning should be relatively fast by parsing the output of `docker system df`.

## Acceptance Criteria
- [ ] Module correctly identifies if Docker is installed.
- [ ] Module reports estimated reclaimable space.
- [ ] Module successfully executes prune commands when confirmed.
- [ ] Reclaimed space is accurately reported after deletion.

## Out of Scope
- Detailed listing of individual images/containers (summary by category is sufficient).
- Aggressive image pruning (`docker image prune -a`).
