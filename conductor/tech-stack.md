# Tech Stack - cmm

## Primary Language
- **Go (Golang):** Chosen for its excellent performance, static typing, and suitability for building cross-platform (macOS focused) system utilities.

## CLI Framework & Tools
- **Cobra:** The standard-bearer for building Go CLI applications, providing a robust structure for commands, subcommands, and flags.
- **Bubble Tea (The Elm Architecture):** A powerful framework for building interactive terminal user interfaces (TUIs).
- **Lip Gloss:** For defining terminal styles, colors, and layouts with a CSS-like approach.
- **Bubbles:** A library of common TUI components (spinners, text inputs, viewports) for Bubble Tea.

## System Interaction
- **Internal Shell/Exec:** For executing native macOS commands like `tmutil`, `rm`, `du`, and `brew`.
- **macOS Native APIs (if needed):** Leveraging `cgo` or specific Go packages if direct system calls are required for better efficiency or safety.

## Testing & Quality
- **Go Testing Framework:** Standard `testing` package for unit and integration tests.
- **Testify:** For more expressive assertions and mocking.

## Changes
- **2026-10-14 (track engine_v2_20261014):** `github.com/mattn/go-isatty` is now a direct dependency. It is the
  terminal check behind the no-human-no-deletion guard in `cmm apply` (`/dev/null` and pipes must not count as
  terminals). New internal packages: `pkg/sys` (+`systest`), `pkg/sizer`, `pkg/guard`, `pkg/policy`, `pkg/rules`,
  `pkg/engine`. Tests use the standard library only (Testify is not used).
