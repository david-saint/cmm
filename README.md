# 🧹 cmm: macOS Cleanup & Maintenance

[![Go Version](https://img.shields.io/github/go-mod/go-version/david-saint/cmm)](https://golang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **"Because your Mac deserves a spa day."** ✨

`cmm` is a Go command-line tool that reclaims disk space on a developer's Mac without guessing. Every cleanup is a **rule**: it names exactly what it may touch, checks that nothing is using it, and is checked again right before anything is removed. You can look first (`cmm plan`), script it (`cmm plan --json`), and nothing is ever deleted without a person at a terminal.

---

## 🚀 What it does

- 🔎 **`cmm plan`** shows what would go, how much space it frees, and which guards made it skip something. It never deletes and never writes anything.
- 🧾 **`cmm plan --json`** prints the same plan as one JSON document (`schema_version` 1) for scripts and apps.
- 🧹 **`cmm apply`** shows the plan, waits for you to press Return, then cleans. Without a terminal it refuses.
- 🖥️ **`cmm run`** is the interactive screen ([Bubble Tea](https://github.com/charmbracelet/bubbletea)) on the same plan. It is a preview unless you pass `--apply`.

### What it cleans

| Rule id | What | When it may go |
| --- | --- | --- |
| `go-build` | Go build cache | no `go` process |
| `npm-cache` | npm download cache | no `npm install`/`ci`/... running |
| `cocoapods` | CocoaPods cache | no `pod install`/`update` running |
| `bun-cache` | bun cache | no `bun install`/`add` running |
| `uv-cache` | uv cache | uv not running and not using it |
| `xcode-module-cache` | Xcode module and compilation caches | Xcode and its build tools not running |
| `deriveddata-stale` | Xcode `DerivedData` folders | untouched for 5+ days (or workspace gone for 3+ days), not in use, volume mounted |
| `lane-local-build` | stale Xcode build folders in `~/lane-builds` | same staleness rule |
| `lane-deps` | `node_modules` and `ios/Pods` of a lane in `~/lane-builds` | lane idle for 5+ days, not in use |
| `lane-build-output` | build output of a lane | lane idle for 5+ days |
| `jest-temp` | Jest temp cache | no `jest` process |
| `maestro-temp` | Maestro test output | older than 1 hour, no maestro or xcodebuild |
| `cursor-update` | Cursor's failed update (staged copy) | Cursor and its updater not running |
| `claude-versions`, `cursor-agent-versions` | old CLI versions | the newest, linked and in-use versions are kept |
| `simulators` | simulators whose runtime was removed | shut down, untouched for 3 days, not in use; removed with `simctl delete` |
| `homebrew` | old versions of installed formulae | `brew cleanup`, brew not running |

Time Machine local snapshots are **not** part of the plan. `cmm run` offers them as a separate, manual, "harsh" option (see below).

---

## 🛡️ How it stays safe

- **Allow-list, not deny-list.** A path can be deleted only if a rule claims it *and* the policy accepts it: inside your home folder or per-user temp folder, and never a broad folder such as `~`, `~/Library` or `~/Library/Caches`.
- **Checked again right before deleting.** The rule's claim, the policy, symlinks and the guards are asked again for every item. If anything changed since the plan, the item is skipped with a reason.
- **Never through a symlink.** No symlink may sit between the root and the target, or be the target.
- **Guards fail safe.** If `lsof` or `pgrep` cannot answer, the item is skipped, not deleted.
- **No human, no deletion.** `cmm apply` and `cmm run --apply` need a terminal. `apply` takes a plain Return (anything else cancels); `run` takes a typed `y` (`n` or Esc go back). `apply --yes` is the deliberate way to run unattended. Previews and `--dry-run` never delete, even in `apply --dry-run --yes` or `run --apply --dry-run`.
- **One failure never stops the rest.** Every item is attempted; failures are listed and the exit status is non-zero.
- **Honest sizes.** Allocated bytes on the same filesystem, hard links counted once.
- **Plans are metadata.** A plan holds paths, sizes, tiers and reasons, never file contents.

### The record of a cleanup

A real apply appends one line per deleted (or failed) item to `~/.local/state/cmm/cleanup.log` and, when something was cleaned, writes the time to `~/.local/state/cmm/last-run`. `plan`, `apply` and `run` then say `Last cleanup: 2026-10-14 (3 days ago)`. Plans, previews, dry runs and refusals write nothing. If the log cannot be written you get a warning; the cleanup still happens.

---

## 📦 Installation

To get started, you'll need [Go](https://go.dev/doc/install) installed on your system.

### Recommended (via `go install`)

```bash
go install github.com/david-saint/cmm@latest
```

### From Source

If you prefer to build it yourself or want to contribute:

1. **Clone the repository:**

   ```bash
   git clone https://github.com/david-saint/cmm.git
   cd cmm
   ```

2. **Build the binary:**
   ```bash
   go build -o cmm .
   ```

---

## 🛠 Usage

```bash
cmm plan                         # look: nothing is deleted
cmm plan -v                      # list every item, not just the biggest per group
cmm plan --json                  # the plan for scripts and apps

cmm apply --dry-run              # the plan, then stop
cmm apply                        # the plan, then press Return to clean
cmm apply --only go-build,npm-cache   # limit to some rule ids
cmm apply --select-file sel.json # limit to the item paths in a JSON file (can only narrow the plan)

cmm run                          # interactive preview
cmm run --apply                  # interactive; type y to clean
```

### Interactive mode

- Use the **arrow keys** to move and **Space** to select a group (or expand its items).
- **Enter** moves on: scan, results, and (with `--apply`) the question.
- Only a typed **`y`** confirms a deletion; Return never does.
- The finished screen reports what was really freed, skipped and failed.
- Time Machine snapshots appear last, flagged **Harsh**.

### JSON

`cmm plan --json` prints one document on stdout (`schema_version` 1: `generated_at`, `host`, `items`, `groups`, `skipped`, `total_bytes`). The format is described in the [engine track's spec](conductor/tracks/engine_v2_20261014/spec.md) and pinned by a golden test.

### For programs and apps

An app that shows the plan and lets a person tick items cleans through the same guarded engine:

```bash
cmm apply --yes --json --select-file selection.json   # selection.json: ["<path from the plan>", ...]
```

`cmm` plans again and keeps only the selected paths that are in that fresh plan, so **a selection can only narrow a plan, never widen it**; any other path is reported as skipped. Every item is still checked again right before it is removed. `--json` prints one event per line on stdout (`start`, one `item` per path, `done`) and nothing else; it needs `--yes` (the caller has a person's confirmation for exactly this selection) or `--dry-run`. The events are described in the [app track's spec](conductor/tracks/app_v0_20261015/spec.md).

`cmm` looks tools up on a `PATH` that includes `/opt/homebrew/bin` and `/usr/local/bin`, so a copy started from Finder still finds `brew`. A reader that goes away (an app quitting) does not stop a confirmed cleaning half way; `SIGINT` does.

### The app

`app/macos` holds a small SwiftUI app (macOS 14 or later) on top of that interface: it shows the plan, lets you tick what you want gone and cleans exactly that through `cmm`. It never deletes anything itself.

```bash
cd app/macos && ./build-app.sh && open build/Cmm.app
```

See [app/macos/README.md](app/macos/README.md) for what it does and does not do, its safety rules and its tests.

---

## 🤝 Contributing

We love contributions! `cmm` follows a strict **Test-Driven Development (TDD)** workflow managed via the `conductor` methodology.

### Development Workflow

1. **Pick a task:** Check the `conductor/tracks/` for open items.
2. **Red Phase:** Write a failing test in `pkg/` or `cmd/`.
3. **Green Phase:** Implement the minimum code to make it pass.
4. **Refactor:** Clean up your code while keeping the tests green.
5. **Coverage:** Ensure you hit at least **80% code coverage**.

Read the full [Workflow Guide](conductor/workflow.md) for more details.

### Ground rules for code that deletes

- **Tests never touch real files.** They build a sandbox (`pkg/sys/systest`) with a fake home, a fake temp folder, a fake command runner and a fixed clock. While a test binary runs, the engine panics instead of deleting (or writing its log) outside a temporary folder.
- **Boundaries are tested.** Only `pkg/sys` starts processes and only `pkg/engine` deletes files (the one listed exception is the manual Time Machine module); `pkg/engine/boundaries_test.go` reads the source and fails when that stops being true.
- **Never `go install` while developing:** it would overwrite the `cmm` you use. Build into a scratch folder instead (`go build -o /tmp/cmm-dev .`).

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

---

Built with ❤️ and plenty of ☕️ by David Saint.
