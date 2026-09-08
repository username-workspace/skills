#!/usr/bin/env python3
"""Orchestrator registry: what the harness does not track about the sessions this one pilots.

Liveness, state, blocking reason and final result come from the harness itself on every read
(`claude agents --json --all`, then `~/.claude/jobs/<id>/state.json` and `~/.claude/sessions/<pid>.json`).
The registry only keeps the orders (tag, verdict), the claude.ai ids, and the targets on other machines.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
from datetime import datetime, timezone

VERDICTS = ("ok", "error", "blocked", "timeout")
FIELDS = ("bridge_id", "local_id", "machine", "cwd", "role", "note")
ISO = "%Y-%m-%dT%H:%M:%SZ"


def config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def home():
    return os.environ.get("ORCHESTRATOR_HOME") or os.path.join(config_dir(), "orchestrator")


def registry_path():
    return os.path.join(home(), "registry.json")


def machine():
    return socket.gethostname().split(".")[0]


def now():
    return datetime.now(timezone.utc).strftime(ISO)


def age(stamp):
    if not stamp:
        return ""
    try:
        parsed = datetime.strptime(stamp.split(".")[0].rstrip("Z") + "Z", ISO).replace(tzinfo=timezone.utc)
    except ValueError:
        return ""
    minutes = max(int((datetime.now(timezone.utc) - parsed).total_seconds() // 60), 0)
    if minutes < 60:
        return "%dm" % minutes
    if minutes < 1440:
        return "%dh" % (minutes // 60)
    return "%dd" % (minutes // 1440)


def shorten(text, width=72):
    return text if len(text) <= width else text[:width - 1] + "…"


def read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (IOError, OSError, ValueError):
        return None


def load():
    data = read_json(registry_path())
    if not isinstance(data, dict) or not isinstance(data.get("targets"), list):
        return {"targets": []}
    return data


def save(data):
    if not os.path.isdir(home()):
        os.makedirs(home())
    tmp = registry_path() + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, registry_path())


def find(data, name):
    for entry in data["targets"]:
        if entry.get("name") == name:
            return entry
    return None


def find_local(data, local_id):
    for entry in data["targets"]:
        if local_id and entry.get("local_id") == local_id:
            return entry
    return None


def upsert(data, name):
    entry = find(data, name)
    if entry is None:
        entry = {"name": name, "status": "idle"}
        data["targets"].append(entry)
    return entry


def die(message, code=1):
    sys.stderr.write(message + "\n")
    raise SystemExit(code)


def is_self(local_id, bridge_id):
    uuid = os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    bridge = os.environ.get("CLAUDE_CODE_BRIDGE_SESSION_ID") or ""
    own_local = bool(local_id) and bool(uuid) and (local_id == uuid or uuid.startswith(local_id + "-"))
    own_bridge = bool(bridge_id) and bridge_id == bridge
    return own_local or own_bridge


def harness_rows():
    binary = os.environ.get("CLAUDE_CODE_EXECPATH") or "claude"
    try:
        run = subprocess.run([binary, "agents", "--json", "--all"], capture_output=True, text=True, timeout=30)
        rows = json.loads(run.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    return rows if isinstance(rows, list) else None


def live_view():
    rows = harness_rows()
    if rows is None:
        sys.stderr.write("harness unavailable: `claude agents --json` did not answer, showing the registry alone\n")
        return {}
    view = {}
    for row in rows:
        background = row.get("kind") == "background"
        local_id = row.get("id") if background else row.get("sessionId")
        if not local_id:
            continue
        entry = {"name": row.get("name"), "kind": row.get("kind"), "cwd": row.get("cwd"),
                 "local_id": local_id, "alive": bool(row.get("pid")), "state": row.get("state") or row.get("status") or "offline",
                 "waiting_for": row.get("waitingFor"), "bridge_id": None, "needs": None, "result": None,
                 "updated_at": None}
        if background:
            job = read_json(os.path.join(config_dir(), "jobs", local_id, "state.json")) or {}
            entry["bridge_id"] = job.get("bridgeSessionId")
            entry["needs"] = job.get("needs")
            output = job.get("output")
            entry["result"] = output.get("result") if isinstance(output, dict) else None
            entry["updated_at"] = job.get("updatedAt")
        elif row.get("pid"):
            registered = read_json(os.path.join(config_dir(), "sessions", "%s.json" % row["pid"])) or {}
            entry["bridge_id"] = registered.get("bridgeSessionId")
        entry["self"] = is_self(local_id, entry["bridge_id"])
        view[local_id] = entry
    return view


def pilot_name(view):
    for entry in view.values():
        if entry["self"]:
            return entry.get("name") or entry["local_id"]
    return None


def live_for(view, target):
    entry = view.get(target.get("local_id"))
    if entry is None and target.get("name"):
        entry = next((e for e in view.values() if e.get("name") == target["name"]), None)
    return entry


def describe(target, live):
    if live is None:
        return "remote" if target.get("machine") not in (None, machine()) else "offline"
    state = live["state"]
    if live.get("needs"):
        suffix = " (%s)" % live["waiting_for"] if live.get("waiting_for") else ""
        return "blocked: %s%s" % (live["needs"], suffix)
    if live.get("waiting_for"):
        return "waiting: %s" % live["waiting_for"]
    if state in ("done", "failed") and live.get("result"):
        return "%s: %s" % (state, live["result"])
    return state


def cmd_sync(args):
    data = load()
    view = live_view()
    touched = []
    for entry in view.values():
        if entry["self"] or not entry.get("name"):
            continue
        target = find_local(data, entry["local_id"]) or upsert(data, entry["name"])
        target["name"] = entry["name"]
        target["local_id"] = entry["local_id"]
        target["kind"] = entry["kind"]
        target["machine"] = machine()
        if entry.get("cwd"):
            target["cwd"] = entry["cwd"]
        if entry.get("bridge_id"):
            target["bridge_id"] = entry["bridge_id"]
        target["seen"] = now()
        touched.append(entry["name"])
    save(data)
    pilot = pilot_name(view)
    if args.json:
        print(json.dumps({"pilot": pilot, "synced": touched, "machine": machine()}, indent=2, sort_keys=True))
        return 0
    if pilot:
        print("pilot: %s" % pilot)
    if touched:
        print("synced %d local session(s): %s" % (len(touched), ", ".join(touched)))
    else:
        print("no other local session — add remote targets with `orchestrator.py add <name> --bridge-id ...`")
    return 0


def cmd_add(args):
    data = load()
    entry = upsert(data, args.name)
    for field in FIELDS:
        value = getattr(args, field)
        if value is not None:
            entry[field] = value
    entry["seen"] = now()
    save(data)
    print("registered %s" % args.name)
    return 0


def cmd_assign(args):
    data = load()
    holder = next((e for e in data["targets"]
                   if e.get("tag") == args.tag and e.get("status") == "busy" and e.get("name") != args.name), None)
    if holder is not None:
        die("tag %s is already running on %s — one tag identifies one order" % (args.tag, holder["name"]), 2)
    entry = upsert(data, args.name)
    view = live_view()
    if is_self(entry.get("local_id"), entry.get("bridge_id")) or args.name == pilot_name(view):
        die("%s is this session — the orchestrator dispatches orders, it does not receive them" % args.name, 2)
    if entry.get("status") == "busy" and entry.get("tag") != args.tag:
        die("%s is still running %s — resolve it before sending another order" % (args.name, entry["tag"]), 2)
    live = live_for(view, entry)
    if live is not None and live["kind"] == "interactive" and live["state"] == "busy":
        sys.stderr.write("warning: %s is busy right now — the order will be read mid-turn, inside its current task; "
                         "prefer an idle session or `claude --bg`\n" % args.name)
    entry["status"] = "busy"
    entry["tag"] = args.tag
    entry["assigned_at"] = now()
    entry["seen"] = entry["assigned_at"]
    entry.pop("verdict", None)
    entry.pop("resolved_at", None)
    if args.note is not None:
        entry["note"] = args.note
    save(data)
    print("%s <- %s" % (args.name, args.tag))
    return 0


def cmd_resolve(args):
    data = load()
    entry = find(data, args.name)
    if entry is None:
        die("unknown target %s" % args.name)
    if args.tag is not None and entry.get("tag") != args.tag:
        die("%s is running %s, not %s" % (args.name, entry.get("tag", "nothing"), args.tag), 2)
    entry["status"] = "idle"
    entry["verdict"] = args.verdict
    entry["resolved_at"] = now()
    entry["seen"] = entry["resolved_at"]
    if args.note is not None:
        entry["note"] = args.note
    save(data)
    print("%s %s %s" % (args.name, entry.get("tag", "-"), args.verdict))
    return 0


def cmd_forget(args):
    data = load()
    remaining = [e for e in data["targets"] if e.get("name") != args.name]
    if len(remaining) == len(data["targets"]):
        die("unknown target %s" % args.name)
    data["targets"] = remaining
    save(data)
    print("forgot %s" % args.name)
    return 0


def merged(data, view):
    rows = []
    for target in sorted(data["targets"], key=lambda e: e.get("name", "")):
        live = live_for(view, target)
        rows.append({"target": target, "live": live, "harness": describe(target, live),
                     "bridge_id": target.get("bridge_id") or (live or {}).get("bridge_id")})
    return rows


def cmd_list(args):
    data = load()
    view = live_view()
    rows = merged(data, view)
    if args.json:
        print(json.dumps({"pilot": pilot_name(view), "targets": rows}, indent=2, sort_keys=True))
        return 0
    pilot = pilot_name(view)
    if pilot:
        print("pilot: %s" % pilot)
    if not rows:
        print("no target registered — run `orchestrator.py sync`, or add one with `orchestrator.py add <name> --bridge-id session_01...`")
        return 0
    table = [("NAME", "KIND", "HARNESS", "ORDER", "VERDICT", "BRIDGE_ID")]
    for row in rows:
        target = row["target"]
        table.append((target.get("name", "?"), target.get("kind", "-"), shorten(row["harness"]),
                      target.get("tag", "-") if target.get("status") == "busy" else "-",
                      target.get("verdict", "-"), row["bridge_id"] or "(none — cannot be read back)"))
    widths = [max(len(r[i]) for r in table) for i in range(len(table[0]))]
    for r in table:
        print("  ".join(value.ljust(widths[i]) for i, value in enumerate(r)).rstrip())
    return 0


def bucket(row):
    target, live = row["target"], row["live"]
    if live is not None and not live["alive"] and live["kind"] == "background":
        return "exited"
    if live is not None and (live.get("waiting_for") or live["state"] == "blocked"):
        return "input"
    if live is not None and live["state"] in ("working", "busy"):
        return "working"
    if live is not None and live["state"] in ("done", "failed"):
        return "finished"
    if target.get("status") == "busy":
        return "order"
    if target.get("verdict") in ("error", "blocked", "timeout"):
        return "attention"
    if live is None:
        return "remote" if row["harness"] == "remote" else "offline"
    return "ready"


def cmd_report(args):
    data = load()
    view = live_view()
    rows = merged(data, view)
    groups = {}
    for row in rows:
        groups.setdefault(bucket(row), []).append(row)
    if args.json:
        print(json.dumps({"pilot": pilot_name(view), "groups": groups}, indent=2, sort_keys=True))
        return 0
    pilot = pilot_name(view)
    if pilot:
        print("pilot: %s" % pilot)
    open_orders = [r for r in rows if r["target"].get("status") == "busy"]
    print("%d target(s) — %d need input, %d working, %d open order(s), %d finished, %d exited"
          % (len(rows), len(groups.get("input", [])), len(groups.get("working", [])),
             len(open_orders), len(groups.get("finished", [])), len(groups.get("exited", []))))
    labels = (("input", "NEEDS INPUT"), ("working", "WORKING"), ("order", "OPEN ORDER"),
              ("finished", "FINISHED"), ("exited", "EXITED"), ("attention", "ATTENTION"), ("ready", "ready"),
              ("remote", "remote"), ("offline", "offline"))
    for key, label in labels:
        for row in groups.get(key, []):
            target = row["target"]
            extra = ""
            if key == "order":
                extra = "%s since %s — harness: %s" % (target.get("tag"), age(target.get("assigned_at")), row["harness"])
            elif key == "attention":
                extra = "%s %s %s" % (target.get("verdict"), target.get("tag", "-"), target.get("note", ""))
            elif key == "ready":
                extra = "last %s %s" % (target.get("verdict", "-"), age(target.get("resolved_at")))
            elif key in ("finished", "exited") and row["live"].get("updated_at"):
                extra = "%s · %s ago · claude rm %s to clear" % (row["harness"], age(row["live"]["updated_at"]), target.get("local_id"))
            else:
                extra = row["harness"]
            if key != "order" and target.get("status") == "busy":
                extra += " · order %s since %s" % (target.get("tag"), age(target.get("assigned_at")))
                if key == "finished":
                    extra += " → resolve it"
            print(("  %-12s %s  %s" % (label, target.get("name"), extra)).rstrip())
    for row in rows:
        if not row["bridge_id"]:
            print("  %-12s %s — no claude.ai id, get_run_log cannot read it" % ("NO ID", row["target"].get("name")))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="orchestrator.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    sync = sub.add_parser("sync", help="import this machine's sessions from the harness")
    sync.add_argument("--json", action="store_true")
    sync.set_defaults(func=cmd_sync)

    add = sub.add_parser("add", help="register or update a target (remote ones especially)")
    add.add_argument("name")
    for field in FIELDS:
        add.add_argument("--" + field.replace("_", "-"), dest=field, default=None)
    add.set_defaults(func=cmd_add)

    assign = sub.add_parser("assign", help="record an order sent to a target")
    assign.add_argument("name")
    assign.add_argument("tag")
    assign.add_argument("--note", default=None)
    assign.set_defaults(func=cmd_assign)

    resolve = sub.add_parser("resolve", help="close the order running on a target")
    resolve.add_argument("name")
    resolve.add_argument("verdict", choices=VERDICTS)
    resolve.add_argument("--tag", default=None)
    resolve.add_argument("--note", default=None)
    resolve.set_defaults(func=cmd_resolve)

    forget = sub.add_parser("forget", help="drop a target")
    forget.add_argument("name")
    forget.set_defaults(func=cmd_forget)

    listing = sub.add_parser("list", help="registry joined with the live harness state")
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(func=cmd_list)

    report = sub.add_parser("report", help="what needs input, what works, what finished")
    report.add_argument("--json", action="store_true")
    report.set_defaults(func=cmd_report)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
