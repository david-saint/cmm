# Track Spec: engine_v2_20261014

## Overview
Replace cmm's blunt, unguarded modules with a **rule-based cleanup engine** that plans, guards and applies
cleanups safely, reproduces the owner's `~/.local/bin/dev-cleanup` script exactly, and emits a stable JSON
plan. This is Milestone 1 of turning cmm into the engine behind a clickable macOS app with a Claude panel
(M2 app, M3 history/menu bar, M4 Claude panel are out of scope here).

## Why
- Today `cmm run` deletes every child of `~/Library/Caches` and the log folders with `os.RemoveAll`: no in-use
  check, no allow-list, no recency rule; one error aborts the whole run; dry-run is off by default; the
  advertised `--force` flag is parsed but never read (a no-op).
- Sizes come from `filepath.Walk` summing apparent file sizes: wrong for sparse files (Docker.raw reads 100 GB,
  uses 51 GB), hard links, and anything that crosses into a mounted volume.
- The safety lessons learned on the owner's Mac (see "Safety invariants") live only in a bash script.

## User Stories
- As the owner, I want `cmm plan` to show exactly what would be deleted and why, per group, with sizes and
  the guards that made it skip things, and `--json` for other tools.
- As the owner, I want `cmm apply` to be unable to delete anything without a human at a terminal (or an
  explicit `--yes`), and `--dry-run` to never delete.
- As the owner, I want every deletion limited to paths a rule claims, re-checked immediately before deleting.
- As the owner, I want parity with `dev-cleanup` so I can retire the script and let the weekly reminder call cmm.
- As a future app or Claude panel, I want a versioned JSON schema I can rely on.

## Safety Invariants (each one is a test)
1. **Allow-list, not deny-list.** A path is deletable only if some rule's `Allows` claims it AND
   `policy.ValidateTarget` accepts it; a path no rule claims is refused. The risk in Go is one rule's `Allows`
   being too broad, so every rule has negative tests for its parent, its siblings and nested paths.
2. **Policy backstop.** Targets must be absolute and clean (no `..`, no `//`), inside an allowed root
   (the user's home or per-user temp dir), not a broad directory (`/`, `/Users`, `$HOME`, `~/Library`,
   `~/Library/Caches`, `~/Library/Application Support`, `~/Documents`, `~/Desktop`, `~/Downloads`, ...),
   and the final element must not be a symlink.
3. **Re-check at apply time.** Immediately before each deletion: re-run `Allows`, `ValidateTarget`, the
   rule's process guards and the in-use check. If anything changed, skip with a reason.
4. **Guards fail safe.** `lsof`: exit 1 with empty stdout = not in use; non-empty stdout = in use; a spawn
   failure, a timeout or any other exit code = cannot answer, so the item is skipped. `pgrep`: exit 0 = running,
   exit 1 = none; exit 2 or more, or a spawn failure = cannot answer, so skip. Each case has a test on a fake runner.
    Platform note (verified 2026-10-14): BSD `pgrep` never reports ancestors of the calling process, so a tool
    that launched cmm (`go run`, `make`, a shell script) is invisible to the process guards. That is harmless for
    cleanup, but it means a guard cannot be demonstrated by running cmm under the very tool it guards.
5. **No human, no deletion.** `apply` without `--yes` requires stdin to be a terminal and a Return keypress;
   EOF or Ctrl-D cancels. `--dry-run` never deletes. `plan` never writes anything.
6. **Errors do not abort the run.** Every item is attempted; failures are reported and the exit code is non-zero.
7. **Honest sizes.** Allocated bytes (`st_blocks * 512`), same filesystem only (like `du -x`), hard links
   counted once, symlinks not followed. APFS clones are not detectable and are documented as a limitation.
8. **Recency in minutes.** All "idle for N days" checks use `now - mtime < N*24h` (BSD `find -mtime` rounds
   up and would treat 4.5 days as 5).
9. **Plans are metadata.** The JSON plan contains paths, sizes, tiers and reasons only, never file contents.
10. **One path form.** The per-user temp dir comes from `getconf DARWIN_USER_TEMP_DIR` (must match
    `/var/folders/*/*/T`), never from `$TMPDIR` or `os.TempDir()`, which callers can override. Roots and targets
    are compared as cleaned, unresolved paths; symlinks are never resolved on one side only (`/var` links to
    `/private/var`).

## Test Isolation (running the tests must never touch real files)
- Tests build their `Env` with `systest.NewSandbox(t)` (package `pkg/sys/systest`), whose home and temp dir live
  under `t.TempDir()`. Its helpers (`WriteFile`, `Age`, `BackdateTree`) call `RequireInside` and fail the test for
  any path outside the sandbox. `DefaultEnv` is called only by its own test, which merely reads the home
  directory and `getconf`.
- While a test binary runs, the engine's delete function panics for any path outside a temporary directory
  (a `testing.Testing()` safety net that also covers injected remove functions).
- No test calls the real `lsof`, `pgrep`, `simctl`, `brew`, `tmutil` or `rm` on real paths: all of them go through
  `FakeRunner`. The single allowed exception is one optional read-only `lsof` check on a temp dir.
- Legacy tests were audited on 2026-10-14: every one uses temp dirs or mocks.
- `cmm run --test-mode` writes `cmm_test_data/` into the working directory, so it is git-ignored.

## Architecture
New packages (the legacy `pkg/cmm`, `pkg/modules`, `pkg/ui` stay until Phase 3):

| Package | Responsibility |
|---|---|
| `pkg/sys` | `Runner` (exec + fake for tests), `Env` (home, per-user temp dir, clock, runner) |
| `pkg/sizer` | allocated, same-device, hard-link-aware size |
| `pkg/guard` | in-use (`lsof`), process-running (`pgrep`), recency walk (depth, prune, early exit), terminal check |
| `pkg/policy` | target validation, `ChildOf`, broad-directory refusal |
| `pkg/rules` | `Rule` interface and the built-in rule kinds |
| `pkg/engine` | `Plan`, `Apply`, JSON schema, log + last-run state, free-space reading |

```go
type Rule interface {
    ID() string
    Group() string
    Plan(ctx context.Context, env *sys.Env, g *guard.Guard) ([]Candidate, []Skip, error)
    Allows(env *sys.Env, path string) bool        // structural claim only
    Recheck(ctx context.Context, env *sys.Env, g *guard.Guard, c Candidate) error // guards at apply time
}
```
Command actions (Homebrew, simulators) implement `Executor` and are dispatched by the engine after the same
re-checks. Rule definitions are data tables interpreted by a few Go rule kinds (path, children, lane, versions,
simulators, command) so M4 can later validate model-proposed rules against the same policy.

## Built-in rules (parity with `dev-cleanup` v2, behavior copied exactly)
Idle threshold `IdleDays = 5`; "min" = minimum size for a path to be listed.

| ID | Target | Guard / rule |
|---|---|---|
| go-build | `~/Library/Caches/go-build` (min 50 MB) | no process named `go` |
| npm-cache | `~/.npm/_cacache` (50 MB) | no `npm (install\|ci\|add\|update\|i\|rebuild)` process |
| cocoapods | `~/Library/Caches/CocoaPods` (50 MB) | no `pod (install\|update\|repo)` |
| bun-cache | `~/.bun/install/cache` (50 MB) | no `bun (install\|add\|i\|update)` |
| uv-cache | `~/.cache/uv` (50 MB) | no uv/uvx process or `.cache/uv/` in a command line, and not in use |
| xcode-module-cache | `DerivedData/ModuleCache.noindex`, `CompilationCache.noindex` (100 MB) | Xcode, xcodebuild, swift-frontend, swift-build not running |
| jest-temp | `$TMPDIR/jest_dx` (50 MB) | no jest process |
| maestro-temp | children of `$TMPDIR` named `maestro_xctestrunner_xcodebuild_output*`, older than 60 min | no maestro process, no xcodebuild |
| cursor-update | `~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt/update.*` and `ShipItState.plist` | Cursor and its updater not running |
| cli-versions | `~/.local/share/{claude,cursor-agent}/versions/<name starting with a digit>` | keep newest, keep any linked from `~/.local/bin`, skip in-use |
| deriveddata-stale | children of `DerivedData` named `<Name>-<28 lowercase letters>` with `info.plist` | stale = nothing within depth 3 modified for IdleDays, or workspace gone and untouched 3 days; skip if workspace volume unmounted or folder in use |
| lane-local-build | direct children of `~/lane-builds` with `info.plist`(WorkspacePath) + `Build/` + (`Index.noindex` or `Logs`) and no `package.json` | same staleness as above |
| lane-deps | `<lane>/node_modules`, `<lane>/ios/Pods` for lanes with a root `package.json` | lane idle = no regular file outside `node_modules`/`Pods`/`.git` modified for IdleDays; skip symlinks and in-use |
| lane-build-output | `<lane>/ios/build`, `android/build`, `android/.gradle`, `android/app/build`, `android/app/.cxx` | same lane-idle rule; nested `<lane>/sub/...` paths are never claimed |
| simulators | devices from `simctl list devices unavailable` | CoreSimulator answering, device has `device.plist`, state shutdown, runtime absent from `simctl list runtimes`, untouched 3 days, not in use; action `simctl delete <udid>` |
| homebrew | `brew cleanup` | plan from `brew cleanup -n` (named formulae, Python flagged), skip if brew running; env `HOMEBREW_NO_AUTO_UPDATE/ANALYTICS/ENV_HINTS`; exit code checked |

## JSON schema v1 (`cmm plan --json`)
```json
{
  "schema_version": 1,
  "generated_at": "RFC3339",
  "host": { "volume": "/System/Volumes/Data", "free_bytes": 0 },
  "items":   [ { "rule": "go-build", "group": "Go build cache", "path": "...", "bytes": 0,
                 "tier": "safe", "action": "delete", "note": "" } ],
  "groups":  [ { "group": "...", "bytes": 0, "count": 0 } ],
  "skipped": [ { "rule": "uv-cache", "reason": "uv is running" } ],
  "total_bytes": 0
}
```
Tiers: `safe` (regenerable), `review` (reserved for M2+), `manual` (needs admin, reserved).

## CLI
- `cmm plan [--json]`: read-only.
- `cmm apply [--dry-run] [--yes] [--only <rule,...>]`: show plan, Return gate, apply.
- `cmm run` (legacy TUI): Phase 1 adds a warning banner; Phase 3 rewires it to the engine (preview-only
  unless `--apply`) and removes the unguarded Caches/Logs modules and the no-op `--force`.

## Out of Scope
User-defined rule files, history snapshots, Time Machine/sudo flows (stay a legacy manual module), the macOS app,
the Claude panel, and **retiring `dev-cleanup` / editing the weekly reminder** (a handover proposal that needs
the owner's explicit yes).

## Acceptance Criteria
1. `scripts/parity.sh` shows `cmm plan --json` equals `dev-cleanup --dry-run` on the real disk: same rule IDs,
   same item paths, sizes within max(2%, 5 MB). Skip wording is not compared. The reference is a patched copy of
   dev-cleanup (kept outside the repo, run with `--dry-run` only) that dumps its planned paths; the installed
   script is never modified.
2. Go tests carry over all 96 `dev-cleanup --self-test` allow-list checks and every fixture scenario
   (4.5 vs 5.5 day edges, nested recency, DerivedData look-alike inside a lane, nested `lane/sub/android/...`,
   symlinks, unmounted volume, workspace gone 4 days vs just now).
3. `apply` refuses without a terminal, cancels on EOF, and `--dry-run` never deletes (tested against a temp tree).
4. The JSON plan schema is covered by a golden test.
5. `cmm run` no longer reaches an unguarded module; `--force` no longer exists as a no-op.
6. New packages have >80% statement coverage.

## Verification Rules
- Never `go install` (it would overwrite the owner's `~/go/bin/cmm`); use `go run .` or build into a scratch dir.
- The agent never runs a real `apply` on the owner's disk, not even to look; `apply` is tested against temp trees.
- Manual verification steps handed to the owner are read-only: `cmm plan`, `cmm plan --json`,
  `cmm apply --dry-run`, and `cmm apply </dev/null` refusing. A real `apply` is the owner's call.
