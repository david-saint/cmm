# Tech Stack - cmm

## Primary Language
- **Go (Golang):** Chosen for its excellent performance, static typing, and suitability for building cross-platform (macOS focused) system utilities.

## CLI Framework & Tools
- **Cobra:** The standard-bearer for building Go CLI applications, providing a robust structure for commands, subcommands, and flags.
- **Bubble Tea (The Elm Architecture):** A powerful framework for building interactive terminal user interfaces (TUIs).
- **Lip Gloss:** For defining terminal styles, colors, and layouts with a CSS-like approach.
- **Bubbles:** A library of common TUI components (spinners, text inputs, viewports) for Bubble Tea.

## System Interaction
- **`pkg/sys` Runner:** Every external tool (`lsof`, `pgrep`, `xcrun simctl`, `plutil`, `brew`, `getconf`) is started through one `Runner` that tests replace with a fake. Only `pkg/sys` imports `os/exec`; the one listed exception is the manual Time Machine module (`tmutil`).
- **Deleting:** Only `pkg/engine` deletes or moves files, after the policy, the rule's own claim, the symlink checks and the guards. Both boundaries are enforced by a test that reads the source.
- **State:** The cleanup log, the last-run stamp, the history of runs (`history.jsonl`) and the free-space samples (`free.jsonl`) live in `~/.local/state/cmm/` (written by `pkg/engine`; the history and samples are only ever read to be shown).
- **macOS Native APIs (if needed):** Leveraging `cgo` or specific Go packages if direct system calls are required for better efficiency or safety.

## Packages
- `pkg/sys` (+`systest`): `Runner`, `Env` (home, per-user temp dir, clock), sandbox for tests.
- `pkg/sizer`, `pkg/guard`, `pkg/policy`: allocated sizes; in-use, process and recency guards; target validation.
- `pkg/rules`: the `Rule` interface and the built-in rules.
- `pkg/engine`: `Plan`, `Apply`, the JSON schema, the journal (log and last-run stamp), the history (runs and free-space samples, `cmm history`).
- `pkg/cmm`, `pkg/ui`: the interactive layer behind `cmm run` (module interface, executor, Bubble Tea screen). The engine's groups reach it through an adapter in `cmd`; `pkg/modules` holds only the manual Time Machine module.

## macOS app (`app/macos`)
- **SwiftUI** (Swift 6, macOS 14+) as a Swift package: `CmmKit` (models, process client, view model; no UI code), `Cmm` (the app), `CmmKitTests` (XCTest). No third-party dependencies. `build-app.sh` builds the Go engine into the bundle, builds the app, assembles `Cmm.app` and signs it ad hoc. The app only starts `cmm` (`plan --json`, `apply --yes --json --select-file`) and never deletes anything itself.

## Testing & Quality
- **Go Testing Framework:** Standard `testing` package for unit and integration tests.
- **Sandboxed tests:** Tests never touch real files: they use a fake home, temp dir, command runner and clock, and the engine panics instead of deleting or writing outside a temporary directory while a test runs.
- **Testify:** Not used; assertions are plain Go.

## Changes
- **2026-10-14 (track engine_v2_20261014):** `github.com/mattn/go-isatty` is now a direct dependency. It is the
  terminal check behind the no-human-no-deletion guard in `cmm apply` (`/dev/null` and pipes must not count as
  terminals). New internal packages: `pkg/sys` (+`systest`), `pkg/sizer`, `pkg/guard`, `pkg/policy`, `pkg/rules`,
  `pkg/engine`. Tests use the standard library only (Testify is not used).
- **2026-10-15 (track app_v0_20261015):** `pkg/sys` looks tools up on a PATH extended with Homebrew's folders;
  `cmm apply` gains `--select-file` and `--json` (NDJSON events) for apps; `app/macos` is the SwiftUI app.
- **2026-10-15 (Docker, option A chosen by the owner):** `pkg/rules` gains the `docker` rule (review tier, command
  items sized by `docker system df`); `pkg/engine` gains `Plan.SafeOnly`; `cmm apply` takes review items only when
  chosen (`--include-review`, `--only`, `--select-file`); `pkg/sys` gains `IsNotFound` so rules never import `os/exec`.
- **2026-10-15 (same track, Phase 3):** `cmm run` runs on the engine's plan and is a preview unless `--apply`. The
  Caches, Logs, Xcode and Homebrew modules are removed (their rules live in `pkg/rules`); `pkg/modules` keeps only
  Time Machine. `pkg/cmm`'s `Module.Delete` now returns a `DeleteResult` (freed, skipped, failed, notes) and the
  executor tries every module. `pkg/engine` gains the journal (`Engine.Journal`, wired only for real use).
