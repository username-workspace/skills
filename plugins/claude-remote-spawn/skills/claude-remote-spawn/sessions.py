#!/usr/bin/env python3
"""Snapshot the live Claude Code sessions of this machine, and plan their restore after a reboot.

snapshot  — writes one file per boot (<boot>.json) listing the live interactive CLI sessions.
plan      — prints, one tab-separated line per session to restore, the newest snapshot taken
            before the current boot: name, session id, cwd, then the original launch flags.
"""
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time

SESSIONS_DIR = os.environ.get("CRS_SESSIONS_DIR", os.path.expanduser("~/.claude/sessions"))
SNAP_DIR = os.environ.get("CRS_SNAPSHOT_DIR", os.path.expanduser("~/.claude/session-snapshots"))
KEEP = 10
VALUED_FLAGS = {"--permission-mode", "--model", "--effort", "--add-dir", "--agent", "--settings"}
BARE_FLAGS = {"--dangerously-skip-permissions", "--chrome", "--ide"}


def boot_id():
    override = os.environ.get("CRS_BOOT_ID")
    if override:
        return override
    if sys.platform == "darwin":
        out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout
        return out.split("sec =", 1)[1].split(",", 1)[0].strip()
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("btime "):
                return line.split()[1]
    raise SystemExit("cannot read the boot time")


def ps_field(pid, field):
    env = dict(os.environ, LC_ALL="C", TZ="UTC0")
    out = subprocess.run(["ps", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True, env=env)
    return out.stdout.strip()


def alive(entry):
    pid = entry.get("pid")
    try:
        os.kill(pid, 0)
    except (OSError, TypeError):
        return False
    started = entry.get("procStart")
    return not started or " ".join(ps_field(pid, "lstart").split()) == " ".join(started.split())


def launch_flags(argv):
    tokens = shlex.split(argv) if argv else []
    kept, i = [], 1
    while i < len(tokens):
        tok = tokens[i]
        name, eq, _ = tok.partition("=")
        if tok in BARE_FLAGS:
            kept.append(tok)
        elif name in VALUED_FLAGS and eq:
            kept.append(tok)
        elif tok in VALUED_FLAGS and i + 1 < len(tokens):
            kept += [tok, tokens[i + 1]]
            i += 1
        elif tok in ("--remote-control", "--rc"):
            kept.append("--remote-control")
            if i + 1 < len(tokens) and not tokens[i + 1].startswith("-"):
                kept.append(tokens[i + 1])
                i += 1
        i += 1
    return kept


def registry():
    entries = []
    for fn in sorted(os.listdir(SESSIONS_DIR)) if os.path.isdir(SESSIONS_DIR) else []:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(SESSIONS_DIR, fn)) as f:
                entries.append(json.load(f))
        except (OSError, ValueError):
            continue
    return entries


def live_sessions():
    return [e for e in registry() if alive(e)]


def snapshot(quiet):
    if os.environ.get("CRS_SNAPSHOT") == "0":
        return
    sessions = []
    for e in live_sessions():
        if e.get("kind") != "interactive" or e.get("entrypoint") != "cli":
            continue
        sessions.append({
            "sessionId": e["sessionId"],
            "name": e.get("name") or "",
            "cwd": e.get("cwd") or "",
            "flags": launch_flags(ps_field(e["pid"], "args")),
            "status": e.get("status") or "",
        })
    os.makedirs(SNAP_DIR, exist_ok=True)
    boot = boot_id()
    path = os.path.join(SNAP_DIR, boot + ".json")
    body = {"boot": boot, "takenAt": int(time.time()), "sessions": sessions}
    fd, tmp = tempfile.mkstemp(dir=SNAP_DIR, prefix=".snap-")
    with os.fdopen(fd, "w") as f:
        json.dump(body, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
    snaps = sorted((s for s in os.listdir(SNAP_DIR) if s.endswith(".json")), key=lambda s: os.path.getmtime(os.path.join(SNAP_DIR, s)))
    for old in snaps[:-KEEP]:
        os.remove(os.path.join(SNAP_DIR, old))
    if not quiet:
        print("snapshot: %d session(s) -> %s" % (len(sessions), path))
        for s in sessions:
            print("  %-28s %s  %s" % (s["name"] or "(unnamed)", s["sessionId"], s["cwd"]))


def previous_snapshot():
    current = boot_id()
    if not os.path.isdir(SNAP_DIR):
        return None
    candidates = [s for s in os.listdir(SNAP_DIR) if s.endswith(".json") and s != current + ".json"]
    if not candidates:
        return None
    newest = max(candidates, key=lambda s: os.path.getmtime(os.path.join(SNAP_DIR, s)))
    return os.path.join(SNAP_DIR, newest)


def plan(path):
    path = path or previous_snapshot()
    if not path:
        raise SystemExit("no snapshot from a previous boot under %s" % SNAP_DIR)
    with open(path) as f:
        snap = json.load(f)
    live_ids = {e.get("sessionId") for e in live_sessions()}
    print("# " + path)
    for s in snap.get("sessions", []):
        state = "live" if s["sessionId"] in live_ids else ("nocwd" if not os.path.isdir(s["cwd"]) else "restore")
        print("\t".join([state, s["name"] or s["sessionId"][:8], s["sessionId"], s["cwd"]] + s["flags"]))


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else ""
    if cmd == "snapshot":
        snapshot("--quiet" in args)
    elif cmd == "plan":
        plan(args[1] if len(args) > 1 else None)
    else:
        raise SystemExit("usage: sessions.py snapshot [--quiet] | plan [snapshot.json]")


if __name__ == "__main__":
    main()
