# Track Plan: engine_v2_20261014

## Phase 1: Safety Foundation, Engine Core and First Rules [checkpoint: cbccf6e]
- [x] Task: `pkg/sys`: command Runner (real exec + fake), Env (home, per-user temp dir from `getconf`, clock) and the `systest.Sandbox` test-isolation helper (`RequireInside`) 9295616
- [x] Task: `pkg/sizer`: allocated size, same device only, hard links once, symlinks not followed 8e8edb2
- [x] Task: `pkg/guard`: in-use (lsof), process-running (pgrep), recency walk, terminal check; fail-safe exit-code semantics from the spec, each tested on a fake runner b12d253
- [x] Task: `pkg/policy`: target validation (absolute, clean, allowed roots, no broad directories, no symlink target) 59d82d6
- [x] Task: `pkg/rules` and `pkg/engine` core: Rule interface, Plan, Apply with safety invariants 1-6 (re-check Allows/policy/guards right before each delete, dry-run never deletes, continue past errors with a non-zero exit) and free-space reading 4a37691
- [x] Task: JSON schema v1 for plans with a golden test 66f0fda
- [x] Task: Path rule kind and the first built-in rules (Go, npm, CocoaPods, bun, uv, Jest, Xcode module caches) 27ef4e3
- [x] Task: CLI `cmm plan [--json]` and `cmm apply [--dry-run] [--yes]` with the no-terminal guard, Return gate and EOF/Ctrl-D cancel; warning banner on legacy `run`; git-ignore `cmm_test_data/` 6cc485d
- [x] Task: Conductor - User Manual Verification 'Phase 1' (Protocol in workflow.md) cbccf6e

## Phase 2: Parity Rules
- [x] Task: Symlink hardening: refuse a target when any folder between its root (home or temp dir) and it is a symlink, at plan and apply time; `PathRule` skips symlinked parents 0d015d0
- [x] Task: Children rules: Maestro temp output (age filter) and Cursor failed-update leftovers 95b105e
- [x] Task: Old CLI versions rule (keep newest, linked and in-use; links and in-use state re-read at apply time) 4bb94c8
- [x] Task: Xcode build folders: DerivedData stale rule (3-level recency, workspace gone, unmounted volume, in-use) 87ed850
- [x] Task: Lane-local Xcode build folders (layout check, same staleness) 58fa5f9
- [x] Task: Lanes: idle dependencies and build output (root package.json, idle test, symlinks, nested paths refused) dbbe35d
- [x] Task: Simulators: unavailable devices via simctl with every guard 1238980
- [x] Task: Homebrew: `brew cleanup` planner (named formulae, Python flag, exit code handling) 7064f79
- [x] Task: Built-in registry in dev-cleanup order, `Engine.Allowed` (a rule allows it, policy accepts it, no symlink below the root) and the 96 allow-list cases ported as a table test; tests proving no rule reaches a real tool (unstubbed fake runner, no `os/exec` import outside `pkg/sys`) 2619cef
- [ ] Task: `scripts/parity.sh`: compare `cmm plan --json` with a patched copy of dev-cleanup on the real disk; fails closed (marker check, dump header, `--dry-run` hard-coded, compare by path, non-zero exit on mismatch) and reports categories that had nothing to compare
- [ ] Task: Conductor - User Manual Verification 'Phase 2' (Protocol in workflow.md)

## Phase 3: Safe Apply, TUI and Legacy Removal
- [ ] Task: Apply polish: cleanup log and last-run stamp (the safety invariants already shipped in Phase 1)
- [ ] Task: Rewire `cmm run` to the engine (preview-only unless `--apply`); remove unguarded Caches/Logs modules and the no-op `--force`; keep Time Machine as a manual legacy module
- [ ] Task: Documentation: README, tech-stack, product docs
- [ ] Task: Conductor - User Manual Verification 'Phase 3' (Protocol in workflow.md)

## Phase 4: Acceptance and Handover
- [ ] Task: Real-disk parity run recorded in this plan
- [ ] Task: Handover proposal for the owner's approval: retire `~/.local/bin/dev-cleanup` and point the weekly reminder at `cmm plan --json`
- [ ] Task: Conductor - User Manual Verification 'Phase 4' (Protocol in workflow.md)
