# Plan: app_v0_20261015

Process: lightweight, one check-in at the end (see spec.md). Branch `feat/app-v0`.

## Milestone 2: App v0
- [ ] Task: Engine API for apps (Go, TDD): `apply --select-file` and `--json` NDJSON events as in the spec; child processes started by cmm get Homebrew's folders on PATH so a Finder-launched cmm still sees `brew`
- [ ] Task: SwiftUI app (`CmmKit`, `Cmm`, tests, `build-app.sh`) built in a separate worktree against the contract in the spec
- [ ] Task: Integration: the real `cmm` through the Swift client against a fake `HOME` (sandboxed apply); build and open the app; README section
- [ ] Task: Milestone check-in: a pass/fail table for the owner, who looks at the app (how it looks and feels is the one thing only a person can judge)
