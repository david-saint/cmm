#!/bin/bash
# Sets up everything for a live, sandboxed run of the built app, and prints how to open it. Never deletes anything: every run
# makes new, time-stamped folders. Nothing real is read or written through the sandbox engine (fake HOME, fake brew/xcrun/docker).
#
#   usage: setup-live.sh <worktree with app/macos/build/Cmm.app built> <scratch dir under /tmp> [full|few|first]
#   env:   LANE_A_MB=2200  makes the safe total big enough for the Monday reminder (2 GB rule)
#          TWIN_DIR=...    where the sandbox twin goes (default <worktree>/app/macos/build/sandbox). Keep it OUT of /tmp: macOS
#                          will not even ask an app in /tmp for notification permission.
set -euo pipefail
WT="$1"; SCRATCH="$2"; SCENARIO="${3:-full}"
KIT="$(cd "$(dirname "$0")" && pwd)"
case "$SCRATCH" in /private/tmp/*|/tmp/*) ;; *) echo "refusing: scratch must be under /tmp" >&2; exit 1;; esac
APP="$WT/app/macos/build/Cmm.app"
[ -d "$APP/Contents" ] || { echo "build the app first: $APP" >&2; exit 1; }
STAMP="$(date +%H%M%S)"
BIN="$SCRATCH/live-bin"; HOME_DIR="$SCRATCH/live-home-$STAMP"; OUT="$SCRATCH/sandbox"; TWIN_DIR="${TWIN_DIR:-$WT/app/macos/build/sandbox}"
mkdir -p "$TWIN_DIR"
mkdir -p "$BIN" "$OUT" "$HOME_DIR/tmp"

# 1. the engine, from the worktree's own source (what the app's bundle carries)
(cd "$WT" && go build -trimpath -o "$BIN/cmm-$STAMP" .)

# 2. fake tools first on PATH, so nothing real is touched
printf '#!/bin/sh\nexit 0\n' > "$BIN/brew"
printf '#!/bin/sh\nexit 1\n' > "$BIN/xcrun"
cat > "$BIN/docker" <<DOCKER
#!/bin/sh
STATE="$BIN/.docker-state"
case "\$1 \$2" in
  "system df")
    if [ -f "\$STATE" ]; then
      printf 'Images\t27MB\t0B (0%%)\nContainers\t0B\t0B\nLocal Volumes\t5GB\t2GB (40%%)\nBuild Cache\t3MB\t0B\n'
    else
      printf 'Images\t900MB\t900MB (100%%)\nContainers\t60MB\t60MB (100%%)\nLocal Volumes\t5GB\t2GB (40%%)\nBuild Cache\t420MB\t420MB\n'
    fi ;;
  "image prune") touch "\$STATE"; echo "Total reclaimed space: 900MB" ;;
  "container prune") touch "\$STATE"; echo "Total reclaimed space: 60MB" ;;
  "builder prune") touch "\$STATE"; echo "Total:  420MB" ;;
  *) echo "fake docker: unsupported \$*" >&2; exit 1 ;;
esac
DOCKER
# the engine asks `getconf DARWIN_USER_TEMP_DIR` for the REAL per-user temp folder (ignoring TMPDIR): answer with a folder that does not exist
cat > "$BIN/getconf" <<'GETCONF'
#!/bin/sh
if [ "$1" = "DARWIN_USER_TEMP_DIR" ]; then echo "/var/folders/zz/cmmsandbox000000000000000000/T/"; else exec /usr/bin/getconf "$@"; fi
GETCONF
chmod +x "$BIN/brew" "$BIN/xcrun" "$BIN/docker" "$BIN/getconf"

# 3. a plan fixture: real, distinct blocks (so a clean really gives disk back), lanes idle since 30 Sep, items over 50 MiB
fill() { mkdir -p "$(dirname "$1")"; dd if=/dev/urandom of="$1" bs=1048576 count="$2" 2>/dev/null; }
lane() { local L="$HOME_DIR/lane-builds/$1"; mkdir -p "$L"; echo "{}" > "$L/package.json"; fill "$L/node_modules/pkg/data" "$2"; find "$L" -exec touch -t 202609300900 {} +; }
lane lane-a "${LANE_A_MB:-70}"; lane lane-b 55; lane lane-c 52
fill "$HOME_DIR/.cache/uv/data" 60
fill "$HOME_DIR/.npm/_cacache/data" 55
fill "$HOME_DIR/Library/Caches/go-build/a/data" 70
fill "$HOME_DIR/.bun/install/cache/data" 52

# 4. the history (runs and free-space notes) the engine reads back
python3 -I "$KIT/make-history-fixture.py" "$HOME_DIR" "$SCENARIO"

# 5. the engine wrapper the sandbox app is told to use (CMM_BIN)
WRAP="$OUT/cmm-wrapper-$STAMP.sh"
cat > "$WRAP" <<WRAPPER
#!/bin/sh
export HOME="$HOME_DIR" TMPDIR="$HOME_DIR/tmp" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
exec "$BIN/cmm-$STAMP" "\$@"
WRAPPER
chmod +x "$WRAP"

# 6. the sandbox twin of the app: its own bundle id, so its preferences, notification permission and login item are not the real app's
TWIN="$TWIN_DIR/cmm-sandbox-$STAMP.app"
ditto "$APP" "$TWIN"
plutil -replace CFBundleIdentifier -string com.davidsaint.cmm.sandbox "$TWIN/Contents/Info.plist"
plutil -replace CFBundleName -string "cmm sandbox" "$TWIN/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "cmm sandbox" "$TWIN/Contents/Info.plist"
codesign --force --sign - "$TWIN/Contents/Resources/cmm" >/dev/null 2>&1
codesign --force --deep --sign - "$TWIN" >/dev/null 2>&1
codesign --verify --deep --strict "$TWIN"

echo
echo "fake home : $HOME_DIR"
echo "engine    : $WRAP"
echo "sandbox   : $TWIN   (bundle id com.davidsaint.cmm.sandbox)"
echo "open with : open -n --env CMM_BIN=\"$WRAP\" \"$TWIN\""
echo "check     : \"$WRAP\" plan --json | head -c 300 ; \"$WRAP\" history | head -8"
