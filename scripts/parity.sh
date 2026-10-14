#!/bin/bash
# parity.sh: does cmm plan the same cleanup as the dev-cleanup script, on this machine, right now?
#
#   scripts/parity.sh
#
# It only looks. cmm is built into a temporary folder (never installed) and asked for `plan --json`; dev-cleanup
# is NOT run directly: a copy is made in which everything from the plan marker on is replaced by a dump of the
# plan and `exit 0`, so no deletion code can run, and the copy is started with --dry-run as well. The installed
# script is read, never changed (its checksum is compared before and after).
#
# The two plans are compared by path: every path must be in both, under the same rule, with a size within
# max(2%, 5 MB). Differences are named. Rules for which neither tool had anything are listed, so a pass on a
# machine where most caches are empty is not mistaken for full coverage.
#
# Exit status: 0 the plans agree, 1 they differ, 2 the comparison could not be made safely (nothing is trusted),
# 3 neither tool planned anything (parity not shown; PARITY_ALLOW_EMPTY=1 turns that into 0).
#
# Environment (all optional):
#   PARITY_DEV_CLEANUP   the dev-cleanup script to compare with (default ~/.local/bin/dev-cleanup)
#   PARITY_CMM           an already built cmm binary (default: build one from this checkout)
#   PARITY_OUT           where the artifacts go (default: a fresh folder under $TMPDIR); they are kept
#   PARITY_PYTHON        python3 to use (default /usr/bin/python3)
#   PARITY_ALLOW_EMPTY   1: "nothing to compare" is exit 0

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEV="${PARITY_DEV_CLEANUP:-$HOME/.local/bin/dev-cleanup}"
PY="${PARITY_PYTHON:-/usr/bin/python3}"
MARKER="# ---------- plan ----------"

fail() { echo "PARITY ERROR: $*" >&2; exit 2; }

[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null)" || fail "python3 not found"
[ -f "$DEV" ] || fail "dev-cleanup not found at $DEV"

if [ -n "${PARITY_OUT:-}" ]; then
  OUT="$PARITY_OUT"
  mkdir -p "$OUT" || fail "cannot create $OUT"
else
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/cmm-parity.XXXXXX")" || fail "cannot create a temporary folder"
fi
echo "artifacts: $OUT"

BEFORE="$(shasum -a 256 "$DEV" | cut -d' ' -f1)" || fail "cannot read dev-cleanup"

# ---- cmm ----
if [ -n "${PARITY_CMM:-}" ]; then
  CMM="$PARITY_CMM"
  [ -x "$CMM" ] || fail "cmm binary not found or not executable: $CMM"
else
  CMM="$OUT/cmm"
  echo "building cmm into $CMM (not installed)"
  (cd "$ROOT" && go build -o "$CMM" .) || fail "go build failed"
fi

# ---- a patched COPY of dev-cleanup that dumps its plan and stops ----
"$PY" - "$DEV" "$OUT/dev-cleanup.patched" "$MARKER" <<'PYEOF' || fail "could not make the patched copy of dev-cleanup: the plan marker must appear exactly once"
import sys

src, dst, marker = sys.argv[1:4]
SNIPPET = r'''# --- parity dump (injected by cmm scripts/parity.sh; not part of dev-cleanup) ---
: "${PARITY_DUMP:?PARITY_DUMP is not set}"
{
  printf 'PARITY-DUMP v1\n'
  _pi=0
  while [ "$_pi" -lt "${#P_PATH[@]}" ]; do
    case "${P_PATH[$_pi]}${P_LABEL[$_pi]}" in *$'\t'*|*$'\n'*) echo "PARITY: a path or label contains a tab or newline" >&2; exit 3 ;; esac
    printf 'path\t%s\t%s\t%s\n' "${P_PATH[$_pi]}" "${P_KB[$_pi]}" "${P_LABEL[$_pi]}"
    _pi=$((_pi + 1))
  done
  _pi=0
  while [ "$_pi" -lt "${#S_UDID[@]}" ]; do
    case "${S_UDID[$_pi]}${S_NAME[$_pi]}" in *$'\t'*|*$'\n'*) echo "PARITY: a simulator id or name contains a tab or newline" >&2; exit 3 ;; esac
    printf 'sim\t%s\t%s\t%s\n' "$SIMDIR/${S_UDID[$_pi]}" "${S_KB[$_pi]}" "${S_NAME[$_pi]}"
    _pi=$((_pi + 1))
  done
  printf 'brew\t%s\n' "${BREW_KB:-0}"
  _pi=0
  while [ "$_pi" -lt "${#SKIPS[@]}" ]; do
    printf 'skip\t%s\n' "${SKIPS[$_pi]//$'\n'/ }"
    _pi=$((_pi + 1))
  done
  printf 'END\n'
} > "$PARITY_DUMP" || exit 3
exit 0
# --- end of parity dump ---
'''
lines = open(src, encoding="utf-8").read().split("\n")
hits = [i for i, line in enumerate(lines) if line.rstrip() == marker]
if len(hits) != 1:
    sys.exit("the plan marker was found %d times" % len(hits))
i = hits[0]
patched = lines[:i] + SNIPPET.rstrip("\n").split("\n") + lines[i:]
open(dst, "w", encoding="utf-8").write("\n".join(patched))
PYEOF
grep -q '^# --- parity dump (injected by cmm' "$OUT/dev-cleanup.patched" || fail "the patched copy has no dump in it"
bash -n "$OUT/dev-cleanup.patched" || fail "the patched copy of dev-cleanup does not parse"

# ---- run the patched copy: --dry-run, no terminal, and it exits at the dump ----
: > "$OUT/dump.tsv"
PARITY_DUMP="$OUT/dump.tsv" bash "$OUT/dev-cleanup.patched" --dry-run </dev/null >"$OUT/dev-cleanup.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "dev-cleanup (patched copy) exited with status $rc; see $OUT/dev-cleanup.out"
[ "$(head -n 1 "$OUT/dump.tsv")" = "PARITY-DUMP v1" ] && [ "$(tail -n 1 "$OUT/dump.tsv")" = "END" ] \
  || fail "dev-cleanup left no complete dump of its plan in $OUT/dump.tsv"

# ---- cmm's plan ----
"$CMM" plan --json >"$OUT/cmm.json" 2>"$OUT/cmm.err" || fail "cmm plan --json failed; see $OUT/cmm.err"

# ---- compare ----
"$PY" "$HERE/parity_compare.py" "$OUT/dump.tsv" "$OUT/cmm.json"
status=$?

AFTER="$(shasum -a 256 "$DEV" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "the installed dev-cleanup changed during the run"
echo "artifacts kept in $OUT"
exit "$status"
