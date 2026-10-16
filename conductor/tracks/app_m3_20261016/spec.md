# Track Spec: app_m3_20261016

## Overview
Milestone 3 of the cmm app, app side: a **History** face in the Details pane (what past cleanups freed and how free space has moved), a **menu bar item** with a popover, a **weekly notification**, and the small amount of settings and consent they need. The engine side exists (track `history_20261015`: `cmm history --json`, `cmm sample --json`). The app stays a thin client: **nothing in this track deletes anything, plans differently, or changes what a plan contains.**

Out of scope: the Claude panel (M4); the optional "Since last week: what grew" row (it needs the engine to record rule sizes at every scan; it is drawn on the boards as optional and is built only if the owner asks); Full Disk Access onboarding; anything unattended that deletes (never: a clean always goes through the main window's confirmation card).

## Process
Approved by the owner on 2026-10-16 ("approved" to starting M3, after approving M2). Design first, on the one Design artifact (boards `C-History`, `C-History-Dark`, `C-History-States`, `C-MenuBar-Dark`, `C-MenuBar-States`, `C-Notification`, `C-Optin`, `C-Settings`, and the optional "since last week" board). Phase 1 (the logic layer, no UI) is built in parallel with the drawings and does not depend on them. Phase 2 (views and system integration) is built to the boards the owner approves. One check-in at the end, where the owner looks at how it looks and feels. TDD, one commit per task, no attribution lines, no push, no `go install`. Branch `feat/app-m3` off `feat/app-ui-c` (worktree `.claude/worktrees/app-m3`).

## What the app reads (engine contracts, already built and golden-tested)

`cmm history --json [--limit N] [--days N]` (one JSON document on stdout, `schema_version` 1). The app asks for `--limit 0 --days 90`. The golden file is `pkg/engine/testdata/history_v1.golden.json`; copy it into the Swift test fixtures and decode it there.
```json
{ "schema_version": 1, "generated_at": "2026-10-15T09:00:00Z",
  "host": { "volume": "/System/Volumes/Data", "free_bytes": 24000000000, "capacity_bytes": 245107195904 },
  "runs": [ { "schema_version": 1, "started_at": "...", "finished_at": "...", "deleted": 3, "skipped": 1, "failed": 1,
              "freed_bytes": 4642000000, "freed_inside_bytes": 6200000000, "free_before": 19800000000, "free_after": 24442000000,
              "capacity_bytes": 245107195904, "stopped": false,
              "items": [ { "rule": "go-build", "group": "Go build cache", "path": "...", "status": "deleted", "bytes": 3715000000, "freed_bytes": 3715000000 },
                         { "rule": "docker", "group": "Docker", "path": "docker: unused images", "status": "deleted", "bytes": 6200000000,
                           "freed_bytes": 6200000000, "frees_inside": "Docker's disk image" },
                         { "rule": "uv-cache", "group": "uv cache", "path": "...", "status": "failed", "bytes": 2500000000, "freed_bytes": 0, "reason": "permission denied" } ] } ],
  "samples": [ { "t": "2026-10-13T08:00:00Z", "free_bytes": 21000000000, "capacity_bytes": 245107195904 } ],
  "unreadable_lines": 0 }
```
Reading rules (from the engine): runs are newest first, samples oldest first; `freed_bytes` is what the disk got back (before and after readings), `freed_inside_bytes` is space freed inside another program's storage (today Docker's disk image) and is **never added to freed**; items are only the ones deleted or failed (skipped ones are only counted); `capacity_bytes`, `frees_inside`, `reason` may be missing; times are UTC to the second; `unreadable_lines` is a count of history lines the engine could not read (skip silently; show a quiet footnote only if above 0); an empty history is `"runs": []`.

`cmm sample --json` prints one line: `{"recorded": true|false, "t": "...", "free_bytes": N, "capacity_bytes": N}`. It reads statfs only (no scan, well under a second) and records a sample only when one is due (30 minutes since the last one, or free space moved 256 MiB), so the app may call it as often as it likes and the engine decides.

The plan (`cmm plan --json`) and apply contracts are unchanged (see `app_v0_20261015`).

## Behaviour rules (each one gets tests)

**R1. Timeline.** Input: samples, runs, now, a 90-day window. Output: the points; segments broken wherever two consecutive samples are more than 6 hours apart (the app was not running): never interpolate across a gap, never forecast; one marker per run at (`finished_at`, `free_after`); a "now" point from `host.free_bytes` when it is newer than the last sample; a y-range of whole GB (floor of the minimum, ceiling of the maximum, at least a 5 GB span, so small movements do not look dramatic), labelled with `SizeText`. Fewer than 3 days of samples: say so plainly ("History fills in as cmm runs"), no chart pretending to be a trend.

**R2. Week change.** Compare the free space now with the sample nearest to now minus 7 days (within 24 hours of that moment); if there is none, say nothing. Words: "Free space is 3.1 GB lower than a week ago." / "higher" / "about the same" (under 0.5 GB). Never extrapolate.

**R3. Totals sentence.** "Freed 44.0 GB in 3 cleanings since 29 Sep." counts the runs in the window whose `freed_bytes` is above 0 (a Docker-only run freed nothing on the disk, so it is listed but not counted); the date is the oldest counted run. Docker's inside figure never enters any total.

**R4. Run rows.** Grouped by calendar week (local time). A row: date and time (with the year only if older than a year); the freed text (`SizeText` of `freed_bytes`; a run that freed 0 says "Nothing came back to the disk"); a second line naming the groups of the deleted items, largest first, at most three then "and N more"; "N failed" in the failed colour; `stopped` says "Stopped" (not "Stopped after X of Y": the history does not know Y); a second dotted-amber figure "9.0 GB inside Docker's disk image, not counted" (the places come from the items' `frees_inside`, joined with `HeldBack.join`). A disclosure expands the run's items like the List does (path in the mono face, size, deleted or failed, the reason for a failure). For an item whose path is a pseudo-path (a command), show it as is.

**R5. Menu bar.** A pure `MenuBarState`: `ready(canGo, free)`, `nothingToClean(free)`, `low(free, canGo)` (free under 10 GB, decimal), `scanning`, `justCleaned(freed, free)`, `unknown`. The title is the free space (`SizeText`); the popover shows what the app last scanned (with its time), the top three safe groups, "Scan" (the same scan as the window) and "Open cmm" (raises the window at rest). **The popover never offers Clean.** Review-tier and Docker figures never enter "can go".

**R6. Sampler.** When "Keep a free-space history" is on and the app runs: `cmm sample --json` at launch, every 30 minutes (use `NSBackgroundActivityScheduler`, interval 30 min, tolerance 10 min, so the system times it), on wake, and after every apply. One in flight at a time; a failure is ignored (one quiet log line). The engine decides whether a sample is due.

**R7. Weekly reminder.** When on and the app runs: at the next occurrence of the weekday and time (default Monday 10:00 local time; calendar arithmetic that survives daylight saving), run `cmm plan --json` at utility QoS through the same scan code the window uses, then notify only if the safe total is at least 2 GB or free space is under 15 GB (decimal; these are defaults the owner confirms on the boards). Text: "19.8 GB free. 8.4 GB can go." (low-space variant: "Only 8.1 GB free. 12 GB can go."); sizes only, **never a path, never Docker's inside figure**. A click opens the window at rest. If the app was not running at the time, fire once on the next launch or wake within 24 hours; never twice in the same week (persist `lastWeeklyDate`). When macOS notification permission is denied, say so quietly in Settings and do nothing else. The permission is requested only from the switch being turned on (macOS shows its own prompt), nowhere else.

**R8. Consent.** Every background behaviour is off until the owner turns it on. A one-time card on the home screen (shown once after the update, never again after either answer): "Turn on" enables the menu bar item, the weekly reminder and the history sampler and asks macOS for notification permission; "Not now" changes nothing. "Open at login" is separate, only in Settings, and is `SMAppService.mainApp` (its state is read from the system, not stored by the app).

**R9. Persistence.** One file, `Settings.swift`, owns the app's preferences: the existing `detailsFace` plus `menuBarEnabled`, `weeklyReminderEnabled`, `historyEnabled`, `optInAnswered`, `lastWeeklyDate`. The existing tripwire that pins `FacePreference.swift` as the only preferences file is updated, deliberately, to pin `Settings.swift` and the exact key list. Nothing else is ever stored (no paths, no sizes, no history of the app's own).

**R10. Safety tripwires (source scans and view-model tests, like the existing ones).** The History, MenuBar, Notification, Sampler, Settings and OptIn files never mention `confirmClean`, `apply`, `removeItem`, `trashItem`, `Process(` or `NSWorkspace` (the one existing allowed use stays where it is, for "Show in Finder"); the engine client stays the only code that starts `cmm`; every string the notification builder can produce is asserted to contain no "/" and no "Docker"; the popover's action type has no clean case; a tampered history can only change what is drawn (a test feeds absurd values: negative bytes, finish before start, a future date, 10,000 runs, and the app neither crashes nor draws nonsense).

**R11. Accessibility and motion.** The chart has one accessibility summary (the totals sentence plus the week change) and the run list is its accessible equivalent; Reduce Motion means no animated drawing or flights; Increase Contrast uses tokens with the same contrast floors as the map (pinned in tests).

## Architecture
- `CmmKit` gets the pure parts: `HistoryReport` (decoding), `EngineClient.history()` and `.sample()` (the client already owns the process boundary), `HistoryTimeline`, `HistorySentences`, `RunRows`, `MenuBarState`, `WeeklyPlanner`, `SamplerSchedule`, `SettingsModel` (a protocol over the store so tests use memory). Injected clocks, calendars and time zones everywhere; no `Date()` in logic.
- `Cmm` gets the views and the system integration: the History face (third face of the Details pane, in `DetailsFace`), `MenuBarExtra` with the window style, the opt-in card, the Settings scene, `UserNotifications`, `SMAppService`, and the activation-policy handling that keeps the app alive in the menu bar when the window closes (only when the owner turned the item on; Quit lives in the item's menu).
- Charts: Swift Charts or a custom `Canvas`, whichever the approved boards need; a custom Canvas if gaps and markers fight Swift Charts.
- macOS 14 or later; the owner's Mac runs macOS 27.

## Done means
`swift test` green with the new tests; the renders match the approved boards (compare like the map); a live sandbox run of the real app (fake `HOME`, fake history seeded by real `cmm` runs) shows the History face, the menu bar item and a delivered notification; nothing in the plan, apply or confirmation path changed (the existing tripwires still pass, unmodified except R9's); the README says what the three new behaviours do, that they are off until turned on, and where macOS lets the owner undo each.
