#!/usr/bin/env python3
"""Snapshot the Warp layout with the Claude Code session each pane runs, and restore it after a reboot.

snapshot  one file per boot: Warp's windows, tab groups, tabs and pane splits, read from Warp's own
          state database, with the live Claude Code session of each pane matched by its pane uuid.
show      print the snapshot a restore would use.
restore   reopen that snapshot, each Claude pane resuming its session in place: in the window of the
          Warp already running as one Tab Config per tab, else as a launch configuration that starts
          Warp with its windows and tab groups; then wait until each of those sessions runs again.
check     what the machine offers: Warp's database, the launch configurations folder, Warp's plugin
          for Claude Code notifications.
"""
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

HOME = os.path.expanduser("~")
MAC = sys.platform == "darwin"
DEFAULT_DB = (HOME + "/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite"
              if MAC else os.environ.get("XDG_STATE_HOME", HOME + "/.local/state") + "/warp-terminal/warp.sqlite")
DEFAULT_LAUNCH = (HOME + "/.warp/launch_configurations" if MAC
                  else os.environ.get("XDG_DATA_HOME", HOME + "/.local/share") + "/warp-terminal/launch_configurations")
WARP_DB = os.environ.get("WS_WARP_DB", DEFAULT_DB)
LAUNCH_DIR = os.environ.get("WS_LAUNCH_DIR", DEFAULT_LAUNCH)
TAB_DIR = os.environ.get("WS_TAB_DIR", HOME + "/.warp/tab_configs" if MAC
                         else os.environ.get("XDG_DATA_HOME", HOME + "/.local/share") + "/warp-terminal/tab_configs")
SESSIONS_DIR = os.environ.get("WS_SESSIONS_DIR", HOME + "/.claude/sessions")
SNAP_DIR = os.environ.get("WS_SNAPSHOT_DIR", HOME + "/.claude/warp-snapshots")
CONFIG_NAME = "warp-session-restore"
KEEP = 10
# Warp's pane_branches.horizontal → the launch configuration's split_direction.
SPLIT = {1: "horizontal", 0: "vertical"}
VALUED_FLAGS = {"--permission-mode", "--model", "--effort", "--add-dir", "--agent", "--settings"}
BARE_FLAGS = {"--dangerously-skip-permissions", "--chrome", "--ide"}
UUID_RE = re.compile(r"WARP_TERMINAL_SESSION_UUID=([0-9A-Fa-f]{32})")


def boot_id():
    if os.environ.get("WS_BOOT_ID"):
        return os.environ["WS_BOOT_ID"]
    if MAC:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True).stdout
        return out.split("sec =", 1)[1].split(",", 1)[0].strip()
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("btime "):
                return line.split()[1]
    raise SystemExit("cannot read the boot time")


def ps(pid, field):
    env = dict(os.environ, LC_ALL="C", TZ="UTC0")
    return subprocess.run(["ps", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True, env=env).stdout.strip()


def pane_uuid(pid):
    if MAC:
        env = subprocess.run(["ps", "-E", "-ww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    else:
        try:
            with open("/proc/%d/environ" % pid, "rb") as f:
                env = f.read().decode("utf-8", "replace").replace("\0", " ")
        except OSError:
            return None
    found = UUID_RE.findall(env)
    return found[-1].upper() if found else None


def alive(entry):
    pid = entry.get("pid")
    try:
        os.kill(pid, 0)
    except (OSError, TypeError):
        return False
    started = entry.get("procStart")
    return not started or " ".join(ps(pid, "lstart").split()) == " ".join(started.split())


def launch_flags(argv):
    tokens = shlex.split(argv) if argv else []
    kept, i = [], 1
    while i < len(tokens):
        tok = tokens[i]
        name, eq, _ = tok.partition("=")
        if tok in BARE_FLAGS or (name in VALUED_FLAGS and eq):
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


def live_claude_sessions():
    sessions = []
    names = sorted(os.listdir(SESSIONS_DIR)) if os.path.isdir(SESSIONS_DIR) else []
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(SESSIONS_DIR, fn)) as f:
                e = json.load(f)
        except (OSError, ValueError):
            continue
        if e.get("kind") == "interactive" and e.get("entrypoint") == "cli" and alive(e):
            sessions.append(e)
    return sessions


def color(raw):
    if not raw:
        return None
    m = re.search(r"Color:\s*(\w+)", raw)
    return (m.group(1) if m else raw.strip()).lower() or None


def connect():
    if not os.path.exists(WARP_DB):
        raise SystemExit("Warp's state database not found: %s" % WARP_DB)
    return sqlite3.connect("file:%s?mode=ro" % quote(WARP_DB), uri=True)


def pane_tree(con, tab_id):
    rows = con.execute(
        "SELECT n.id, n.parent_pane_node_id, n.is_leaf, b.horizontal, l.kind, l.is_focused, t.cwd, hex(t.uuid) "
        "FROM pane_nodes n LEFT JOIN pane_branches b ON b.pane_node_id = n.id "
        "LEFT JOIN pane_leaves l ON l.pane_node_id = n.id LEFT JOIN terminal_panes t ON t.id = n.id "
        "WHERE n.tab_id = ? ORDER BY n.id", (tab_id,)).fetchall()
    nodes = {r[0]: r for r in rows}
    children = {}
    for r in rows:
        children.setdefault(r[1], []).append(r[0])

    def build(nid):
        _, _, is_leaf, horizontal, kind, focused, cwd, uuid = nodes[nid]
        if is_leaf:
            if kind != "terminal":
                return None
            return {"cwd": cwd or "", "focused": bool(focused), "uuid": uuid}
        kids = [k for k in (build(c) for c in children.get(nid, [])) if k]
        if len(kids) < 2:
            return kids[0] if kids else None
        return {"split": SPLIT[1 if horizontal else 0], "panes": kids}

    roots = children.get(None, [])
    return build(roots[0]) if roots else None


def warp_layout():
    con = connect()
    try:
        windows = []
        for wid, active in con.execute("SELECT id, active_tab_index FROM windows ORDER BY id").fetchall():
            groups = {g[0]: {"id": g[0], "name": g[1] or "", "color": color(g[2]), "collapsed": bool(g[3]), "pinned": bool(g[4])}
                      for g in con.execute("SELECT id, name, color, collapsed, pinned FROM tab_groups WHERE window_id = ?", (wid,))}
            tabs = []
            for tid, title, tcolor, gid in con.execute(
                    "SELECT id, custom_title, color, tab_group_id FROM tabs WHERE window_id = ? ORDER BY id", (wid,)).fetchall():
                layout = pane_tree(con, tid)
                if layout:
                    tabs.append({"title": title or "", "color": color(tcolor), "group": groups.get(gid), "layout": layout})
            if tabs:
                windows.append({"active_tab_index": min(active, len(tabs) - 1), "tabs": tabs})
        return windows
    finally:
        con.close()


def leaves(node):
    if "panes" in node:
        for p in node["panes"]:
            for leaf in leaves(p):
                yield leaf
    else:
        yield node


def snapshot(quiet):
    if os.environ.get("WS_SNAPSHOT") == "0":
        return
    windows = warp_layout()
    by_uuid = {leaf["uuid"]: leaf for w in windows for t in w["tabs"] for leaf in leaves(t["layout"])}
    outside = []
    for e in live_claude_sessions():
        session = {"sessionId": e["sessionId"], "name": e.get("name") or "", "cwd": e.get("cwd") or "",
                   "flags": launch_flags(ps(e["pid"], "args"))}
        leaf = by_uuid.get(pane_uuid(e["pid"]) or "")
        if leaf is not None:
            leaf["claude"] = session
        else:
            outside.append(session)
    os.makedirs(SNAP_DIR, exist_ok=True)
    boot = boot_id()
    path = os.path.join(SNAP_DIR, boot + ".json")
    fd, tmp = tempfile.mkstemp(dir=SNAP_DIR, prefix=".snap-")
    with os.fdopen(fd, "w") as f:
        json.dump({"boot": boot, "takenAt": int(time.time()), "windows": windows, "outside": outside}, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
    snaps = sorted((s for s in os.listdir(SNAP_DIR) if s.endswith(".json")),
                   key=lambda s: os.path.getmtime(os.path.join(SNAP_DIR, s)))
    for old in snaps[:-KEEP]:
        os.remove(os.path.join(SNAP_DIR, old))
    if not quiet:
        print("snapshot -> %s" % path)
        show(path)


def pick(args):
    if "--from" in args:
        return args[args.index("--from") + 1]
    current = boot_id() + ".json"
    snaps = [s for s in os.listdir(SNAP_DIR) if s.endswith(".json")] if os.path.isdir(SNAP_DIR) else []
    if "--current" not in args:
        snaps = [s for s in snaps if s != current]
    if not snaps:
        raise SystemExit("no snapshot %s under %s" % ("at all" if "--current" in args else "from a previous boot", SNAP_DIR))
    return os.path.join(SNAP_DIR, max(snaps, key=lambda s: os.path.getmtime(os.path.join(SNAP_DIR, s))))


def load(path):
    with open(path) as f:
        return json.load(f)


def describe(node, depth):
    pad = "    " * depth
    if "panes" in node:
        print("%s%s split" % (pad, node["split"]))
        for p in node["panes"]:
            describe(p, depth + 1)
        return
    c = node.get("claude")
    print("%s%s%s" % (pad, ("claude %s (%s)" % (c["name"] or "-", c["sessionId"])) if c else "shell", "  " + (c["cwd"] if c else node["cwd"])))


def show(path):
    snap = load(path)
    for i, w in enumerate(snap["windows"]):
        print("window %d" % (i + 1))
        for t in w["tabs"]:
            g = t.get("group")
            print("  tab %s%s" % (t["title"] or "(untitled)", ("  [group %s, %s]" % (g["name"], g["color"])) if g else ""))
            describe(t["layout"], 2)
    for s in snap.get("outside", []):
        print("outside Warp: claude %s (%s)  %s" % (s["name"] or "-", s["sessionId"], s["cwd"]))


def q(value):
    return json.dumps(value, ensure_ascii=False)


def warp_running():
    marker = "/Warp.app/Contents/MacOS/" if MAC else "warp-terminal"
    out = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True).stdout
    return any(marker in line for line in out.splitlines())


def leaf_plan(node, live_ids, report, resumed):
    c = node.get("claude")
    cwd = (c["cwd"] if c else node["cwd"]) or HOME
    if c and c["sessionId"] in live_ids:
        report.append("= %s: already running, its pane opens a shell (%s)" % (c["name"] or c["sessionId"], c["sessionId"]))
    elif c and not os.path.isdir(c["cwd"]):
        report.append("! %s: %s no longer exists, its pane opens a shell (%s)" % (c["name"] or c["sessionId"], c["cwd"], c["sessionId"]))
        cwd = HOME
    elif c:
        argv = ["claude", "--resume", c["sessionId"]] + (["-n", c["name"]] if c["name"] else []) + c["flags"]
        report.append("+ %s: resumes %s in %s" % (c["name"] or c["sessionId"], c["sessionId"], c["cwd"]))
        resumed.append(c["sessionId"])
        return cwd, " ".join(shlex.quote(a) for a in argv)
    return cwd, None


def tab_title(tab):
    claude = [leaf["claude"] for leaf in leaves(tab["layout"]) if leaf.get("claude")]
    return tab["title"] or (claude[0]["name"] if claude and claude[0]["name"] else "")


def tab_toml(tab, name, path, live_ids, report, resumed):
    panes = []

    def walk(node):
        entry = {"id": "p%d" % len(panes)}
        panes.append(entry)
        if "panes" in node:
            entry["split"] = node["split"]
            entry["children"] = [walk(p) for p in node["panes"]]
        else:
            cwd, command = leaf_plan(node, live_ids, report, resumed)
            entry.update({"type": "terminal", "directory": cwd, "commands": [command] if command else []})
            if node.get("focused"):
                entry["is_focused"] = True
        return entry["id"]

    walk(tab["layout"])
    first = next(e for e in panes if "type" in e)
    first["commands"].insert(0, "rm -f " + shlex.quote(path))
    lines = ["name = %s" % q(name), "title = %s" % q(tab_title(tab))]
    if tab.get("color"):
        lines.append("color = %s" % q(tab["color"]))
    for e in panes:
        lines += ["", "[[panes]]"] + ["%s = %s" % (k, json.dumps(v, ensure_ascii=False)) for k, v in e.items()]
    return "\n".join(lines) + "\n"


def pane_yaml(node, pad, live_ids, report, resumed):
    lines = []
    if "panes" in node:
        lines.append("%ssplit_direction: %s" % (pad, node["split"]))
        lines.append("%spanes:" % pad)
        for p in node["panes"]:
            sub = pane_yaml(p, pad + "    ", live_ids, report, resumed)
            lines.append(pad + "  - " + sub[0].lstrip())
            lines += sub[1:]
        return lines
    cwd, command = leaf_plan(node, live_ids, report, resumed)
    lines.append("%scwd: %s" % (pad, q(cwd)))
    if node.get("focused"):
        lines.append("%sis_focused: true" % pad)
    if command:
        lines += ["%scommands:" % pad, "%s  - exec: %s" % (pad, q(command))]
    return lines


def wanted(tab, names):
    if not names:
        return True
    return any(leaf.get("claude") and (leaf["claude"]["name"] in names or leaf["claude"]["sessionId"] in names)
               for leaf in leaves(tab["layout"]))


def launch_yaml(snap, live_ids, report, resumed, names):
    lines = ["---", "name: %s" % CONFIG_NAME, "windows:"]
    for w in snap["windows"]:
        if not any(wanted(t, names) for t in w["tabs"]):
            continue
        order, runs = [], []
        for i, t in enumerate(w["tabs"]):
            if not wanted(t, names):
                continue
            g = t.get("group")
            gid = g["id"] if g else None
            if gid is None:
                runs.append([(i, t)])
            elif gid in [x["id"] for x in order]:
                next(r for r in runs if r[0][1].get("group") and r[0][1]["group"]["id"] == gid).append((i, t))
            else:
                order.append(g)
                runs.append([(i, t)])
        tabs = [pair for run in runs for pair in run]
        active = next((n for n, (i, _) in enumerate(tabs) if i == w["active_tab_index"]), 0)
        lines.append("  - active_tab_index: %d" % active)
        if order:
            lines.append("    tab_groups:")
            for g in order:
                lines.append("      - name: %s" % q(g["name"]))
                if g["color"]:
                    lines.append("        color: %s" % g["color"])
                lines += ["        collapsed: %s" % str(g["collapsed"]).lower(), "        pinned: %s" % str(g["pinned"]).lower()]
        lines.append("    tabs:")
        for _, t in tabs:
            lines.append("      - title: %s" % q(tab_title(t)))
            if t.get("color"):
                lines.append("        color: %s" % t["color"])
            if t.get("group"):
                lines.append("        group: %d" % [x["id"] for x in order].index(t["group"]["id"]))
            lines.append("        layout:")
            lines += pane_yaml(t["layout"], "          ", live_ids, report, resumed)
    return "\n".join(lines) + "\n"


def restore(args):
    path = pick(args)
    snap = load(path)
    live_ids = {e["sessionId"] for e in live_claude_sessions()}
    report, resumed = [], []
    names = {a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--from")}
    if not any(wanted(t, names) for w in snap["windows"] for t in w["tabs"]):
        raise SystemExit("no tab of %s holds a session named %s" % (path, ", ".join(sorted(names))))
    in_window = "--window" not in args and warp_running()
    files = []
    if in_window:
        for t in [t for w in snap["windows"] for t in w["tabs"] if wanted(t, names)]:
            name = "%s-%d" % (CONFIG_NAME, len(files) + 1)
            path_toml = os.path.join(TAB_DIR, name + ".toml")
            tab_report, tab_resumed = [], []
            body = tab_toml(t, name, path_toml, live_ids, tab_report, tab_resumed)
            report += tab_report
            if tab_resumed:
                resumed += tab_resumed
                files.append((name, path_toml, body))
        if any(t.get("group") for w in snap["windows"] for t in w["tabs"] if wanted(t, names)):
            report.append("~ tab groups come back only in a new window: restore --window")
    else:
        files.append((CONFIG_NAME + ".yaml", os.path.join(LAUNCH_DIR, CONFIG_NAME + ".yaml"),
                      launch_yaml(snap, live_ids, report, resumed, names)))
    print("snapshot: %s" % path)
    print("opens in: %s" % ("the Warp window already open, one tab per session tab" if in_window
                            else "a new Warp window per snapshot window"))
    for line in report:
        print(line)
    for s in snap.get("outside", []):
        print("~ %s: ran outside Warp, not restored (%s)" % (s["name"] or s["sessionId"], s["sessionId"]))
    if "--dry-run" in args:
        for _, _, body in files:
            sys.stdout.write(body)
        return
    opener = os.environ.get("WS_OPEN", "open" if MAC else "xdg-open")
    for n, (name, target, body) in enumerate(files):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            f.write(body)
        if n:
            time.sleep(1)
        subprocess.run([opener, ("warp://tab_config/" if in_window else "warp://launch/") + quote(name)], check=False)
    pending = set(resumed)
    deadline = time.time() + float(os.environ.get("WS_OPEN_WAIT", "30"))
    while pending and time.time() < deadline:
        pending -= {e["sessionId"] for e in live_claude_sessions()}
        if pending:
            time.sleep(1)
    if pending:
        manual = ("its tab from Warp's + menu: %s" % ", ".join(n for n, p, _ in files if os.path.exists(p)) if in_window
                  else "File > Launch Configurations > %s" % CONFIG_NAME)
        print("! not back yet: %s — if Warp opened nothing (locked screen), open %s"
              % (", ".join(sorted(pending)), manual))
        sys.exit(1)
    print("restored: every Claude session is running again")


def check():
    print("warp db  : %s" % ("ok " + WARP_DB if os.path.exists(WARP_DB) else "NOT FOUND " + WARP_DB))
    print("launch   : %s" % LAUNCH_DIR)
    settings = os.path.join(HOME, ".claude", "settings.json")
    try:
        with open(settings) as f:
            enabled = json.load(f).get("enabledPlugins", {}).get("warp@claude-code-warp") is True
    except (OSError, ValueError):
        enabled = False
    print("notify   : %s" % ("Warp's Claude Code plugin enabled (agent notifications)" if enabled else
                             "Warp's Claude Code plugin missing — claude plugin marketplace add warpdotdev/claude-code-warp && claude plugin install warp@claude-code-warp"))
    snaps = sorted(os.listdir(SNAP_DIR)) if os.path.isdir(SNAP_DIR) else []
    print("snapshots: %d under %s" % (len([s for s in snaps if s.endswith(".json")]), SNAP_DIR))


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else ""
    if cmd == "snapshot":
        snapshot("--quiet" in args)
    elif cmd == "show":
        show(pick(args[1:]))
    elif cmd == "restore":
        restore(args[1:])
    elif cmd == "check":
        check()
    else:
        raise SystemExit("usage: warp_session_restore.py snapshot [--quiet] | show [--current|--from F] | "
                         "restore [--dry-run] [--window] [--current|--from F] [name...] | check")


if __name__ == "__main__":
    main()
