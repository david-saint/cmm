# Product Guide - cmm (macOS Cleanup & Maintenance)

## Product Vision
`cmm` is a Go command-line tool that simplifies and automates macOS maintenance for developers. It finds what can safely go, shows it, and removes it only with a person's say-so. Cleanups are rules in a guarded engine, so the same plan can be read by a person, by a script (`--json`) and, later, by an app.

## Target Audience
- **Advanced Users & Developers:** Seeking automation for tedious tasks like clearing Xcode derived data, package-manager caches or idle project dependencies.
- **General macOS Users:** Looking for a trustworthy, guided experience to safely free up storage.
- **System Administrators:** Needing a reliable tool for maintaining the health of Mac fleets.

## Core Goals
- **Disk Space Recovery:** Efficiently target heavy, regenerable data: package-manager and build caches, stale Xcode build output, idle lane dependencies, unavailable simulators, old tool versions, Homebrew leftovers.
- **Safe by Construction:** A path is deletable only if a rule claims it and the policy accepts it; it is checked again right before deletion; guards that cannot answer mean "skip"; nothing is deleted without a person at a terminal.
- **Transparency:** Show what would go, why, how big it really is, and which guard refused what.
- **Machine-Readable:** A versioned JSON plan (`cmm plan --json`) for scripts, the weekly reminder and the future app.

## Key Features
- **Plan:** `cmm plan` lists what each rule would remove, with honest sizes, tiers and the guards that made a rule skip something. It never deletes or writes anything.
- **Tiers:** Safe items (regenerable caches and build output) are what a plain apply takes. Review items (Docker's prunes for unused images, stopped containers and build cache) are listed under "needs your choice" and are taken only when chosen on purpose, never unattended.
- **Apply:** `cmm apply` shows the plan and waits for Return; `--dry-run` stops after the plan; `--only` limits it to some rules; `--yes` is the deliberate unattended mode.
- **Interactive Mode:** `cmm run` is the terminal screen on the same plan: pick groups, expand accordion-style lists of every path with its size (sorted by size), and, with `--apply`, confirm with a typed `y`. Without `--apply` it is a preview.
- **macOS app (v0):** `app/macos` is a small SwiftUI window on the same engine: it shows the plan, lets the owner tick items and cleans exactly those through `cmm`, with a confirmation sheet and a Stop button. It never deletes anything itself.
- **Record:** Every real apply logs each deleted or failed item and stamps the time of the last cleanup (`~/.local/state/cmm/`); `plan`, `apply` and `run` say how long ago it was.
- **Time Machine (manual):** Local snapshots are offered only in `cmm run`, flagged "Harsh", and are never part of the plan.
- **Safety Warnings:** High-visibility warnings for "Harsh" modules.

## Safety & Trust
- **Explicit Confirmation:** Return at the `apply` prompt, or a typed `y` in `run --apply`; anything else cancels or goes back. Without a terminal, `apply` and `run --apply` refuse.
- **Re-Checks:** Policy, rule claim, symlinks and guards are asked again for every item right before it is removed; a changed item is skipped with a reason.
- **Errors Do Not Abort:** Every item is attempted; failures are reported and the exit status says so.
- **Execution Summaries:** Clear reporting of what was really freed, skipped and failed, and the free space before and after, never the planned size presented as the result.

## User Experience (UX)
- **Guided & Educational:** Provides context and clear warnings, explaining the *why* and *how* behind each cleanup step.
- **Modern Terminal UI:** Interactive menus and spinners for a polished, professional feel.
- **Enhanced Navigation:** Intuitive navigation flow allowing users to move forward and back through the cleanup stages seamlessly.
