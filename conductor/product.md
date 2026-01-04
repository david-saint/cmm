# Product Guide - cmm (macOS Cleanup & Maintenance)

## Product Vision
`cmm` is a modern, interactive Go-based command-line tool designed to simplify and automate macOS system maintenance. It empowers users—from casual owners to power developers—to reclaim disk space and optimize performance through guided, safe, and customizable cleanup workflows.

## Target Audience
- **Advanced Users & Developers:** Seeking automation for tedious tasks like clearing Xcode derived data or Homebrew caches.
- **General macOS Users:** Looking for a trustworthy, guided experience to safely free up storage.
- **System Administrators:** Needing a reliable tool for maintaining the health of Mac fleets.

## Core Goals
- **Disk Space Recovery:** Efficiently target and remove heavy local snapshots, backups, and caches.
- **Performance Optimization:** Refresh system state by clearing bloated logs and temporary files.
- **Customizable Control:** Offer flexible "flows" (Quick, Deep, Custom) to suit different needs and risk tolerances.

## Key Features
- **Automated Modules:** Specialized logic for Time Machine snapshots, User caches, Xcode Derived Data, System logs, and Homebrew artifacts.
- **Interactive Mode:** A rich terminal interface allowing users to hand-pick tasks or choose predefined maintenance paths.
- **Dry Run Capability:** Transparency through previews, showing exactly what will be deleted before any action is taken.
- **Detailed File Previews:** Interactive accordion-style lists showing the path, size, and type of every file targeted for deletion, sorted by size.
- **Safety Warnings:** High-visibility warnings for "Harsh" cleanup modules.

## Safety & Trust
- **Mandatory Confirmations:** Explicit user approval required for any destructive operations.
- **Safety First Checks:** Integrated verification of system status to prevent accidental data loss.
- **Execution Summaries:** Clear reporting on actions taken, files removed, and total space reclaimed.

## User Experience (UX)
- **Guided & Educational:** Provides context and clear warnings, explaining the *why* and *how* behind each cleanup step.
- **Modern Terminal UI:** Utilizes interactive menus, progress bars, and spinners for a polished, professional feel.
- **Enhanced Navigation:** Intuitive navigation flow allowing users to move forward and back through the cleanup stages seamlessly.
