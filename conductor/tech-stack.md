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
