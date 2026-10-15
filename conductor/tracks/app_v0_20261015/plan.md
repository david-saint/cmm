# Plan: app_v0_20261015

Process: lightweight, one check-in at the end (see spec.md). Branch `feat/app-v0`.

## Milestone 2: App v0
- [x] Task: Engine API for apps (Go, TDD): `apply --select-file` and `--json` NDJSON events as in the spec; child processes started by cmm get Homebrew's folders on PATH so a Finder-launched cmm still sees `brew`
  - Done 2026-10-15 (commits 83e0c6d, ed3f0c2, d358d17). `go test -race ./...` passes (cmd 93.8%, engine 95.4%, sys 95.4%); 20 mutants of the selection and JSON code and 10 of the PATH code are caught (one equivalent survivor). Checked on the real binary in a fake home: of three selected paths only the planned Go cache was deleted, the documents file and the home folder were reported as skipped, the npm cache stayed, and the log and stamp were written.
- [~] Task: SwiftUI app (`CmmKit`, `Cmm`, tests, `build-app.sh`) built in a separate worktree against the contract in the spec (worker in `.claude/worktrees/app-ui`, branch `feat/app-v0-ui`)
- [ ] Task: Integration: the real `cmm` through the Swift client against a fake `HOME` (sandboxed apply); build and open the app; README section
- [ ] Task: Milestone check-in: a pass/fail table for the owner, who looks at the app (how it looks and feels is the one thing only a person can judge)
