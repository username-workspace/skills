#!/usr/bin/env python3
"""Snapshot the Claude Code sessions running on this machine, and reopen them in Warp after a reboot.

snapshot  one file per boot: each live Claude Code CLI session, its folder, name, launch flags and the
          group of its folder (the git repository it runs in, worktrees included, else the folder).
show      print the snapshot a restore would use.
restore   reopen each session in Warp, one tab per session, `claude --resume <id>` in place, grouped by
          folder: in the window of the Warp already running, one Tab Config per session, else as a launch
          configuration that starts Warp with one tab group per folder; then wait until they run again.
check     what the machine offers: the launch configurations and Tab Configs folders, Warp's plugin for
          Claude Code notifications, the snapshots.
"""
import ctypes
import ctypes.util
import json
import os
import select
import shlex
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

HOME = os.path.expanduser("~")
MAC = sys.platform == "darwin"
DATA = os.environ.get("XDG_DATA_HOME", HOME + "/.local/share") + "/warp-terminal"
LAUNCH_DIR = os.environ.get("WS_LAUNCH_DIR", HOME + "/.warp/launch_configurations" if MAC else DATA + "/launch_configurations")
TAB_DIR = os.environ.get("WS_TAB_DIR", HOME + "/.warp/tab_configs" if MAC else DATA + "/tab_configs")
SESSIONS_DIR = os.environ.get("WS_SESSIONS_DIR", HOME + "/.claude/sessions")
SNAP_DIR = os.environ.get("WS_SNAPSHOT_DIR", HOME + "/.claude/warp-snapshots")
CONFIG_NAME = "warp-session-restore"
KEEP = 10
COLORS = ["blue", "green", "yellow", "magenta", "cyan", "red"]
VALUED_FLAGS = {"--permission-mode", "--model", "--effort", "--add-dir", "--agent", "--settings"}
BARE_FLAGS = {"--dangerously-skip-permissions", "--chrome", "--ide"}
SHELLS = {"bash", "sh", "zsh"}
ENDED = {"prompt_input_exit", "clear", "logout"}
DETACH_DRIVER = os.environ.get("WS_DETACH_DRIVER", HOME + "/.claude/skills/claude-remote-spawn/driver.sh")


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


def alive(entry):
    pid = entry.get("pid")
    try:
        os.kill(pid, 0)
    except (OSError, TypeError):
        return False
    started = entry.get("procStart")
    return not started or " ".join(ps(pid, "lstart").split()) == " ".join(started.split())


def argv_of(pid):
    if not pid:
        return []
    if not MAC:
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                return [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
        except OSError:
            return []
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    mib, size = (ctypes.c_int * 3)(1, 49, pid), ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0):
        return []
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0):
        return []
    raw = buf.raw[:size.value]
    argc, rest = int.from_bytes(raw[:4], sys.byteorder), raw[4:]
    rest = rest[rest.find(b"\0"):].lstrip(b"\0")
    return [a.decode(errors="replace") for a in rest.split(b"\0")[:argc]]


def parent_of(pid):
    ppid = ps(pid, "ppid")
    return int(ppid) if ppid.isdigit() else 0


def launch_flags(tokens):
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


def repo_root(cwd):
    common = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True).stdout.strip() if os.path.isdir(cwd) else ""
    if not common:
        return ""
    return os.path.realpath(os.path.dirname(common) if os.path.basename(common) == ".git" else common.rstrip("/"))


def folder_group(cwd):
    if not cwd or os.path.realpath(cwd) == os.path.realpath(HOME):
        return "home"
    return os.path.basename(repo_root(cwd) or cwd.rstrip("/"))


def launcher(parent, cwd):
    script = os.path.realpath(parent[1]) if len(parent) > 1 and os.path.basename(parent[0]) in SHELLS else ""
    root = repo_root(cwd)
    if not script or not root or not script.startswith(root + os.sep):
        return None
    head = parent[2:3] if len(parent) > 2 and not parent[2].startswith("-") else []
    return {"argv": [os.path.basename(parent[0]), script] + head, "flags": launch_flags(parent[1:])}


def entry(e):
    parent = argv_of(parent_of(e["pid"]))
    cwd = e.get("cwd") or ""
    s = {"sessionId": e["sessionId"], "name": "" if e.get("nameSource") == "derived" else e.get("name") or "",
         "cwd": cwd, "group": folder_group(cwd), "flags": launch_flags(argv_of(e["pid"]))}
    run_by = launcher(parent, cwd)
    if run_by:
        s["launcher"] = run_by
    if parent and os.path.basename(parent[0]) == "script":
        s["detached"] = True
    return s


def ended_session():
    if sys.stdin is None or sys.stdin.isatty() or not select.select([sys.stdin], [], [], 0.5)[0]:
        return ""
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return ""
    ended = event.get("hook_event_name") == "SessionEnd" and event.get("reason") in ENDED
    return event.get("session_id", "") if ended else ""


def snapshot(quiet):
    if os.environ.get("WS_SNAPSHOT") == "0":
        return
    ended = ended_session()
    sessions = [entry(e) for e in live_claude_sessions() if e["sessionId"] != ended]
    os.makedirs(SNAP_DIR, exist_ok=True)
    boot = boot_id()
    path = os.path.join(SNAP_DIR, boot + ".json")
    fd, tmp = tempfile.mkstemp(dir=SNAP_DIR, prefix=".snap-")
    with os.fdopen(fd, "w") as f:
        json.dump({"boot": boot, "takenAt": int(time.time()), "sessions": sessions}, f, indent=2, ensure_ascii=False)
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


def grouped(sessions):
    groups = {}
    for s in sessions:
        groups.setdefault(s["group"], []).append(s)
    order = sorted(groups, key=str.lower)
    return [(g, COLORS[i % len(COLORS)], sorted(groups[g], key=lambda s: (s["name"].lower(), s["sessionId"])))
            for i, g in enumerate(order)]


def load(path):
    with open(path) as f:
        return json.load(f)["sessions"]


def show(path):
    for group, color, sessions in grouped(load(path)):
        print("group %s (%s)" % (group, color))
        for s in sessions:
            print("  claude %s (%s)  %s" % (s["name"] or "-", s["sessionId"], s["cwd"]))


def q(value):
    return json.dumps(value, ensure_ascii=False)


def title(s):
    return s["name"] or "%s %s" % (os.path.basename(s["cwd"].rstrip("/")), s["sessionId"][:8])


def command(s):
    run_by = s.get("launcher")
    head, flags = (run_by["argv"], run_by["flags"]) if run_by else (["claude"], s["flags"])
    argv = head + ["--resume", s["sessionId"]] + (["-n", s["name"]] if s["name"] else []) + flags
    return " ".join(shlex.quote(a) for a in argv)


def detach(s):
    model = s["flags"][s["flags"].index("--model") + 1:][:1] if "--model" in s["flags"] else []
    argv = [DETACH_DRIVER, "resume", s["sessionId"], s["name"] or s["sessionId"][:8], "--in-place"]
    subprocess.run(argv + (["--model"] + model if model else []), cwd=s["cwd"], check=False,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def tab_toml(s, color, name, path):
    lines = ["name = %s" % q(name), "title = %s" % q(title(s)), "color = %s" % q(color), "", "[[panes]]",
             'id = "claude"', 'type = "terminal"', "directory = %s" % q(s["cwd"]),
             "commands = %s" % q(["rm -f " + shlex.quote(path), command(s)])]
    return "\n".join(lines) + "\n"


def launch_yaml(groups):
    lines = ["---", "name: %s" % CONFIG_NAME, "windows:", "  - active_tab_index: 0", "    tab_groups:"]
    for group, color, _ in groups:
        lines += ["      - name: %s" % q(group), "        color: %s" % color, "        collapsed: false", "        pinned: false"]
    lines.append("    tabs:")
    for i, (_, color, sessions) in enumerate(groups):
        for s in sessions:
            lines += ["      - title: %s" % q(title(s)), "        group: %d" % i, "        layout:",
                      "          cwd: %s" % q(s["cwd"]), "          commands:", "            - exec: %s" % q(command(s))]
    return "\n".join(lines) + "\n"


def warp_running():
    marker = "/Warp.app/Contents/MacOS/" if MAC else "warp-terminal"
    out = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True).stdout
    return any(marker in line for line in out.splitlines())


def restore(args):
    path = pick(args)
    sessions = load(path)
    names = {a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] != "--from")}
    if names:
        sessions = [s for s in sessions if s["name"] in names or s["sessionId"] in names]
        if not sessions:
            raise SystemExit("no session of %s is named %s" % (path, ", ".join(sorted(names))))
    live_ids = {e["sessionId"] for e in live_claude_sessions()}
    report, todo = [], []
    for s in sessions:
        if s["sessionId"] in live_ids:
            report.append("= %s: already running (%s)" % (title(s), s["sessionId"]))
        elif not os.path.isdir(s["cwd"]):
            report.append("! %s: %s no longer exists (%s)" % (title(s), s["cwd"], s["sessionId"]))
        else:
            how = "detached" if s.get("detached") and os.path.exists(DETACH_DRIVER) else s["group"]
            report.append("+ %s: resumes %s in %s [%s]" % (title(s), s["sessionId"], s["cwd"], how))
            todo.append(s)
    detached = [s for s in todo if s.get("detached") and os.path.exists(DETACH_DRIVER)]
    groups = grouped([s for s in todo if s not in detached])
    in_window = "--window" not in args and warp_running()
    files = []
    if in_window:
        for _, color, group_sessions in groups:
            for s in group_sessions:
                name = "%s-%d" % (CONFIG_NAME, len(files) + 1)
                target = os.path.join(TAB_DIR, name + ".toml")
                files.append((name, target, tab_toml(s, color, name, target)))
    elif todo:
        files.append((CONFIG_NAME + ".yaml", os.path.join(LAUNCH_DIR, CONFIG_NAME + ".yaml"), launch_yaml(groups)))
    print("snapshot: %s" % path)
    print("opens in: %s" % ("the Warp window already open, one tab per session" if in_window
                            else "a new Warp window, one tab group per folder"))
    for line in report:
        print(line)
    if "--dry-run" in args:
        for _, _, body in files:
            sys.stdout.write(body)
        return
    for s in detached:
        detach(s)
    opener = os.environ.get("WS_OPEN", "open" if MAC else "xdg-open")
    for n, (name, target, body) in enumerate(files):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            f.write(body)
        if n:
            time.sleep(1)
        subprocess.run([opener, ("warp://tab_config/" if in_window else "warp://launch/") + quote(name)], check=False)
    pending = {s["sessionId"] for s in todo}
    deadline = time.time() + float(os.environ.get("WS_OPEN_WAIT", "30"))
    while pending and time.time() < deadline:
        pending -= {e["sessionId"] for e in live_claude_sessions()}
        if pending:
            time.sleep(1)
    if pending:
        manual = ("its tab from Warp's + menu: %s" % ", ".join(n for n, p, _ in files if os.path.exists(p)) if in_window
                  else "File > Launch Configurations > %s" % CONFIG_NAME)
        print("! not back yet: %s — if Warp opened nothing (locked screen), open %s" % (", ".join(sorted(pending)), manual))
        sys.exit(1)
    print("restored: every Claude session is running again")


def check():
    print("launch   : %s" % LAUNCH_DIR)
    print("tabs     : %s" % TAB_DIR)
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
