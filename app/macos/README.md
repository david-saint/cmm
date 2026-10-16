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
- **At rest** it says how much is safe to remove ("8.4 GB is safe to remove.", one sentence about what that is) for
  as long as everything safe is ticked and nothing from review is, with one pill, **Clean 8.4 GB…**, for what is
  ticked right now, and, when cmm found anything that needs a person's look (Docker), a link **Review 9.0 GB more ›**
  that opens the pane on it, on the map. With any other selection the headline follows the ticks: "3.9 GB will go.",
  the number on the pill, and under it what else there is, "4.5 GB more is safe to remove. Docker's 9.0 GB is yours to
  review." (a clause is left out when it is zero; "0 GB will go." with nothing ticked, and the pill is off). The band
  at the bottom shows the disk: used,
  review (dotted), safe to remove (green), free (outlined), with "19.8 GB free now → 28.2 GB after" and, when the
  guards held something back, one line saying what and why. When cmm reports no disk size (`host.capacity_bytes` is
  optional) there is no band; the free-space caption stays. While items that free their space *inside another
  program's storage* are ticked (Docker's prunes: cmm marks them `frees_inside`), the pill and "will go" still count
  them, because they will be removed, but "after" and the green slice do not, and one quiet line under the band says
  so: "+ 6.2 GB inside Docker's disk image, not counted above."
- **Details** (⌘I, or **Show details** at the top right) slides a 452 pt glass pane in from the right and the headline
  steps aside to the left. The pane lists **Safe to remove** (round checkboxes, ticked; a group opens to its items,
  and to the one-line note under it such as "Rebuild with npm ci or pod install."), **Review first** (never ticked for
  you; "Volumes are never offered.") and **Held back** (what the guards skipped, and why; nothing there can be
  ticked). Under the title, **List | Map** switches the pane between that list and the map (below); the first open
  shows the map and after that the face last used is remembered. The pill, the headline once the ticks are not the
  default, and the "after" of the band follow what is ticked, and a ticked review item adds to what will go but never
  to what is safe.
- **The map** is everything cmm found, drawn as a squarified treemap in the pane: a tile per item, as big as its bytes
  (Docker's three prunes are one tile that ticks all three; the list's expanded rows stay the place to tick them one by
  one). Safe tiles are green, a little when not ticked and more when ticked; review tiles have a dotted amber edge and
  no fill until ticked; each has the list's round checkbox, and ticking in the map or in the list shows in both, in
  the pill, the headline, the band and the card. What a tile writes depends on its size (the name and size from
  96 x 56 pt, the size alone from 44 x 28, the badge alone from 28 x 28; smaller tiles are fill only and are reached by
  hovering, the arrow keys, Space or VoiceOver). One caption under the map follows the keyboard focus, or the tile under
  the pointer when nothing is focused.
- **The band is the doorway to the map.** Hovered, and for as long as the map is open, it is 10 pt thick and its
  reclaimable end is drawn five times as wide, one slice per tile, under a bracket and a caption that say it is
  enlarged ("17.4 GB reclaimable, enlarged ×5": a band that is bigger than the disk's truth always says so). The
  pointer names the slice it is on, a click on a slice opens the map on that tile, a hovered or focused tile lights or
  rings its slice, and the slices of the band lift off and grow into the tiles, largest first, as the pane slides in
  (and fold back when it closes). A band whose capacity is unknown has no end to enlarge.
- **Cleans** the ticked items: the pill opens a card that grows out of it ("Delete 9 items (8.4 GB)? Each item is
  checked again right before it is removed. Free space afterwards: about 28.2 GB.", and when Docker's items are
  ticked, "6.2 GB is freed inside Docker's disk image. The disk shows it later, if at all."). **Cancel** is the
  filled default on the left, so Return and Esc cancel; the red **Delete 9 Items** has no shortcut. Behind the card
  the screen is dimmed, disabled and hidden from VoiceOver, which is also what keeps the keyboard inside the card.
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
move through the list's rows, **→ ←** open and close a group, **Space** ticks the focused row, **Return** presses the
card's Cancel. On the map **↑ ↓ ← →** move to the neighbouring tile, **Home** and **End** to the first and last,
**Space** and **Return** tick the focused tile, and a click on a tile focuses it as well as ticking it. The menu
commands and the map's arrows are key equivalents, so they work wherever the focus is (without Full Keyboard Access no
button can take it); Space and Return are the map's own, once it has the keyboard: the review link, a click on a
slice or a tile, or the first arrow gives it. Behind the card none of them does anything.

Light and dark follow the system. **Increase Contrast** gives the hairlines, rings, dotted strokes and quiet text
stronger colours; **Reduce Motion** turns the springs (the pane, the card, the slices' flight) into 0.2 s crossfades
and enlarges the band's end without animation; **VoiceOver** reads the band as one sentence ("Disk 228 GB: 19.8 GB
free, 8.4 GB safe to remove, 9.0 GB needs your review", with a **Show the map** action), the map as a group
"Reclaimable space map" of buttons ("lane-a node_modules, 1.4 GB, safe to remove, ticked"; "Docker, 9.0 GB, review, not
ticked") that tick when pressed, the list as the full representation, each row and button has a label, and nothing is
carried by color alone. On macOS 26 the pane and the card sit on Liquid Glass; on
macOS 14 and 15 on a blurred material with the same tint.

## What it does not do

No history, menu bar item, notifications, Claude panel, administrator or `sudo` flows, Time Machine snapshots or
Trash handling, and no scan of the home folder: the map is today's plan, not a disk usage browser. It does not read
file contents (only paths, sizes and notes from cmm), does not write anything except one temporary file per cleanup
(below) and, as the one thing it remembers, which face of the pane was last used (`FacePreference.swift`: one
`UserDefaults` key, `detailsFace`), and starts no program but `cmm`. The one other thing it asks the system for is to show a path in
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

- **Docker's space is in what is removed, not in what is freed.** A prune frees space inside Docker's own disk image,
  which the Mac only gets back when Docker shrinks it. The pill and the card's "Delete N items (X GB)?" count it (it
  is what is removed); "after", the green slice, "freed so far" and "freed" do not (it is not what the disk gets), and
  the place's name is cmm's `frees_inside`, word for word. The pane's rows for such items say what runs and where the
  space goes.
- **The running item is inferred.** cmm sends no event when it starts an item, so the "Removing" row is the next item
  of the selection in cmm's order; it is replaced by the real result when the item event arrives.
- **Held back** also lists groups the app cannot offer (a tier it does not know, items that need a person), with the
  reason, and they cannot be ticked.
- **Quitting during a cleanup** (⌘Q, or closing the window) sends cmm the same stop request as the Stop button and the
  app exits at once, so cmm has nobody to report to. It finishes the item it is on and ends; the broken pipe does not
  matter (cmm ignores SIGPIPE in `--json` mode), and its log and last-run stamp are written as usual. You just do not
  see the result screen; press Stop and wait if you want it.
- **The map's tiles follow the plan's bytes alone**, so ticking never moves one. A tiny item is given a larger share
  than its bytes (under 0.2 % of the total, and, in a plan of up to 300 tiles, until its tile is 16 pt on each side) so
  that it can be pointed at: the areas of the smallest tiles are therefore a little out of proportion.
- **The slice under a band that is not hovered cannot be clicked**: a thin band is not a button. The slices are
  invisible buttons that exist while the end is enlarged, and the pointer's hover over them (the label naming a
  slice) is SwiftUI's own, which only a real pointer drives.
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
tokens' WCAG contrast in all four looks, and the screens drawn in light, dark and Increase Contrast. For the map: the
treemap against a reference and the board's own tile rectangles, the tiles and what they write by size, the caption's
rule, the arrows' spatial navigation, the band's magnified end and its slices, the flights' schedule and clock (the
spring is compared with SwiftUI's own `Spring`), the headline's states, and, through a real window kept off every
screen, the keys, the clicks and VoiceOver's presses on the real views, and the accessibility tree they leave
(`MapInteractionTests`, `MapAccessibilityTests`).

Set `CMM_SNAPSHOT_DIR=/some/folder` to keep the rendered pictures: every screen of design C as a 1100 x 720 PNG, in
light and dark (`rest`, `restReview`, `restNothingTicked`, `details`, `detailsExpanded`, `map`, `mapDockerFocused`,
`bandHovered`, `unfoldMid`, `sheet`, `cleaning`, `done`, `doneProblems`, `empty`, `scanning`, `errorScan` ...), and with
Increase Contrast (`*-light-contrast.png`); the flights are drawn frozen at a moment (`unfoldEarly`, `unfoldMid`,
`unfoldLate`, `foldMid`):

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

Not covered by any test here: the pointer hovering (SwiftUI's hover and tap gestures only answer the real pointer;
buttons, which the tiles and the band's slices are, answer a synthetic click, and those are tested), the feel of the
flights (they are tested as numbers and drawn frozen), VoiceOver itself (its tree and its presses are tested, not its
speech), and, in the real window, the card, Stop, ⌘R and ⌘I from the menu and quitting mid-clean. That Cancel is the
card's default button, and that Delete has no shortcut, is checked by reading the source, not by pressing Return. The running window was looked at once, in dark mode, on the Mac
that built the app (`screencapture -l` of the rest, scanning and error screens and of the open pane, which showed
the same geometry as the pictures, on Liquid Glass); light mode, the system's own Increase Contrast and Reduce
Motion switches, the card, the cleaning and done screens in the live window and the macOS 14 and 15 material
fallback were not run live.

## Layout

```
Package.swift            CmmKit (library), Cmm (the SwiftUI app), CmmKitTests
build-app.sh             builds and signs build/Cmm.app
Sources/CmmKit/          models, NDJSON parser, selection model, process client, view model, and the pure types
                         the screens are made from (band, copy, headline, rows, layout, placement, navigation, the
                         treemap, the map's tiles and keys, the band's magnifier, the flights); no UI code
Sources/Cmm/             the SwiftUI app: CmmApp (lifecycle, menu), RootView (screens, the card), RestScreen,
                         DetailsPane/DetailsRows, FaceSwitch and FacePreference (List | Map, and the one thing
                         remembered), MapFace/MapTileView, ConfirmCard, StatusScreens (cleaning, done, empty,
                         scanning, errors), BandViews (the band and its doorway), FlightOverlay, Hero, Design/
                         (Theme: colour tokens and type; Primitives: pills, checkmarks, dots, glass, spinner)
Tests/CmmKitTests/       tests, Fixtures/ (hand-written plan and event samples, fake-cmm.sh)
```

The contract between the app and cmm (the JSON and NDJSON it reads, the exit statuses, SIGINT) is in
[conductor/tracks/app_v0_20261015/spec.md](../../conductor/tracks/app_v0_20261015/spec.md).
