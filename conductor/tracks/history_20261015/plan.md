# Plan: history_20261015

Process: lightweight. Branch `feat/app-v0`.

## Milestone 3 (engine side): history and free-space timeline
- [ ] Task: Run records: `engine.History` (append a Run, read the newest runs back) and the engine writes one after every real apply that deleted or failed something
- [ ] Task: Samples: `engine.History` appends a sample only when due; reads the last N days back
- [ ] Task: `cmm sample` and `cmm history [--json]`
- [ ] Task: Docs (README, GEMINI.md, product.md) and the proof that nothing that decides reads the history
