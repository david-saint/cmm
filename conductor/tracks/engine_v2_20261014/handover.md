# Handover proposal: retire dev-cleanup, move the weekly reminder to cmm

**Status: proposal.** Nothing below has been done. Each step needs the owner's explicit yes.

## Why now
- Parity on the real disk (see Phase 4 in `plan.md`): the same items and sizes for go-build, bun-cache, uv-cache and lane-deps; the other 13 rules are proven in sandbox tests, and the 96 allow-list cases of `dev-cleanup --self-test` run as Go tests.
- cmm has everything dev-cleanup has (plan, Return gate, no terminal means no deletion, a log, a last-run stamp) and adds re-checks right before deleting, symlink refusal, JSON output and a test suite.

## What would change (every step is reversible)
1. **Install the new cmm**, keeping the old binary: `cd ~/go/src/github.com/david-saint/cmm && cp ~/go/bin/cmm ~/go/bin/cmm.old && go install .` (the installed `cmm` today is the old unguarded build from Jan 14).
2. **Carry the history over** (copies, never overwrites): `mkdir -p ~/.local/state/cmm && cp -n ~/.local/state/dev-cleanup/cleanup.log ~/.local/state/dev-cleanup/last-run ~/.local/state/cmm/`. The log lines have the same format, so the history stays one record and `Last cleanup:` keeps working.
3. **Retire the script** by renaming it: `mv ~/.local/bin/dev-cleanup ~/.local/bin/dev-cleanup.retired`. Its state folder `~/.local/state/dev-cleanup/` is left as it is.
4. **Point the weekly reminder at `cmm plan`** (read-only). The new prompt is below. It uses the text plan rather than `--json` because the reminder reports the "Last cleanup" line, the biggest items and the skipped guards, which the text plan prints; the JSON schema deliberately carries none of that.
5. **Left to you:** merging `feat/engine-v2` into `main` and pushing it. Neither is part of this handover.

## Undo
- `mv ~/.local/bin/dev-cleanup.retired ~/.local/bin/dev-cleanup`
- `mv ~/go/bin/cmm.old ~/go/bin/cmm`
- put the old reminder prompt (last section) back with the task update tool.
- `~/.local/state/cmm/` can be deleted; nothing else depends on it.

## The new reminder prompt (`weekly-dev-cleanup-reminder`)

```
You are a weekly disk-hygiene reminder for Saint's Mac mini (the internal 245 GB disk is chronically near full). This run is unattended and strictly READ-ONLY: never delete, move or modify anything, and never ask questions.

Background: Saint uses cmm (/Users/saint/go/bin/cmm), a guarded cleanup tool that removes regenerable developer clutter (build and package caches, idle ~/lane-builds dependencies and build output, stale Xcode build folders, old CLI versions, Homebrew old versions, orphaned simulators). `cmm apply` always shows a plan and waits for Saint to press Return, so Saint must run it personally in a terminal.

Do exactly this:
1. Run: df -h /System/Volumes/Data   and note the free space (the "Avail" column).
2. Run: /Users/saint/go/bin/cmm plan 2>&1   (ONLY `plan`; it deletes and writes nothing). From its output take: the "Last cleanup" line, the TOTAL it would free, the 3 biggest plan items, and any lines under SKIPPED.
3. Write a short report (at most 8 lines): free space now, how long since the last cleanup, what cmm would free and the top items, any SKIPPED guard that matters. If free space is below 20 GB, say so in the first line. End with one line: "Run cmm apply in Terminal, read the plan, press Return." Add one more line only if relevant: the Trash is invisible to cmm, so empty it if it is large.
4. If the PushNotification tool is available, send ONE notification (under 200 characters, one line, no markdown) that leads with the free space, for example: "Disk: 24 GB free. cmm would free ~7 GB. Run cmm apply in Terminal." If the tool is unavailable or reports "not sent", just continue.
5. Finish by giving the same short report as your final message.

Hard rules: only ever run cmm plan (never cmm apply, cmm run, or anything with --yes); never run rm, mv, brew cleanup, simctl delete, or any command that changes files or state; never edit anything. If a command is blocked or fails, do not retry it in another way; still deliver the reminder text from step 3 (say which check could not run).
```

## The old reminder prompt (to restore)

```
You are a weekly disk-hygiene reminder for Saint's Mac mini (the internal 245 GB disk is chronically near full). This run is unattended and strictly READ-ONLY: never delete, move or modify anything, and never ask questions.

Background: Saint has a script at /Users/saint/.local/bin/dev-cleanup that removes regenerable developer clutter (build caches, idle ~/lane-builds dependencies and build output, stale Xcode build folders, old CLI versions, Homebrew old versions, orphaned simulators). It always shows a plan and waits for Saint to press Return, so Saint must run it personally in a terminal.

Do exactly this:
1. Run: df -h /System/Volumes/Data   and note the free space (the "Avail" column).
2. Run: /Users/saint/.local/bin/dev-cleanup --dry-run   (ONLY with --dry-run; it deletes nothing). From its output take: the "Last cleanup" line, the TOTAL it would free, the 3 biggest plan items, and any lines under SKIPPED.
3. Write a short report (at most 8 lines): free space now, how long since the last cleanup, what dev-cleanup would free and the top items, any SKIPPED guard that matters. If free space is below 20 GB, say so in the first line. End with one line: "Run ~/.local/bin/dev-cleanup in Terminal, read the plan, press Return." Add one more line only if relevant: the Trash is invisible to this script, so empty it if it is large.
4. If the PushNotification tool is available, send ONE notification (under 200 characters, one line, no markdown) that leads with the free space, for example: "Disk: 24 GB free. dev-cleanup would free ~4 GB. Run ~/.local/bin/dev-cleanup in Terminal." If the tool is unavailable or reports "not sent", just continue.
5. Finish by giving the same short report as your final message.

Hard rules: never run dev-cleanup without --dry-run; never pass --yes; never run rm, mv, brew cleanup, simctl delete, or any command that changes files or state; never edit the script. If a command is blocked or fails, do not retry it in another way; still deliver the reminder text from step 3 (say which check could not run).
```
