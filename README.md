# 🧹 cmm: macOS Cleanup & Maintenance

[![Go Version](https://img.shields.io/github/go-mod/go-version/david-saint/cmm)](https://golang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **"Because your Mac deserves a spa day."** ✨

`cmm` is a modern, interactive, Go-powered terminal utility designed to help you reclaim disk space and keep your macOS running like new. No more hunting through `/Library/Caches` or manually purging Time Machine snapshots. `cmm` does the heavy lifting with a polished TUI that makes system maintenance... dare we say, _fun_?

---

## 🚀 Key Features

- 📸 **Time Machine Purge:** Say goodbye to those bloated local snapshots.
- 🛠️ **Xcode Detox:** Clear out `DerivedData` and old simulators with one click.
- 🍺 **Homebrew Hygiene:** Cleanup old cellar versions and cache files.
- 🧹 **Cache & Log Crusher:** Target deep system and user caches safely.
- 🕵️ **Interactive Previews:** See exactly what's being deleted before you pull the trigger.
- 🎨 **Beautiful TUI:** Built with [Bubble Tea](https://github.com/charmbracelet/bubbletea) for a premium terminal experience.

---

## 📦 Installation

To get started, you'll need [Go](https://go.dev/doc/install) installed on your system.

### Recommended (via `go install`)

The easiest way to install `cmm` is via `go install`:

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
   go build -o cmm main.go
   ```

---

## 🛠 Usage

Run the tool interactively:

```bash
cmm run
```

### Tips

- Use the **arrow keys** to navigate.
- Press **Space** to select/deselect modules.
- Hit **Enter** to confirm your cleanup path.
- Look out for **Safety Red** warnings on "Harsh" cleanup modules—we take your data seriously!

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

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

---

Built with ❤️ and plenty of ☕️ by David Saint.
