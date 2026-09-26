"""Shared kernel of the delivery-harness plugins (ship-when-done, mr-watchdog, merge-review,
proof-of-fix). SOURCE OF TRUTH: lib/_kernel.py — vendored byte-identical into each plugin's
scripts/ dir by `python3 scripts/kernel-sync.py` (CI and the harness suite fail on drift); edit it
HERE, never in a vendored copy. Stateless on purpose: plugin identity (the .git/ state-file names)
stays in each plugin, so a process that loads two plugins can never cross their state."""
import json
import os
import re
import subprocess
import time
from urllib.parse import quote
from datetime import datetime, timedelta, timezone


def run(cmd, cwd, check=False, raw=False, timeout=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        if check:
            raise
        return (127, "", f"{cmd[0]}: not found")
    except subprocess.TimeoutExpired:
        return (124, "", "timed out")
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {p.stderr.strip()}")
    return (p.returncode, p.stdout if raw else p.stdout.strip(), p.stderr.strip())


def git_dir(repo):
    rc, gd, _ = run(["git", "rev-parse", "--git-dir"], repo)
    gd = gd if (rc == 0 and gd) else ".git"
    return gd if os.path.isabs(gd) else os.path.join(repo, gd)


def cur_branch(repo):
    rc, b, _ = run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], repo)
    return b if rc == 0 else None


def head_sha(repo):
    rc, sha, _ = run(["git", "rev-parse", "HEAD"], repo)
    return sha if rc == 0 else ""


def remote_name(repo):
    rc, up, _ = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], repo)
    if rc == 0 and "/" in up:
        return up.split("/", 1)[0]
    _, remotes, _ = run(["git", "remote"], repo)
    rl = [r for r in remotes.splitlines() if r.strip()]
    return ("origin" if "origin" in rl else rl[0]) if rl else None


def default_branch(repo, remote):
    if remote:
        rc, out, _ = run(["git", "symbolic-ref", "--quiet", f"refs/remotes/{remote}/HEAD"], repo)
        if rc == 0 and out:
            return out.rsplit("/", 1)[-1]
    for b in ("main", "master"):
        rc, _, _ = run(["git", "rev-parse", "--verify", "--quiet", b], repo)
        if rc == 0:
            return b
    return "main"


def parse_remote(url):
    """Parse an scp-style or http(s) git URL into {host, path, forge, https}. None if unrecognized."""
    if not url:
        return None
    u = re.sub(r"\.git/?$", "", url.strip())
    m = re.match(r"https?://(?:[^@/]+@)?([^/]+)/(.+)$", u) or \
        re.match(r"ssh://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$", u)
    if not m and "://" not in u:
        m = re.match(r"(?:[^@/]+@)?([^/:]+):(.+)$", u)
    if not m:
        return None
    host, path = m.group(1), m.group(2).strip("/")
    if "/" not in path:
        return None
    h = host.lower()
    forge = "github" if "github" in h else "gitlab" if "gitlab" in h else "bitbucket" if "bitbucket" in h else "unknown"
    return {"host": host, "path": path, "forge": forge, "https": f"https://{host}/{path}"}


def gitlab_branch_project_id(repo):
    """The numeric id of the GitLab project this branch is pushed to, None if unknown. A branch's own MR is
    the one whose source is this project: in a fork clone glab resolves `:id` to the parent (an
    `upstream` remote wins), where both my fork's MR and a stranger's show the parent as target."""
    rc, url, _ = run(["git", "remote", "get-url", remote_name(repo) or "origin"], repo)
    info = parse_remote(url) if rc == 0 else None
    if not info:
        return None
    rc, out, _ = run(["glab", "api", f"projects/{quote(info['path'], safe='')}"], repo)
    try:
        return json.loads(out)["id"] if rc == 0 else None
    except Exception:
        return None


def detect_forge(repo, cfg, remote):
    """The forge is the remote HOST's (a `forge` config value overrides, e.g. a self-hosted GitLab
    without "gitlab" in its hostname) — never a word found elsewhere in the URL."""
    if cfg.get("forge"):
        return cfg["forge"]
    rc, url, _ = run(["git", "remote", "get-url", remote or "origin"], repo)
    info = parse_remote(url) if rc == 0 else None
    return info["forge"] if info else "unknown"


def git_toplevel(path):
    if not path:
        return None
    rc, top, _ = run(["git", "-C", path, "rev-parse", "--show-toplevel"], ".")
    return top if rc == 0 and top else None


def repo_root(path):
    ap = os.path.abspath(path or ".")
    return git_toplevel(ap) or ap


def repo_from_command(cmd):
    m = re.search(r"\bgit\b[^&|;]*?\s-C\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd or "") \
        or re.search(r"(?:^|&&|;|\|)\s*cd\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd or "")
    return m.group(1).strip("\"'") if m else None


def last_edited_file(tp):
    if not tp or not os.path.isfile(tp):
        return None
    last, edits = None, {"Edit", "Write", "MultiEdit", "NotebookEdit", "Update"}
    try:
        for line in open(tp, errors="ignore"):
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") != "assistant":
                continue
            content = (d.get("message") or {}).get("content")
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in edits:
                        inp = b.get("input") or {}
                        fp = inp.get("file_path") or inp.get("notebook_path")
                        if fp:
                            last = fp
    except Exception:
        return None
    return last


def resolve_repo(cwd, transcript, command):
    """The git repo root we're actually working in: the one named in a push command; else, in a
    submodule workspace (cwd repo has .gitmodules), the repo of the most-recently edited file when it
    is nested inside the cwd's — acting on the superproject would only bump a pointer; else the cwd's
    repo, else the edited file's. None when no git repo is in scope."""
    if command:
        p = repo_from_command(command)
        if p:
            if not os.path.isabs(p) and cwd:
                p = os.path.join(cwd, p)
            r = git_toplevel(p)
            if r:
                return r
    cwd_repo = git_toplevel(cwd) if cwd else None
    if cwd_repo and transcript and os.path.isfile(os.path.join(cwd_repo, ".gitmodules")):
        f = last_edited_file(transcript)
        if f:
            edited = git_toplevel(os.path.dirname(f))
            if edited and edited != cwd_repo and edited.startswith(cwd_repo + os.sep):
                return edited
    if cwd_repo:
        return cwd_repo
    if transcript:
        f = last_edited_file(transcript)
        if f:
            r = git_toplevel(os.path.dirname(f))
            if r:
                return r
    return None


def cmd_resolve(args):
    r = resolve_repo(args.cwd, args.transcript, args.command)
    if r:
        print(r)


def write_json(path, data):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


SESSION_GC_DAYS = 7


def read_sessions(path):
    """v1 multi-session map. Anything else — absent, corrupt, or pre-v1 (the one-minor migration
    window is closed) — reads as empty and is rewritten as v1 on the next write."""
    try:
        st = json.load(open(path))
    except Exception:
        st = None
    if isinstance(st, dict) and "v" in st and isinstance(st.get("sessions"), dict):
        return st
    return {"v": 1, "sessions": {}}


def write_sessions(path, st):
    cutoff = (datetime.now(timezone.utc) - timedelta(days=SESSION_GC_DAYS)).isoformat()
    st["sessions"] = {k: v for k, v in st["sessions"].items() if (v.get("started") or cutoff) >= cutoff}
    try:
        write_json(path, st)
    except OSError:
        pass


def read_state(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def write_state(path, data):
    try:
        write_json(path, data)
    except OSError:
        pass


def _under(path, roots):
    """Filesystem identity, not spelling: on a case-insensitive volume `~/src/ZV` is `~/src/zv`."""
    ids = set()
    for r in roots:
        try:
            st = os.stat(r)
            ids.add((st.st_dev, st.st_ino))
        except OSError:
            pass
    p = os.path.realpath(path)
    while True:
        try:
            st = os.stat(p)
            if (st.st_dev, st.st_ino) in ids:
                return True
        except OSError:
            pass
        parent = os.path.dirname(p)
        if parent == p:
            return False
        p = parent


def auto_engage(repo):
    """Engagement mode switch. Default (explicit): plugins act only on explicit protocol artifacts —
    the done-marker, ship's handoff stamp. HARNESS_AUTO_ENGAGE=1 restores inferred engagement
    (baseline deltas, provenance ∩ branch content, upstream advance), scoped: a session launched
    outside a git work tree (CLAUDE_PROJECT_DIR, e.g. $HOME) has no project to infer from, and a
    launch dir or repo under a path of HARNESS_AUTO_ENGAGE_EXCLUDE (os.pathsep-separated, ~ and $VAR
    expanded — repos that carry their own delivery harness) stays explicit; an entry that is not an
    absolute path after expansion, or still holds a `$`, cannot be honoured, so auto stays off. Truthy allowlist: the truthy side takes
    autonomous actions, so an unrecognized value must mean OFF."""
    if os.environ.get("HARNESS_AUTO_ENGAGE", "").lower() not in ("1", "true"):
        return False
    entries = [os.path.expandvars(os.path.expanduser(p.strip()))
               for p in os.environ.get("HARNESS_AUTO_ENGAGE_EXCLUDE", "").split(os.pathsep) if p.strip()]
    if not all(os.path.isabs(e) and "$" not in e for e in entries):
        return False
    excluded = [os.path.realpath(e) for e in entries]
    launch = os.environ.get("CLAUDE_PROJECT_DIR")
    if launch and (not git_toplevel(launch) or _under(launch, excluded)):
        return False
    return not _under(repo, excluded)


def marker_path(repo):
    return os.path.join(git_dir(repo), "swd-done.json")          # inside .git → never committed


def read_marker(repo):
    p = marker_path(repo)
    if os.path.isfile(p):
        try:
            return json.load(open(p))
        except Exception:
            return {"done": True}
    return None


def marker_for_branch(repo, branch):
    """ship-when-done's explicit 'this delivery is ready' declaration — the cross-plugin signal the
    explicit mode acts on. STRICT branch match: a corrupt or branch-less marker is inert here (never
    a wildcard engagement); only evaluate_completion keeps the tolerant read, on an already-engaged
    branch. Inert when the sibling is absent."""
    m = read_marker(repo)
    return bool(m and m.get("branch") == branch)


def ledger_path(repo):
    return os.path.join(git_dir(repo), "conductor.json")


def read_ledger(repo):
    """delivery-conductor's need ledger as ('absent' | 'ok' | 'corrupt', ledger)."""
    try:
        st = json.load(open(ledger_path(repo)))
    except FileNotFoundError:
        return "absent", None
    except Exception:
        return "corrupt", None
    needs = st.get("needs") if isinstance(st, dict) else None
    if isinstance(needs, dict) and all(isinstance(n, dict) for n in needs.values()):
        return "ok", st
    return "corrupt", None


def live_dir():
    return os.environ.get("HARNESS_LIVE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "harness-live")


def live_path(session):
    return os.path.join(live_dir(), re.sub(r"[^\w.-]", "_", session) + ".json")


def stamp_live(session, prompt_id, scope):
    """delivery-conductor refreshes this from each of its hooks: proof that it runs in `session` at
    `prompt_id`. Keyed by session alone, never by repo: a session launched outside the conductor's
    scope may have no repo yet when its prompt starts, and must still be seen as running it."""
    if not session:
        return
    try:
        os.makedirs(live_dir(), exist_ok=True)
        cutoff = time.time() - SESSION_GC_DAYS * 86400
        for e in os.scandir(live_dir()):
            if e.stat().st_mtime < cutoff:
                os.remove(e.path)
    except OSError:
        pass
    write_state(live_path(session), {"prompt_id": prompt_id or "", "scope": bool(scope)})


def previous_prompt_id(transcript, prompt_id):
    """The prompt before `prompt_id` in the transcript ('' before the first one), None if unreadable.
    Every user entry of a turn (its prompt, its tool results) carries the turn's promptId."""
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as f:
            for start in (max(0, size - 1048576), 0):
                f.seek(start)
                ids = [i for i in re.findall(r'"promptId":\s*"([^"]+)"', f.read().decode("utf-8", "ignore"))
                       if i != prompt_id]
                if ids or start == 0:
                    return ids[-1] if ids else ""
    except (OSError, TypeError):
        return None


def conductor_live(session, prompt_id, transcript=None, at_prompt=False):
    """The conductor's stamp when it ran for this prompt. A UserPromptSubmit caller runs in parallel
    with the conductor's own hook, so it also accepts the stamp of the prompt just before."""
    st = read_state(live_path(session)) if session else None
    last = st.get("prompt_id") if isinstance(st, dict) else None
    if last is None or not prompt_id:
        return None
    if last == prompt_id or (at_prompt and last == previous_prompt_id(transcript, prompt_id)):
        return st
    return None


def conductor_scope(session, prompt_id, transcript):
    st = conductor_live(session, prompt_id, transcript, at_prompt=True)
    return bool(st and st.get("scope"))


def driven(repo, session, prompt_id):
    """True while delivery-conductor holds the current branch for a need: every sibling stands down on
    it. Only while the conductor runs for this very prompt, so a ledger left behind by a disabled
    conductor is inert; a corrupt ledger under a running conductor holds every branch."""
    if not conductor_live(session, prompt_id):
        return False
    status, ledger = read_ledger(repo)
    if status != "ok":
        return status == "corrupt"
    branch = cur_branch(repo)
    return bool(branch) and any(n.get("branch") == branch for n in ledger["needs"].values())


def provenance_path(repo):
    return os.path.join(git_dir(repo), "swd-provenance.json")


def provenance_paths(repo, sid):
    """ship-when-done's observed-edits file — the cross-plugin engagement protocol. Any unexpected
    shape degrades inert: an engagement gate must never traceback open."""
    try:
        st = json.load(open(provenance_path(repo)))
        return set((st.get("sessions", {}).get(sid) or {}).get("paths", []))
    except Exception:
        return set()


def carried_paths(repo):
    """NUL-delimited feeds (-z, raw): C-quoting would break the verbatim intersection with provenance
    paths, and stripping would eat a worktree-only entry's leading space. In porcelain -z a rename's
    original path is a bare extra token — skipped (staged or worktree side)."""
    _, names, _ = run(["git", "diff", "--name-only", "-z",
                       f"{default_branch(repo, remote_name(repo))}...HEAD"], repo, raw=True)
    paths = set(filter(None, names.split("\0")))
    _, porcelain, _ = run(["git", "status", "--porcelain", "-z"], repo, raw=True)
    toks = iter(porcelain.split("\0"))
    for t in toks:
        if len(t) > 3 and t[2] == " ":
            paths.add(t[3:])
            if "R" in t[:2] or "C" in t[:2]:
                next(toks, None)
    return paths


BYPASS_PATTERNS = [
    r"--no-verify",
    r"\|\|\s*true\b",
    r"\bcontinue-on-error:\s*true",
    r"\ballow_failure:\s*true",
    r"\bwhen:\s*never\b",
    r"@(?:pytest\.mark\.)?(?:skip|xfail)\b",
    r"\bpytest\.skip\b|\b(?:unittest|self)\.skip(?:Test)?\b",
    r"\b(?:it|test|describe)\.skip\b",
    r"\bxit\b|\bxdescribe\b",
    r"\.skip\s*\(",
    r"\bassert\s+(?:True|1)\b",
    r"\bexpect\(\s*true\s*\)\.tobe\(\s*true\s*\)",
    r"--maxfail\b",
    r"eslint-disable",
    r"#\s*type:\s*ignore",
    r"#\s*noqa(?!:\s*E501)",
    r"@ts-(?:ignore|nocheck|expect-error)",
    r"\bskip_tests?\b",
]


TEST_PATH = re.compile(r"(^|/)(tests?/|test_|conftest|.*[._-](test|spec)\.)", re.I)


def added_lines(diff):
    return "\n".join(l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++"))


def bypass_in_diff(diff):
    for pat in BYPASS_PATTERNS:
        m = re.search(pat, diff, re.I)
        if m:
            return m.group(0)
    return None


def deleted_tests(repo):
    _, ns, _ = run(["git", "diff", "HEAD", "--name-status"], repo)
    return [p.split("\t")[-1] for p in ns.splitlines()
            if p[:1] == "D" and TEST_PATH.search(p.split("\t")[-1])]


def weakened_tests(repo):
    _, ns, _ = run(["git", "diff", "HEAD", "--name-status"], repo)
    for line in ns.splitlines():
        parts = line.split("\t")
        if parts[0][:1] == "M" and TEST_PATH.search(parts[-1]):
            _, d, _ = run(["git", "diff", "HEAD", "--", parts[-1]], repo)
            removed = [l for l in d.splitlines() if l.startswith("-") and not l.startswith("---")]
            if any(re.search(r"\b(assert|expect|should|require)\b", r, re.I) for r in removed):
                return parts[-1]
    return None


def read_capped(repo, rel, cap=20000):
    try:
        return open(os.path.join(repo, rel), errors="ignore").read()[:cap]
    except OSError:
        return ""


def fake_green(repo):
    """Returns a short reason the working-tree change fakes green, else '' (the change looks honest)."""
    g = deleted_tests(repo)
    if g:
        return f"deleted-test:{g[0][-40:]}"
    w = weakened_tests(repo)
    if w:
        return f"weakened-test:{w[-40:]}"
    _, tracked, _ = run(["git", "diff", "HEAD"], repo)
    _, un, _ = run(["git", "ls-files", "--others", "--exclude-standard"], repo)
    new_files = [f for f in un.splitlines() if f]
    scan = added_lines(tracked) + "\n" + "\n".join(read_capped(repo, f) for f in new_files)
    hit = bypass_in_diff(scan)
    return f"bypass:{hit[:40]}" if hit else ""
