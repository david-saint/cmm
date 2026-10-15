# cmm for macOS

A small SwiftUI window for [cmm](../../README.md): it shows what cmm would clean, lets you tick what you want gone
and cleans exactly that through cmm's own guarded engine. The app is a thin client. **It never deletes anything
itself; only the `cmm` program inside it does.**

## Build and open

You need macOS 14 or later, the Swift toolchain (Xcode) and Go. From this folder:

```sh
./build-app.sh          # builds the engine and the app, signs it ad hoc, prints where it is
open build/Cmm.app
```

`build-app.sh` builds `cmm` from this repository (two folders up) into `Cmm.app/Contents/Resources/cmm`, runs
`swift build -c release`, assembles `build/Cmm.app` (bundle id `com.davidsaint.cmm`, name "cmm", macOS 14+) and signs
it with `codesign --sign -` (no developer account; the app is meant to run on the Mac that built it). It can be run
again at any time and only ever replaces its own `build/Cmm.app`. Without Go on `PATH` it stops and says so; it never
runs `go install`.

## What it does

- **Scans** on start with `cmm plan --json` (10 to 20 seconds; big folders are sized) and shows three cards (free
  space, what is safe to remove, how many rules the guards held back and why), then the groups, largest first.
  Groups have a tri-state checkbox and open to their items (path shortened to `~/...`, size, note). Items cmm calls
  `safe` start ticked; anything else never does.
- **Cleans** the ticked items: **Clean N items…** opens a sheet ("Delete N items (X GB)? Each item is checked again
  right before it is removed."). Return presses **Cancel**; **Clean** has no shortcut. After Clean, each item appears
  as cmm finishes it (deleted, skipped, failed), with a **Stop** button that asks cmm to finish the item it is on and
  end. The result screen shows what cmm reports it freed, skipped and failed, the free space before and after, and
  where cmm's log is.
- **Rescan** is ⌘R. States: scanning, ready, nothing to clean (with the guards' reasons), cleaning, done, and an
  error screen with Retry (cmm not found, plan failed, unreadable plan, "this app reads schema 1").
- Follows the system light and dark appearance, with accessibility labels on the checkboxes and buttons and no
  meaning carried by color alone.

## What it does not do

No treemap, history, menu bar item, notifications, Claude panel, administrator or `sudo` flows, Time Machine
snapshots or Trash handling (all out of scope for v0). It does not read file contents (only paths, sizes and notes
from cmm), does not write anything except one temporary file per cleanup (below), and starts no program but `cmm`.

## Safety rules (each has tests)

1. The app never deletes, moves or writes outside its own temporary files; it only starts `cmm`.
2. It passes only paths that appeared in the last plan. `Plan` and its items cannot be built outside `CmmKit`, and
   `ApplySelection` keeps only paths of the plan it is given.
3. `cmm apply --yes` runs only after Clean and then the sheet's Clean; Cancel (or a stale or forged confirmation)
   runs nothing.
4. The ticked paths travel to `cmm apply --select-file` in a file of mode 0600, in a folder of mode 0700, in the app's
   temporary folder. The file is removed as soon as cmm has read it (its `start` event), at the latest when the run
   ends (also on errors), and at once when you press Stop or quit. Only a crash or a force quit in the first seconds of
   a run (cmm plans again before its `start` event) can leave one behind; it holds paths and nothing else.
5. It shows metadata, never file contents.
6. Tests never run a real clean on the real disk.

cmm itself plans again before applying and re-checks every item right before removing it; a selection can only
narrow that fresh plan.

## Known limits (v0)

- **Quitting during a cleanup** (⌘Q, or closing the window) sends cmm the same stop request as the Stop button and the
  app exits at once, so cmm has nobody to report to. It finishes the item it is on and ends; the broken pipe does not
  matter (cmm ignores SIGPIPE in `--json` mode), and its log and last-run stamp are written as usual. You just do not
  see the result screen; press Stop and wait if you want it.
- The app is built for the architecture of the Mac that builds it (no universal binary) and is signed ad hoc.
- The scan and the cleanup each run one `cmm` at a time; the window offers no way to start a second.

## Using another cmm: `CMM_BIN`

The app runs `Cmm.app/Contents/Resources/cmm`. While developing, `CMM_BIN` points it elsewhere. A Finder-launched app
does not see your shell's environment, so pass it on:

```sh
open --env CMM_BIN=/path/to/cmm build/Cmm.app
# or run the executable directly
CMM_BIN=/path/to/cmm build/Cmm.app/Contents/MacOS/Cmm
# or without a bundle
CMM_BIN=/path/to/cmm swift run Cmm
```

A `CMM_BIN` that does not point at an executable is an error screen, not a silent fallback to the bundled copy.
cmm is always started with `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (a Finder-launched
app has a minimal `PATH`, and the Homebrew rule needs `brew`).

## Tests

```sh
swift test
```

They cover decoding `plan --json` fixtures (unknown fields, a schema mismatch), the selection model (tri-state,
totals, defaults by tier), the NDJSON parser (events split at every byte, several per chunk, a bad line, an oversized
line), the view-model state machine with a fake client (scan, confirm, clean, stop, errors, empty), each safety
rule, the process client against `Tests/CmmKitTests/Fixtures/fake-cmm.sh` (a stand-in `cmm` that speaks the contract:
incremental delivery, SIGINT, a failing item, a fatal error, the selection file's mode and removal), and rendering of
every screen in light and dark. Set `CMM_SNAPSHOT_DIR=/some/folder` to keep the rendered pictures.

Two tests run a real `cmm` and are skipped unless asked for, always in a fake home (fake `HOME` and `TMPDIR`, fake
`brew` and `xcrun` first on `PATH`):

```sh
# read-only: decode a real `cmm plan --json`
CMM_BIN=/path/to/cmm swift test --filter RealCmmTests
# a real apply in the fake home; needs a cmm that has `apply --select-file`
CMM_BIN=/path/to/cmm CMM_SANDBOX_APPLY=1 swift test --filter RealCmmTests
```

The apply test refuses to start (and fails) unless cmm's fresh plan consists only of `delete` items inside the fake
home: cmm asks `getconf` for the real temp folder and appends Homebrew's folders to `PATH` itself, so a fake `HOME`
alone does not make a run airtight. Not covered by any test here: the look and feel of the live window (the render
tests only prove that each screen draws in both appearances), clicking through the real window (the sheet, Stop, the
popover, ⌘R, quitting mid-clean) and VoiceOver. That Cancel is the sheet's default button is checked by reading the
source, not by pressing Return.

## Layout

```
Package.swift            CmmKit (library), Cmm (the SwiftUI app), CmmKitTests
build-app.sh             builds and signs build/Cmm.app
Sources/CmmKit/          models, NDJSON parser, selection model, process client, view model (no UI code)
Sources/Cmm/             the SwiftUI app (CmmApp.swift holds the app lifecycle)
Tests/CmmKitTests/       tests, Fixtures/ (hand-written plan and event samples, fake-cmm.sh)
```

The contract between the app and cmm (the JSON and NDJSON it reads, the exit statuses, SIGINT) is in
[conductor/tracks/app_v0_20261015/spec.md](../../conductor/tracks/app_v0_20261015/spec.md).
