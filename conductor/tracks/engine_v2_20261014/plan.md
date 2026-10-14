# Track Plan: engine_v2_20261014

## Phase 1: Safety Foundation, Engine Core and First Rules
- [x] Task: `pkg/sys`: command Runner (real exec + fake), Env (home, per-user temp dir from `getconf`, clock) and the `TestEnv`/`RequireIsolated` test-isolation helper 9295616
- [x] Task: `pkg/sizer`: allocated size, same device only, hard links once, symlinks not followed 8e8edb2
- [x] Task: `pkg/guard`: in-use (lsof), process-running (pgrep), recency walk, terminal check; fail-safe exit-code semantics from the spec, each tested on a fake runner b12d253
- [ ] Task: `pkg/policy`: target validation (absolute, clean, allowed roots, no broad directories, no symlink target)
- [ ] Task: `pkg/rules` and `pkg/engine` core: Rule interface, Plan, Apply with safety invariants 1-6 (re-check Allows/policy/guards right before each delete, dry-run never deletes, continue past errors with a non-zero exit) and free-space reading
- [ ] Task: JSON schema v1 for plans with a golden test
- [ ] Task: Path rule kind and the first built-in rules (Go, npm, CocoaPods, bun, uv, Jest, Xcode module caches)
- [ ] Task: CLI `cmm plan [--json]` and `cmm apply [--dry-run] [--yes]` with the no-terminal guard, Return gate and EOF/Ctrl-D cancel; warning banner on legacy `run`; git-ignore `cmm_test_data/`
- [ ] Task: Conductor - User Manual Verification 'Phase 1' (Protocol in workflow.md)

## Phase 2: Parity Rules
- [ ] Task: Children rules: Maestro temp output (age filter) and Cursor failed-update leftovers
- [ ] Task: Old CLI versions rule (keep newest, linked and in-use)
- [ ] Task: Xcode build folders: DerivedData stale rule (3-level recency, workspace gone, unmounted volume, in-use)
- [ ] Task: Lane-local Xcode build folders (layout check, same staleness)
- [ ] Task: Lanes: idle dependencies and build output (root package.json, idle test, symlinks, nested paths refused)
- [ ] Task: Simulators: unavailable devices via simctl with every guard
- [ ] Task: Homebrew: `brew cleanup` planner (named formulae, Python flag, exit code handling)
- [ ] Task: Built-in registry in dev-cleanup order and the 96 allow-list cases ported as a table test
- [ ] Task: `scripts/parity.sh`: compare `cmm plan --json` with a patched copy of dev-cleanup on the real disk
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
