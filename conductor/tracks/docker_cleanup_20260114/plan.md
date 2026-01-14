# Plan: Docker Cleanup Module

## Phase 1: Module Foundation & Detection [checkpoint: 0ed0c9d]
- [x] Task: Initialize Docker module structure in `pkg/modules/docker.go` 7d9f453
- [x] Task: Implement Docker installation detection b0b7992
- [x] Task: Conductor - User Manual Verification 'Module Foundation & Detection' (Protocol in workflow.md) 0ed0c9d

## Phase 2: Scanning & Estimation [checkpoint: 64af566]
- [x] Task: Write tests for `Scan()` method 264e073
    - [x] Mock `docker system df` output parsing
    - [x] Verify `FileItem` generation for each category (Images, Containers, Volumes, etc.)
- [x] Task: Implement `Scan()` logic 264e073
    - [x] Execute `docker system df --format '{{.Type}}	{{.Size}}	{{.Reclaimable}}'`
    - [x] Parse output and calculate total reclaimable space
- [x] Task: Conductor - User Manual Verification 'Scanning & Estimation' (Protocol in workflow.md) 64af566

## Phase 3: Cleanup Execution [checkpoint: 8475494]
- [x] Task: Write tests for `Delete()` method 88b44c7
    - [x] Mock execution of `docker system prune` and `docker volume prune`
    - [x] Verify total bytes freed calculation
- [x] Task: Implement `Delete()` logic 88b44c7
    - [x] Execute `docker system prune -f`
    - [x] Execute `docker volume prune -f`
    - [x] Return the total size of items successfully pruned
- [x] Task: Conductor - User Manual Verification 'Cleanup Execution' (Protocol in workflow.md) 8475494

## Phase 4: Integration & Registry
- [ ] Task: Register `DockerModule` in the main module list
    - [ ] Update module initialization logic to include the new Docker module
- [ ] Task: Conductor - User Manual Verification 'Integration & Registry' (Protocol in workflow.md)
