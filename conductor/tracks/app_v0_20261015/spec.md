# Track Spec: app_v0_20261015

## Overview
Milestone 2 of the cmm app: a double-clickable macOS app (SwiftUI) that shows what `cmm` would clean and cleans the items the owner ticks, through the same guarded engine. The app is a thin client: **it never deletes anything itself**; only `cmm` does.

Out of scope for v0: treemap, history, menu-bar item and notifications (M3), the Claude panel (M4), admin/sudo flows, Time Machine, Trash handling.

## Process (approved by the owner on 2026-10-15)
One check-in at the end of the milestone. TDD and per-task commits stay; no per-task plan-update commits or notes. Mutation checks only for code that deletes or guards. The agent may run sandboxed applies (a fake `HOME` under its scratch folder, never the real one); it never runs `cmm apply` against the real disk.

## Architecture
- `cmm` (Go, this repo) is the engine and the only thing that deletes. The app embeds it as `Cmm.app/Contents/Resources/cmm`, built from this repo by `app/macos/build-app.sh`. The environment variable `CMM_BIN` overrides the path (development and tests).
- `app/macos/` is a Swift package with: library `CmmKit` (models, the process client, view models; no UI code), executable `Cmm` (the SwiftUI app) and tests `CmmKitTests`. `build-app.sh` builds the Go binary and the Swift app, then assembles and ad-hoc signs `app/macos/build/Cmm.app` (bundle id `com.davidsaint.cmm`, display name "cmm").
- macOS 14 or later (the owner's machine runs macOS 27 with Xcode 27 and Swift 6.4). `xcodegen` is installed if a real Xcode project is ever needed; SwiftPM plus the script is the default.
- The app starts `cmm` with `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (a Finder-launched app has a minimal PATH, and the Homebrew rule needs `brew`).

## The CLI contract the app relies on

### Plan: `cmm plan --json` (exists; schema v1, golden-tested)
Stdout is exactly one JSON document, exit status 0. It takes 10-20 s (big folders are sized), so the app shows a spinner and "Checking what can safely go (this can take a minute)".
```json
{
  "schema_version": 1,
  "generated_at": "2026-10-15T09:38:54.530781+02:00",
  "host": { "volume": "/System/Volumes/Data", "free_bytes": 27633246208 },
  "items": [
    { "rule": "go-build", "group": "Go build cache", "path": "/Users/saint/Library/Caches/go-build",
      "bytes": 927080448, "tier": "safe", "action": "delete" },
    { "rule": "lane-deps", "group": "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)",
      "path": "/Users/saint/lane-builds/ios27-scene-cloud-mobile/node_modules", "bytes": 838086656,
      "tier": "safe", "action": "delete", "note": "lane ios27-scene-cloud-mobile: untouched for 5+ days" },
    { "rule": "homebrew", "group": "Homebrew: old versions of installed formulae (brew cleanup)",
      "path": "homebrew: cleanup", "bytes": 704000000, "tier": "safe", "action": "command",
      "note": "boost 1.85.0, 0.5 GB; python@3.14 3.14.7, 81 MB" }
  ],
  "groups":  [ { "group": "Go build cache", "bytes": 927080448, "count": 1 } ],
  "skipped": [ { "rule": "uv-cache", "reason": "uv is running" } ],
  "total_bytes": 2469166592
}
```
Reading rules: `items[].path` is an opaque identity (for `"action": "command"` it is not a file path: show `note` instead of it). `tier` is `safe` (preselect), `review` or `manual` (never preselect; reserved). `note` is optional. `skipped` is information, not an error. Unknown fields must be ignored; `schema_version` other than 1 is an error the app shows ("this app reads schema 1").

### Apply: `cmm apply --yes --json --select-file FILE` (new; built by the engine side of this track)
- `FILE` is a UTF-8 JSON array of strings: the `path` values of the ticked items, exactly as in the plan.
- `cmm` plans again, then keeps only the selected paths that are in that fresh plan: **a selection can only narrow the fresh plan, never widen it.** Each item is re-checked right before it is removed, as in every apply. A selected path that is not in the fresh plan is reported as skipped.
- `--json` needs `--yes` (the caller has the person's confirmation for exactly this selection) or `--dry-run`. `--only RULES` still works and combines with the selection.
- Stdout is NDJSON: one JSON object per line, nothing else. Human text is not printed.
```
{"event":"start","schema_version":1,"selected":2,"matched":2,"bytes":1765167104,"free_bytes":27633246208}
{"event":"item","rule":"go-build","group":"Go build cache","path":"/Users/saint/Library/Caches/go-build","status":"deleted","reason":"","bytes":927080448,"freed_bytes":927080448}
{"event":"item","rule":"lane-deps","group":"Idle lane dependencies (...)","path":"/Users/saint/lane-builds/x/node_modules","status":"skipped","reason":"in use: node (pid 1234) has files open","bytes":838086656,"freed_bytes":0}
{"event":"done","deleted":1,"skipped":1,"failed":0,"freed_bytes":927080448,"free_before":27633246208,"free_after":28560326656,"stopped":false,"warnings":[],"log":"/Users/saint/.local/state/cmm/cleanup.log"}
```
`status` is `deleted`, `skipped`, `failed` or `dry-run`. `log` is present only when something was logged. `warnings` lists problems with the log or the stamp (never failures of the cleanup itself).
- Exit status: 0 when nothing failed (skips are fine); 1 when an item failed or on a fatal error (a message on stderr, and the `done` event may be missing).
- SIGINT stops cleanly after the item in progress and ends with a `done` event with `"stopped":true`.
- Without a terminal and without `--yes` `cmm apply` refuses, as always.

## Safety rules for the app (each one gets a test)
1. The app never deletes, moves or writes outside its own temporary files; it only starts `cmm`.
2. It passes only paths that appeared in the last `cmm plan --json` result, never typed or constructed ones.
3. `cmm apply --yes` runs only after the person clicked **Clean** and then confirmed in a sheet that names the item count and the total size; Cancel runs nothing.
4. The selection file is created with mode 0600 in the app's temporary folder and removed afterwards.
5. The app shows metadata (paths, sizes, notes), never file contents.
6. Tests never run a real clean on the real disk: they use a fake `cmm` script, or the real `cmm` against a fake `HOME` in a temporary folder.

## UX (one window, "cmm", minimum 760x560, follows the system light/dark appearance)
- **Header:** three cards: *Free space now* (value, volume), *Safe to remove* (planned total, and the selected total when it differs), *Skipped by guards* (count; the reasons on click or hover).
- **Body:** groups sorted by size, largest first. A group row has a disclosure arrow, a tri-state checkbox, the name, the item count and the size. Expanded, it lists items: checkbox, path shortened to `~/...` (or the `note` for command items), size, and the `note` as secondary text. Items with tier `safe` start ticked.
- **Footer:** "Selected: N items, X GB", **Rescan** (⌘R), **Clean N items…** (disabled when nothing is ticked).
- **Confirmation sheet:** "Delete N items (X GB)? Each item is checked again right before it is removed." Buttons: Cancel (default) and Clean.
- **States:** scanning (spinner), ready, empty ("Nothing to clean right now" plus the skip reasons), cleaning (each item as it finishes, with deleted/skipped/failed marks, and a **Stop** button that sends SIGINT), done (freed X, skipped N, failed M, free space before and after, the log path, Rescan), error (the message and Retry; `cmm` not found; plan failed; schema mismatch).
- Accessibility labels on the checkboxes and buttons; no color as the only signal.

## Testing
- `swift test` covers: decoding real plan JSON fixtures (anonymized paths), tolerance for unknown fields and a schema mismatch, the selection model (tri-state, totals, defaults by tier), the NDJSON parser (split chunks, several events per chunk, a bad line), the view-model state machine with a fake client, and the safety rules above.
- Integration tests use a fake `cmm` shell script with canned output, and, when `CMM_BIN` points at a built `cmm`, the real binary against a fake `HOME` (a sandboxed real apply).
- The engine side (Go) is tested in this repo's sandbox as for every rule: the selection only narrows, a path outside the fresh plan is skipped, `--json` output is pure NDJSON, `--json` without `--yes` is refused, the log and stamp are written as for any apply.

## Acceptance criteria
1. `app/macos/build-app.sh` produces `Cmm.app`, which opens, scans, shows the groups and sizes, and cleans only the ticked items after the confirmation sheet.
2. `swift test` and `go test -race ./...` pass; a sandboxed real apply through the Swift client deletes exactly the selected items.
3. The app never starts `cmm apply` without the confirmation sheet, and never with a path that was not in the last plan.
4. The README explains how to build and open the app and what it does and does not do.
