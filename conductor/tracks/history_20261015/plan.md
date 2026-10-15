# Plan: history_20261015

Process: lightweight. Branch `feat/app-v0`.

## Milestone 3 (engine side): history and free-space timeline
- [x] Task: Run records: `engine.FileHistory` (append a Run, read the newest runs back) and the engine writes one after every real apply that deleted or failed something
  - Done 2026-10-15 (796f782).
- [x] Task: Samples: `FileHistory.Sample` appends only when due; `Samples` reads the last N days back
  - Done 2026-10-15 (796f782).
- [x] Task: `cmm sample` and `cmm history [--json]`
  - Done 2026-10-15 (13a0762). Checked on the real binary in a fake home: a 300 MB cache cleaned by `apply --yes --only go-build --json` left one run line and the samples; `history` and `history --json` read them back; files 0600 in a 0700 folder.
- [x] Task: Docs and the proof that nothing that decides reads the history
  - README, tech-stack, product; `history_boundary_test.go` (the engine holds the history through an append-only interface, only the history code and the history commands read the files, rules/policy/guards/sizing never mention them); the allow-list test refuses cmm's own records. 43 mutants of the store, report, apply wiring and commands: all caught after six new tests.
