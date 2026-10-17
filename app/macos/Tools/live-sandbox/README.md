# Live sandbox for the app

Opens the **built** app against a fake home folder, with a seeded history, a plan fixture and fake `brew`/`xcrun`/`docker`/`getconf`,
so the screens, the menu bar item, a real (fixture-only) cleaning and the weekly note can be looked at without touching the real disk.

```sh
cd app/macos && ./build-app.sh
LANE_A_MB=2200 Tools/live-sandbox/setup-live.sh "$(git rev-parse --show-toplevel)" /tmp/cmm-live full    # full | few | first
# it prints the `open -n --env CMM_BIN=... <twin>` line to run
```

Rules this kit exists to keep (each was learned the hard way):

- The twin has its own bundle id (`com.davidsaint.cmm.sandbox`): UserDefaults is keyed by bundle id and a fake `HOME` does **not**
  isolate it. Remove its preferences afterwards with `defaults delete com.davidsaint.cmm.sandbox`.
- **Never press "Turn on" or "Open at login" in the twin**: they register a real login item on the Mac. Switch the other three
  Settings switches one by one instead.
- The engine asks `getconf DARWIN_USER_TEMP_DIR` for the *real* per-user temp folder, ignoring `TMPDIR`; the kit's fake `getconf`
  answers with a folder that does not exist, so the plan holds only fixture items. Check the plan before any click.
- macOS refuses to show its notification permission question to an app that runs from `/tmp`: the twin goes to `build/sandbox`.
- The first "Weekly reminder" switch-on asks macOS for permission (a person must click Allow); set the weekday to today in the
  picker to make the note fire. The reminder needs 2 GB or more that can go (`LANE_A_MB=2200`), the window on the rest screen
  or closed, and a fresh `lastWeeklyDate` (`defaults delete com.davidsaint.cmm.sandbox lastWeeklyDate`).
- Nothing in here deletes anything; each run makes new, time-stamped folders.
