#!/usr/bin/env python3
"""Compare dev-cleanup's dumped plan with cmm's plan (called by scripts/parity.sh).

usage: parity_compare.py DUMP.tsv CMM.json

Exit status: 0 the plans agree, 1 they differ, 2 an input cannot be trusted, 3 neither tool planned anything
(PARITY_ALLOW_EMPTY=1 turns that into 0).
"""
import json
import os
import sys

# dev-cleanup's group label -> cmm rule id (cmm uses the same wording as its group names)
LABELS = {
    "Simulators whose runtime was removed": "simulators",
    "Stale Xcode build output (DerivedData)": "deriveddata-stale",
    "Xcode module/compilation cache (rebuilds on the next build)": "xcode-module-cache",
    "Go build cache": "go-build",
    "npm download cache": "npm-cache",
    "CocoaPods cache": "cocoapods",
    "bun cache": "bun-cache",
    "uv cache (Python packages; downloads again on demand)": "uv-cache",
    "Jest temp cache": "jest-temp",
    "Maestro test output (older than 1 hour)": "maestro-temp",
    "Cursor's failed update (staged copy)": "cursor-update",
    "Old claude CLI versions": "claude-versions",
    "Old cursor-agent versions": "cursor-agent-versions",
    "Idle lane dependencies (untouched 5+ days; rebuild with npm ci / pod install)": "lane-deps",
    "Idle lane build output (untouched 5+ days; rebuilds on the next build)": "lane-build-output",
    "Stale lane-local Xcode build folders": "lane-local-build",
    "Homebrew: old versions of installed formulae (brew cleanup)": "homebrew",
}
RULES = list(LABELS.values())  # dev-cleanup order
RULE_LABEL = {rule: label for label, rule in LABELS.items()}
BREW_PATH = "homebrew: cleanup"

TOLERANCE_PERCENT = 0.02
TOLERANCE_MIN_BYTES = 5 * 1024 * 1024


def error(msg):
    print("PARITY ERROR: " + msg, file=sys.stderr)
    sys.exit(2)


def human(n):
    if n >= 1 << 30:
        return "%.1f GB" % (n / (1 << 30))
    if n >= 1 << 20:
        return "%d MB" % (n >> 20)
    return "%d KB" % (n >> 10)


def read_dump(path):
    """-> (items {path: (rule, bytes)}, skips [str]); every line is checked."""
    with open(path, encoding="utf-8", errors="strict") as f:
        lines = f.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) < 2 or lines[0] != "PARITY-DUMP v1" or lines[-1] != "END":
        error("dev-cleanup's dump is not complete")
    items, skips = {}, []

    def add(p, rule, nbytes, n):
        if p in items:
            error("dev-cleanup planned %r twice (dump line %d)" % (p, n))
        items[p] = (rule, nbytes)

    for n, line in enumerate(lines[1:-1], start=2):
        f = line.split("\t")
        kind = f[0]
        try:
            if kind == "path" and len(f) == 4:
                if f[3] not in LABELS:
                    error("dev-cleanup uses a group label this script does not know (dump line %d): %r" % (n, f[3]))
                add(f[1], LABELS[f[3]], int(f[2]) * 1024, n)
            elif kind == "sim" and len(f) == 4:
                add(f[1], "simulators", int(f[2]) * 1024, n)
            elif kind == "brew" and len(f) == 2:
                if int(f[1]) > 0:
                    add(BREW_PATH, "homebrew", int(f[1]) * 1024, n)
            elif kind == "skip" and len(f) >= 2:
                skips.append("\t".join(f[1:]))
            else:
                error("dev-cleanup's dump has a line this script does not understand (line %d): %r" % (n, line))
        except ValueError:
            error("dev-cleanup's dump has a bad number (line %d): %r" % (n, line))
    return items, skips


def read_plan(path):
    try:
        with open(path, encoding="utf-8") as f:
            plan = json.load(f)
    except (OSError, ValueError) as e:
        error("cmm's output is not JSON (%s)" % e)
    if not isinstance(plan, dict) or plan.get("schema_version") != 1:
        error("cmm's plan has an unsupported schema_version (%r); this script reads 1" % (plan.get("schema_version") if isinstance(plan, dict) else None))
    items, groups = {}, {}
    for it in plan.get("items") or []:
        try:
            p, rule, group, nbytes = it["path"], it["rule"], it["group"], int(it["bytes"])
        except (KeyError, TypeError, ValueError):
            error("cmm's plan has an item this script does not understand: %r" % (it,))
        if p in items:
            error("cmm planned %r twice" % p)
        items[p] = (rule, nbytes)
        groups[p] = group
    skips = ["%s: %s" % (s.get("rule", "?"), s.get("reason", "?")) for s in plan.get("skipped") or []]
    return items, groups, skips


def main():
    if len(sys.argv) != 3:
        error("usage: parity_compare.py DUMP.tsv CMM.json")
    dc, dc_skips = read_dump(sys.argv[1])
    cm, cm_groups, cm_skips = read_plan(sys.argv[2])

    problems = []
    for p in sorted(set(dc) | set(cm)):
        if p not in cm:
            problems.append("only in dev-cleanup: %s (%s, %s)" % (p, dc[p][0], human(dc[p][1])))
            continue
        if p not in dc:
            problems.append("only in cmm: %s (%s, %s)" % (p, cm[p][0], human(cm[p][1])))
            continue
        (drule, dbytes), (crule, cbytes) = dc[p], cm[p]
        if drule != crule:
            problems.append("rule differs: %s dev-cleanup=%s cmm=%s" % (p, drule, crule))
        if abs(dbytes - cbytes) > max(TOLERANCE_PERCENT * max(dbytes, cbytes), TOLERANCE_MIN_BYTES):
            problems.append("size differs: %s dev-cleanup=%s cmm=%s" % (p, human(dbytes), human(cbytes)))
    for p, group in sorted(cm_groups.items()):
        rule = cm[p][0]
        if rule in RULE_LABEL and group != RULE_LABEL[rule]:
            problems.append("group differs: %s cmm says %r for rule %s, dev-cleanup calls it %r" % (p, group, rule, RULE_LABEL[rule]))
        if rule not in RULE_LABEL:
            problems.append("unknown rule: %s planned by cmm rule %r, which this script does not know" % (p, rule))

    def tally(items):
        out = {}
        for rule, nbytes in items.values():
            n, total = out.get(rule, (0, 0))
            out[rule] = (n + 1, total + nbytes)
        return out

    dt, ct = tally(dc), tally(cm)
    print()
    print("%-24s %-22s %-22s" % ("rule", "dev-cleanup", "cmm"))
    for rule in RULES:
        d, c = dt.get(rule), ct.get(rule)
        if d or c:
            fmt = lambda x: "%d (%s)" % (x[0], human(x[1])) if x else "-"
            print("%-24s %-22s %-22s" % (rule, fmt(d), fmt(c)))
    empty = [r for r in RULES if r not in dt and r not in ct]
    if empty:
        print("\nNothing to compare in: " + ", ".join(empty))

    print("\nSkipped (for information, wording differs between the tools): dev-cleanup %d, cmm %d" % (len(dc_skips), len(cm_skips)))
    for s in dc_skips:
        print("  dev-cleanup: " + s)
    for s in cm_skips:
        print("  cmm: " + s)

    print()
    if problems:
        for p in problems:
            print("  " + p)
        print("\nPARITY MISMATCH: %d difference(s). Both tools ran a few minutes apart; if a difference sits on a"
              " time limit (5 days, 3 days, 1 hour), run it again." % len(problems))
        return 1
    if not dc and not cm:
        print("NOTHING TO COMPARE: neither tool planned anything, so parity is not shown.")
        return 0 if os.environ.get("PARITY_ALLOW_EMPTY") == "1" else 3
    total = sum(b for _, b in dc.values())
    print("PARITY OK: %d item(s) agree (%s)." % (len(dc), human(total)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
