#!/usr/bin/env python3
"""Writes a believable history.jsonl and free.jsonl for a SANDBOX home, in cmm's own line format (schema 1).

usage: python3 -I make-history-fixture.py <fake-home> <scenario: full|few|first> [free-now-bytes]

full  : ~40 days of samples every 30 min with a two-day gap, five cleanings (a big one, one with a failed item, a stopped
        one with `planned`, a normal one, a Docker-only one); the series ends at the real free space (or the number given)
few   : three days of samples and one cleaning (the "History fills in" state)
first : no files at all (the first-run state)
It only ever writes inside <fake-home>/.local/state/cmm and refuses any home that is not under /tmp.
"""
import sys, os, json, random, shutil, datetime as dt

home, scenario = os.path.abspath(sys.argv[1]), sys.argv[2]
state = os.path.join(home, ".local", "state", "cmm")
assert home.startswith("/tmp/") or home.startswith("/private/tmp/"), "refusing: not a scratch home under /tmp: " + home
os.makedirs(state, mode=0o700, exist_ok=True)
for name in ("history.jsonl", "free.jsonl"):
    p = os.path.join(state, name)
    if os.path.exists(p):
        os.remove(p)
if scenario == "first":
    print("first run: no files"); sys.exit(0)

GB = 1_000_000_000
cap = 245_107_195_904
free_now = int(sys.argv[3]) if len(sys.argv) > 3 else shutil.disk_usage("/System/Volumes/Data").free
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
rnd = random.Random(20261016)

def ts(t): return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def local_at(days_ago, hour, minute):
    base = (dt.datetime.now().astimezone() - dt.timedelta(days=days_ago)).replace(hour=hour, minute=minute, second=7, microsecond=0)
    return base.astimezone(dt.timezone.utc)

def item(rule, group, path, status, size, inside="", reason=""):
    d = {"rule": rule, "group": group, "path": path, "status": status, "bytes": size,
         "freed_bytes": size if status == "deleted" else 0}
    if inside: d["frees_inside"] = inside
    if reason: d["reason"] = reason
    return d

def run(started, minutes, items, planned, stopped=False, skipped=0):
    deleted = sum(1 for i in items if i["status"] == "deleted")
    failed = sum(1 for i in items if i["status"] == "failed")
    freed = sum(i["freed_bytes"] for i in items if i["status"] == "deleted" and "frees_inside" not in i)
    inside = sum(i["freed_bytes"] for i in items if i["status"] == "deleted" and "frees_inside" in i)
    r = {"schema_version": 1, "started_at": ts(started), "finished_at": ts(started + dt.timedelta(minutes=minutes)),
         "deleted": deleted, "skipped": skipped, "failed": failed, "freed_bytes": freed}
    if inside: r["freed_inside_bytes"] = inside
    r.update({"free_before": 0, "free_after": 0, "capacity_bytes": cap, "stopped": stopped, "planned": planned, "items": items})
    return r, started + dt.timedelta(minutes=minutes)

H = home
runs = []
def add(days_ago, hh, mm, minutes, items, planned, **kw):
    r, fin = run(local_at(days_ago, hh, mm), minutes, items, planned, **kw)
    runs.append((r, fin))

if scenario == "full":
    start_days = 40
    add(17, 10, 2, 6, [
        item("simulators", "Unavailable simulators", "xcrun simctl delete unavailable", "deleted", 9_800_000_000),
        item("lane-deps", "Idle lane dependencies", H + "/lane-builds/lane-a/node_modules", "deleted", 7_100_000_000),
        item("lane-deps", "Idle lane dependencies", H + "/lane-builds/lane-b/ios/Pods", "deleted", 5_300_000_000),
        item("cli-versions", "Old CLI versions", H + "/.local/share/claude/versions/2.1.201", "deleted", 4_400_000_000),
        item("brew-old", "Homebrew old versions", "brew cleanup", "deleted", 3_900_000_000),
        item("npm-cache", "npm cache", H + "/.npm/_cacache", "deleted", 3_100_000_000),
        item("go-build", "Go build cache", H + "/Library/Caches/go-build", "deleted", 2_000_000_000),
        item("uv-cache", "uv cache", H + "/.cache/uv", "deleted", 800_000_000),
    ], 8)
    add(7, 9, 41, 3, [
        item("go-build", "Go build cache", H + "/Library/Caches/go-build", "failed", 1_200_000_000, reason="permission denied"),
        item("brew-old", "Homebrew old versions", "brew cleanup", "deleted", 1_200_000_000),
        item("npm-cache", "npm cache", H + "/.npm/_cacache", "deleted", 700_000_000),
        item("uv-cache", "uv cache", H + "/.cache/uv", "deleted", 300_000_000),
    ], 4)
    add(5, 16, 40, 2, [
        item("lane-deps", "Idle lane dependencies", H + "/lane-builds/lane-a/node_modules", "deleted", 1_400_000_000),
        item("lane-deps", "Idle lane dependencies", H + "/lane-builds/lane-a/ios/Pods", "deleted", 900_000_000),
    ], 9, stopped=True)
    add(2, 14, 6, 4, [
        item("lane-deps", "Idle lane dependencies", H + "/lane-builds/lane-c/node_modules", "deleted", 3_600_000_000),
        item("uv-cache", "uv cache", H + "/.cache/uv", "deleted", 600_000_000),
        item("go-build", "Go build cache", H + "/Library/Caches/go-build", "deleted", 1_200_000_000),
    ], 3)
    add(2, 14, 20, 1, [
        item("docker", "Docker", "docker: unused images", "deleted", 9_000_000_000, inside="Docker's disk image"),
    ], 1)
elif scenario == "few":
    start_days = 3
    add(1, 14, 6, 4, [
        item("lane-deps", "Idle lane dependencies", H + "/lane-builds/lane-c/node_modules", "deleted", 3_600_000_000),
        item("uv-cache", "uv cache", H + "/.cache/uv", "deleted", 600_000_000),
        item("go-build", "Go build cache", H + "/Library/Caches/go-build", "deleted", 1_200_000_000),
    ], 3)
else:
    sys.exit("unknown scenario " + scenario)

runs.sort(key=lambda p: p[1])

if scenario == "full":
    big, big_fin = runs[0]
    later = runs[1:]
    t0 = now - dt.timedelta(days=start_days)
    before_big = 4.0 * GB
    t_big_start = dt.datetime.strptime(big["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    after_big = before_big + big["freed_bytes"]
    span_days = (now - big_fin).total_seconds() / 86400
    rate = (after_big + sum(r["freed_bytes"] for r, _ in later) - free_now) / span_days
    def free_at(t):
        if t < t_big_start:
            frac = (t - t0).total_seconds() / max((t_big_start - t0).total_seconds(), 1)
            return 11.0 * GB + (before_big - 11.0 * GB) * frac
        if t < big_fin:
            return before_big
        v = after_big - rate * (t - big_fin).total_seconds() / 86400
        for r, fin in later:
            if fin <= t: v += r["freed_bytes"]
        return v
else:
    decline_per_day = 0.38 * GB
    J = [(fin, r["freed_bytes"]) for r, fin in runs]
    def free_at(t):
        days = (now - t).total_seconds() / 86400
        v = free_now + decline_per_day * days
        for fin, freed in J:
            if fin > t: v -= freed
        return v

gap = None
if scenario == "full":
    gap = (now - dt.timedelta(days=11, hours=-6), now - dt.timedelta(days=9, hours=12))

samples = []
t = now - dt.timedelta(days=start_days)
while t <= now:
    if not (gap and gap[0] <= t <= gap[1]):
        samples.append((t, int(free_at(t) + rnd.uniform(-0.06, 0.06) * GB)))
    t += dt.timedelta(minutes=30, seconds=rnd.randint(-40, 40))
samples = [(t, v) for t, v in samples if t <= now]
assert min(v for _, v in samples) > 0, "the curve went below zero: pick a larger free-now"

final = []
for r, fin in runs:
    started = dt.datetime.strptime(r["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    r["free_before"] = int(free_at(started - dt.timedelta(seconds=1)))
    assert r["free_before"] > 0
    r["free_after"] = r["free_before"] + r["freed_bytes"] - rnd.randint(0, 40_000_000)
    final.append(r)

with open(os.path.join(state, "history.jsonl"), "w") as f:
    for r in final:
        f.write(json.dumps(r, separators=(",", ":"), ensure_ascii=False) + "\n")
with open(os.path.join(state, "free.jsonl"), "w") as f:
    for t, v in samples:
        f.write(json.dumps({"t": ts(t), "free_bytes": v, "capacity_bytes": cap}, separators=(",", ":")) + "\n")
for name in ("history.jsonl", "free.jsonl"):
    os.chmod(os.path.join(state, name), 0o600)
print(f"{scenario}: {len(final)} runs, {len(samples)} samples, free now {free_now/GB:.1f} GB -> {state}")
