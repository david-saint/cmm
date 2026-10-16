# Plan: app_m3_20261016

Process: lightweight, one check-in at the end (see spec.md). Branch `feat/app-m3`, worktree `.claude/worktrees/app-m3`.

## Phase 1: the logic layer (no UI; independent of the boards)
- [x] Task: Decode the history report (`HistoryReport`, golden fixture copied from the engine's `history_v1.golden.json`, tolerant of missing optional fields) and add `EngineClient.history()` and `.sample()` with fakes for tests
- [x] Task: `HistoryTimeline` (R1) and `WeekChange` (R2): gaps, markers, y-range, the "now" point, fewer-than-3-days rule
- [x] Task: `HistorySentences` (R3) and `RunRows` (R4): totals sentence, weekly grouping in local time, group naming, failed and stopped labels, the dotted Docker figure
- [x] Task: `MenuBarState` (R5), including the low-space threshold and the cached last scan
- [x] Task: `WeeklyPlanner` (R7): next fire date with daylight-saving-safe calendar maths, the notify-or-not rule, the two texts, catch-up within 24 hours, once per week
- [x] Task: `SamplerSchedule` (R6) with an injected scheduler and clock
- [x] Task: `Settings` store and the updated preferences tripwire (R9); the safety tripwires of R10 and the tampered-history test
- [x] Task: Phase 1 review: run the whole suite, mutate the planner and the gap logic, fix survivors

## Phase 2: views and system integration (boards approved 2026-10-16; two builders in parallel)
Builder A (branch `feat/app-m3-history`): the History face. Builder B (branch `feat/app-m3-system`): menu bar, Settings, opt-in card, notification, background services, lifecycle, README. The orchestrator merges them, then runs the live sandbox pass and the check-in.
- [ ] Task: The History face in the Details pane (third face), to `C-History`, `C-History-Dark` and `C-History-States`; renders compared with the boards
- [ ] Task: `MenuBarExtra` and the popover states, to `C-MenuBar-Dark` and `C-MenuBar-States`
- [ ] Task: The opt-in card and the Settings scene, to `C-Optin` and `C-Settings`; `SMAppService` for "Open at login"
- [ ] Task: Notification delivery (`UserNotifications`), to `C-Notification`; the click opens the window at rest
- [ ] Task: Accessibility pass (R11) and the interaction tests through the offscreen window, like the map's
- [ ] Task: Live sandbox run of the real app (fake `HOME`): History face, menu bar item, a delivered notification; README

## Check-in
- [ ] Task: One short pass/fail table for the owner; the owner looks at how it looks and feels
