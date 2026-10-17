# Spec: history and free-space timeline (milestone 3, engine side)

Process: lightweight (TDD, one commit per task, one check-in when the app screens are built). Branch `feat/app-v0`.

## Why
The app (and later the menu bar and the weekly notification) needs to say "you freed 5.4 GB on Tuesday" and "free space has fallen 3 GB since last week" without parsing a text log or scanning again. The engine keeps two small, private, append-only files and reads them back as JSON.

## What is kept (metadata only: paths and sizes that the plan already showed, never file contents)
Both files live in `~/.local/state/cmm/` (cmm's own folder, mode 0700; files 0600; appended with `O_APPEND|O_NOFOLLOW`, one write per line; a link in their place is never followed).

- `history.jsonl`: one line per real apply that deleted or failed something (a dry run, or a run in which everything was skipped, leaves no line, like `cleanup.log`):
  `{"schema_version":1,"started_at":RFC3339,"finished_at":RFC3339,"deleted":N,"skipped":N,"failed":N,"freed_bytes":N,"free_before":N,"free_after":N,"capacity_bytes":N,"stopped":false,"planned":N,"items":[{"rule","group","path","status":"deleted|failed","bytes","freed_bytes","reason"}]}`
  Items list what was deleted or failed (skipped ones are only counted). `capacity_bytes` is left out when unknown. `planned` (added 2026-10-16 for the app's History face) is how many items the run set out to do, skipped ones included; with deleted+skipped+failed it tells how many a stopped run never reached ("stopped after 2 of 9"); it is left out of lines written before it existed.
- `free.jsonl`: one line per free-space sample: `{"t":RFC3339,"free_bytes":N,"capacity_bytes":N}` (capacity left out when unknown). A sample is added only when it is due: at least 30 minutes after the last one, or when free space moved by 256 MiB or more since then. `cmm sample` takes one; nothing else writes samples (`cmm plan` stays read-only).

## Commands
- `cmm sample [--json]`: reads the free space of the volume (statfs only, no scan, under a second) and appends a sample if one is due. Text: `Recorded: 19.6 GB free.` or `Not due: the last sample is 4 min old.`. JSON: `{"recorded":true|false,"t":...,"free_bytes":N,"capacity_bytes":N}`. A failure to write is reported on stderr and exits non-zero (it is the only thing this command does).
- `cmm history [--json] [--limit N] [--days N]`: the last N runs (default 20, newest first) and the samples of the last N days (default 90, oldest first), plus the run endpoints folded into the timeline. Text: a short table. JSON (schema 1):
  `{"schema_version":1,"generated_at":...,"host":{"volume","free_bytes","capacity_bytes"},"runs":[...run objects as above...],"samples":[{"t","free_bytes","capacity_bytes"}],"unreadable_lines":N}`
  A line that cannot be read (garbled, not JSON, wrong schema, too long) is skipped and counted in `unreadable_lines`, never fatal. Reads are bounded (the last 8 MiB of each file).

## Safety
- History never decides anything: no rule, policy, plan or apply code reads it (a test walks the imports and the call graph of `Plan`/`Apply` to prove it). A tampered history can only change what the app shows.
- A history that cannot be written is a warning on the report (`history: ...`), never a failed cleanup, exactly like the journal.
- Honest numbers: `freed_bytes` is what the results said, `free_before`/`free_after` are what statfs said.
- Plans stay metadata, `plan` stays read-only.

## Out of scope
Pruning or rotating the files (a year of weekly runs is a few hundred KB; samples are at most 48 a day), the menu bar, notifications and the screens that draw the timeline (the app milestone).
