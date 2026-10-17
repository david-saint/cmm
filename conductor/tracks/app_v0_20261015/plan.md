# Plan: app_v0_20261015

Process: lightweight, one check-in at the end (see spec.md). Branch `feat/app-v0`.

## Milestone 2: App v0
- [x] Task: Engine API for apps (Go, TDD): `apply --select-file` and `--json` NDJSON events as in the spec; child processes started by cmm get Homebrew's folders on PATH so a Finder-launched cmm still sees `brew`
  - Done 2026-10-15 (commits 83e0c6d, ed3f0c2, d358d17). `go test -race ./...` passes (cmd 93.8%, engine 95.4%, sys 95.4%); 20 mutants of the selection and JSON code and 10 of the PATH code are caught (one equivalent survivor). Checked on the real binary in a fake home: of three selected paths only the planned Go cache was deleted, the documents file and the home folder were reported as skipped, the npm cache stayed, and the log and stamp were written.
- [x] Task: SwiftUI app (`CmmKit`, `Cmm`, tests, `build-app.sh`) built in a separate worktree against the contract in the spec
  - Built by a background worker in its own worktree (11 commits, nothing outside `app/`), then reviewed and re-verified on 2026-10-15: `swift test` runs 186 tests (2 skipped by design), 0 failures, 0 warnings; `build-app.sh` makes a valid ad-hoc-signed `Cmm.app` (7.8 MB) with cmm 0.4.0 inside; every screen renders in light and dark. Read in the code: `apply` is reachable only through `confirmClean` (the pending confirmation for the current plan), and the selection file is created `O_EXCL|O_NOFOLLOW` with mode 0600 in a 0700 folder.
- [x] Task: Integration: the real `cmm` through the Swift client against a fake `HOME` (sandboxed apply); build and open the app; README section
  - The three real-cmm tests pass with a freshly built cmm, including a sandboxed real apply (it deleted exactly the selected items and spared the unselected one and the bystander; it refuses to start unless the fresh plan is only sandbox deletes).
  - Found by running a real cmm in a fake home with a reader that quits after the first event: cmm died on the broken pipe (first cache deleted, second kept, no stamp). Fixed by ignoring SIGPIPE in `--json` mode (0fb4eeb) and verified on the real binary before and after.
  - Found by the worker: the root `.gitignore` rule `cmm` also hid `app/macos/Sources/Cmm` on a case-insensitive filesystem; anchored to `/cmm`.
  - Not verified by anyone yet: clicking through the live window (the sheet, Stop, the popover, ⌘R, quitting mid-clean) and VoiceOver. That is the owner's check-in.
- [~] Task: Milestone check-in: a pass/fail table for the owner, who looks at the app (how it looks and feels is the one thing only a person can judge)
