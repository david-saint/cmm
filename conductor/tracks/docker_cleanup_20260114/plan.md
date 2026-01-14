# Plan: Docker Cleanup Module

## Phase 1: Module Foundation & Detection
- [x] Task: Initialize Docker module structure in `pkg/modules/docker.go` 7d9f453
    - [ ] Create `DockerModule` struct
    - [ ] Implement `Name()`, `Description()`, and `Category()` (Advanced/Optional)
- [x] Task: Implement Docker installation detection b0b7992
    - [ ] Create `isDockerInstalled()` helper function
    - [ ] Ensure `Scan()` returns early if Docker is missing
- [ ] Task: Conductor - User Manual Verification 'Module Foundation & Detection' (Protocol in workflow.md)

## Phase 2: Scanning & Estimation
- [ ] Task: Write tests for `Scan()` method
    - [ ] Mock `docker system df` output parsing
    - [ ] Verify `FileItem` generation for each category (Images, Containers, Volumes, etc.)
- [ ] Task: Implement `Scan()` logic
    - [ ] Execute `docker system df --format '{{.Type}}	{{.Size}}	{{.Reclaimable}}'`
    - [ ] Parse output and calculate total reclaimable space
- [ ] Task: Conductor - User Manual Verification 'Scanning & Estimation' (Protocol in workflow.md)

## Phase 3: Cleanup Execution
- [ ] Task: Write tests for `Delete()` method
    - [ ] Mock execution of `docker system prune` and `docker volume prune`
    - [ ] Verify total bytes freed calculation
- [ ] Task: Implement `Delete()` logic
    - [ ] Execute `docker system prune -f`
    - [ ] Execute `docker volume prune -f`
    - [ ] Return the total size of items successfully pruned
- [ ] Task: Conductor - User Manual Verification 'Cleanup Execution' (Protocol in workflow.md)

## Phase 4: Integration & Registry
- [ ] Task: Register `DockerModule` in the main module list
    - [ ] Update module initialization logic to include the new Docker module
- [ ] Task: Conductor - User Manual Verification 'Integration & Registry' (Protocol in workflow.md)
