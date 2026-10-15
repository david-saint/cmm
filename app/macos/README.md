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
`swift build -c release`, compiles the app icon (`Icon/AppIcon.icon`, see [Icon/README.md](Icon/README.md)) with
`actool`, assembles `build/Cmm.app` (bundle id `com.davidsaint.cmm`, name "cmm", macOS 14+) and signs
it with `codesign --sign -` (no developer account; the app is meant to run on the Mac that built it). It can be run
again at any time and only ever replaces its own `build/Cmm.app`. Without Go on `PATH` it stops and says so; it never
runs `go install`.

## What it does

The window is design "C" of the owner's boards: one calm number, one pill, one link and a thin disk band. Everything
else is in a pane that slides in on request.

- **Scans** on start with `cmm plan --json` (10 to 20 seconds; big folders are sized).
- **At rest** it says how much is safe to remove ("8.4 GB is safe to remove.", one sentence about what that is), with
  one pill, **Clean 8.4 GB…**, for what is ticked right now, and, when cmm found anything that needs a person's look
  (Docker), a link **Review 9.0 GB more ›** that opens the pane on it. The band at the bottom shows the disk: used,
  review (dotted), safe to remove (green), free (outlined), with "19.8 GB free now → 28.2 GB after" and, when the
  guards held something back, one line saying what and why. When cmm reports no disk size (`host.capacity_bytes` is
  optional) there is no band; the free-space caption stays. While items that free their space *inside another
  program's storage* are ticked (Docker's prunes: cmm marks them `frees_inside`), the pill still counts them, because
  they will be removed, but "after" and the green slice do not, and one quiet line under the band says so: "+ 6.2 GB
  inside Docker's disk image, not counted above."
- **Details** (⌘I, or **Show details** at the top right) slides a 452 pt glass pane in from the right and the headline
  steps aside to the left. The pane lists **Safe to remove** (round checkboxes, ticked; a group opens to its items,
  and to the one-line note under it such as "Rebuild with npm ci or pod install."), **Review first** (never ticked for
  you; "Volumes are never offered.") and **Held back** (what the guards skipped, and why; nothing there can be
  ticked). The big number is always the safe total, whatever is ticked; the pill, and the "after" of the band, follow
  what is ticked, and a ticked review item adds to them but never to the big number.
- **Cleans** the ticked items: the pill opens a card that grows out of it ("Delete 9 items (8.4 GB)? Each item is
  checked again right before it is removed. Free space afterwards: about 28.2 GB.", and when Docker's items are
  ticked, "6.2 GB is freed inside Docker's disk image. The disk shows it later, if at all."). **Cancel** is the filled default
  on the left, so Return and Esc cancel; the red **Delete 9 Items** has no shortcut. Behind the card the screen is
  dimmed, disabled and hidden from VoiceOver, which is also what keeps the keyboard inside the card.
- **While it cleans**, a list shows each item as cmm finishes it (removing, deleted, skipped, failed) under a running
  total of what the disk has got back ("3.1 GB freed so far"), with **Stop**, which asks cmm to finish the item it is
  on and end. What went inside another program's storage is a quiet line apart ("+ 2.1 GB inside Docker's disk
  image"), never in "freed" or "free now".
- **Done** says what is free now ("25.2 GB free now. Up from 19.8 GB. 5.2 GB freed." with cmm's `freed_bytes`, the
  disk's share), and, when `freed_inside_bytes` is more than zero, what went inside and that the disk shows it when
  that space is given back. It counts what was deleted, skipped and failed, names up to three of the items that did
  not go (with **Show in Finder**; "and 4 more skipped or failed." for the rest) and where cmm's log is, and offers
  **Done** and **Rescan** (both scan again; there is nothing else to go back to).
- **Nothing to clean**, **scanning** and the **error screens** (cmm not found, plan failed, unreadable plan, "this app
  reads schema 1", a failed or stopped cleanup) are in the same language.

Keyboard: **⌘R** Rescan, **⌘I** Show or Hide details, **Esc** cancels the card, otherwise closes the pane, **↑ ↓**
move through the pane's rows, **→ ←** open and close a group, **Space** ticks the focused row, **Return** presses the
card's Cancel. The first two are menu commands, so they work wherever the focus is.

Light and dark follow the system. **Increase Contrast** gives the hairlines, rings, dotted strokes and quiet text
stronger colours; **Reduce Motion** turns the springs (the pane, the card) into crossfades; **VoiceOver** reads the
band as one sentence ("Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB needs your review"), each row and
button has a label, and nothing is carried by color alone. On macOS 26 the pane and the card sit on Liquid Glass; on
macOS 14 and 15 on a blurred material with the same tint.

## What it does not do

No reclaimable-space map (the title row of the pane leaves room for a future List | Map switch), history, menu bar
item, notifications, Claude panel, administrator or `sudo` flows, Time Machine snapshots or Trash handling. It does
not read file contents (only paths, sizes and notes from cmm), does not write anything except one temporary file per
cleanup (below), and starts no program but `cmm`. The one other thing it asks the system for is to show a path in
Finder (**Show in Finder** on the done screen, for a failed item and the log); `FinderReveal.swift` is the only place
that talks to the workspace, and it changes nothing.

## Safety rules (each has tests)

1. The app never deletes, moves or writes outside its own temporary files; it only starts `cmm`.
2. It passes only paths that appeared in the last plan. `Plan` and its items cannot be built outside `CmmKit`, and
   `ApplySelection` keeps only paths of the plan it is given.
3. `cmm apply --yes` runs only after the pill and then the card's Delete; Cancel, Esc (or a stale or forged
   confirmation) runs nothing. `AppModel.confirmClean` is the only way to `apply`, and it is called from one place:
   the card's Delete button. Review items are in a selection only when the person ticked them.
4. The ticked paths travel to `cmm apply --select-file` in a file of mode 0600, in a folder of mode 0700, in the app's
   temporary folder. The file is removed as soon as cmm has read it (its `start` event), at the latest when the run
   ends (also on errors), and at once when you press Stop or quit. Only a crash or a force quit in the first seconds of
   a run (cmm plans again before its `start` event) can leave one behind; it holds paths and nothing else.
5. It shows metadata, never file contents.
6. Tests never run a real clean on the real disk.

cmm itself plans again before applying and re-checks every item right before removing it; a selection can only
narrow that fresh plan.

## Known limits

- **Docker's space is counted twice over, on purpose.** A prune frees space inside Docker's own disk image, which the
  Mac only gets back when Docker shrinks it. The pill and the card's "Delete N items (X GB)?" count it (it is what is
  removed); "after", the green slice and "freed" do not (it is not what the disk gets), and the place's name is
  cmm's `frees_inside`, word for word. The "Removing" row's note and the review row say what runs.
- **The running item is inferred.** cmm sends no event when it starts an item, so the "Removing" row is the next item
  of the selection in cmm's order; it is replaced by the real result when the item event arrives.
- **Held back** also lists groups the app cannot offer (a tier it does not know, items that need a person), with the
  reason, and they cannot be ticked.

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

They cover decoding `plan --json` fixtures (unknown fields, a schema mismatch, the optional `capacity_bytes`), the
selection model (tri-state, totals, defaults by tier, held and manual items that cannot be ticked), the NDJSON parser
(events split at every byte, several per chunk, a bad line, an oversized line), the view-model state machine with a
fake client (scan, confirm, clean, stop, errors, empty), each safety rule (some by reading the app's source), the
process client against `Tests/CmmKitTests/Fixtures/fake-cmm.sh` (a stand-in `cmm` that speaks the contract:
incremental delivery, SIGINT, a failing item, a fatal error, the selection file's mode and removal), and, for design C,
the pure types the views are made from: the band's segments and words, the headline and its copy, the pane's rows
and their VoiceOver strings, the layout numbers of the boards, the card's placement, what Esc closes, the colour
tokens' WCAG contrast in all four looks, and the screens drawn in light, dark and Increase Contrast.

Set `CMM_SNAPSHOT_DIR=/some/folder` to keep the rendered pictures: every screen of design C as a 1100 x 720 PNG, in
light and dark (`rest`, `restReview`, `details`, `detailsExpanded`, `sheet`, `cleaning`, `done`, `doneProblems`,
`empty`, `scanning`, `errorScan` ...), and with Increase Contrast (`*-light-contrast.png`):

```sh
mkdir -p /tmp/c-snap && CMM_SNAPSHOT_DIR=/tmp/c-snap swift test --filter AppViewsTests
```

Offscreen rendering (`NSView.cacheDisplay`) draws a layer's shadow offset upside down, so the render tests set
`ViewEnvironment.shadowDirection` to -1 and the pictures show shadows where the window does. A window's appearance
cannot turn the system's Increase Contrast switch on either, so the tests set `cmmIncreasedContrast` in the
environment; in the app it is SwiftUI's own `colorSchemeContrast` that selects the stronger colours.

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
alone does not make a run airtight.

Not covered by any test here: clicking through the real window (the pane, the card, Stop, ⌘R and ⌘I from the menu,
quitting mid-clean) and VoiceOver. That Cancel is the card's default button, and that Delete has no shortcut, is
checked by reading the source, not by pressing Return. The running window was looked at once, in dark mode, on the Mac
that built the app (`screencapture -l` of the rest, scanning and error screens and of the open pane, which showed
the same geometry as the pictures, on Liquid Glass); light mode, the system's own Increase Contrast and Reduce
Motion switches, the card, the cleaning and done screens in the live window and the macOS 14 and 15 material
fallback were not run live.

## Layout

```
Package.swift            CmmKit (library), Cmm (the SwiftUI app), CmmKitTests
build-app.sh             builds and signs build/Cmm.app
Sources/CmmKit/          models, NDJSON parser, selection model, process client, view model, and the pure types
                         the screens are made from (band, copy, rows, layout, placement, navigation); no UI code
Sources/Cmm/             the SwiftUI app: CmmApp (lifecycle, menu), RootView (screens, the card), RestScreen,
                         DetailsPane/DetailsRows, ConfirmCard, StatusScreens (cleaning, done, empty, scanning,
                         errors), BandViews, Hero, Design/ (Theme: colour tokens and type; Primitives: pills,
                         checkmarks, dots, glass, spinner)
Tests/CmmKitTests/       tests, Fixtures/ (hand-written plan and event samples, fake-cmm.sh)
```

The contract between the app and cmm (the JSON and NDJSON it reads, the exit statuses, SIGINT) is in
[conductor/tracks/app_v0_20261015/spec.md](../../conductor/tracks/app_v0_20261015/spec.md).
