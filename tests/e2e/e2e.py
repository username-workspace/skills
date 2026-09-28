#!/usr/bin/env python3
"""harness-e2e — generative end-to-end validation of the delivery harness against a REAL forge.

The hermetic suites idealize four things the real world doesn't: composition, environment, time, and
state evolution. This lane covers them by replaying generated scenarios (seeded, so every failure is
reproducible) on a disposable sandbox repo with plan-steered CI — real pushes, real PRs, real checks,
real registration windows.

Watcher duties: every scenario failure is re-run once with the same seed (flake vs defect); the sandbox
is self-healed before each run (stale e2e/* and need/* branches and PRs are garbage-collected); a persistent
failure files a GitHub issue on the skills repo carrying the full evidence, ready for a fixing session.

Usage: python3 tests/e2e/e2e.py [--forge github|gitlab] [--seed N] [--count N] [--repo owner/name]
                               [--scenario flow:gate:ci | twist:<name> | need:<name>]
"""
import argparse, json, os, random, re, shlex, shutil, socket, subprocess, sys, tempfile, time
from urllib.parse import quote

os.environ.setdefault("HARNESS_AUTO_ENGAGE", "1")   # the generated scenarios replay the AUTO lanes

SKILLS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHIP = os.path.join(SKILLS, "plugins/ship-when-done/skills/ship-when-done/scripts/ship.py")
REVIEW = os.path.join(SKILLS, "plugins/merge-review/skills/merge-review/scripts/review.py")
WATCH = os.path.join(SKILLS, "plugins/mr-watchdog/skills/mr-watchdog/scripts/watch.py")
SHIP_HOOK = os.path.join(SKILLS, "plugins/ship-when-done/hooks/stop-hook.py")
SHIP_PLUGIN = os.path.join(SKILLS, "plugins/ship-when-done")
CONDUCTOR = os.path.join(SKILLS, "plugins/delivery-conductor/skills/delivery-conductor/scripts/conductor.py")
POF = os.path.join(SKILLS, "plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py")
HARNESS = ("plugins/ship-when-done", "plugins/merge-review", "plugins/mr-watchdog", "plugins/proof-of-fix",
           "plugins/delivery-conductor", "lib")
E2E_REPO = "username-workspace/harness-e2e"      # same path on github.com and gitlab.com
FORGE = "github"
ISSUE_REPO = "username-workspace/skills"

DIMS = {
    "flow": ["single-shot", "multi-turn", "reedit"],
    "gate": ["green", "red-then-fixed", "timeout", "none"],
    "ci": ["green", "red-then-fixed", "slow-green"],
}
CANONICAL = [
    {"flow": "single-shot", "gate": "green", "ci": "green"},
    {"flow": "multi-turn", "gate": "green", "ci": "red-then-fixed"},
]
# the EXPLICIT default (HARNESS_AUTO_ENGAGE unset) is a different contract — declaration-driven, no
# inference — so it gets its own targeted set: every flow against the meaningful gate × ci pairs,
# plus one auto-detected-gate archetype. Not the full matrix: gate timeout/none and ci slow-green
# behave identically past the declaration (the hermetic suites pin that); the holes worth a real
# forge are the declared pipeline itself and the turn-1 inaction.
EXPLICIT_SET = ([{"flow": f, "gate": g, "ci": c, "mode": "explicit"}
                 for f in DIMS["flow"]
                 for g in ("green", "red-then-fixed")
                 for c in ("green", "red-then-fixed")]
                + [{"flow": "single-shot", "gate": "auto", "ci": "green", "project": "node",
                    "mode": "explicit"}])
CI_PLANS = {"green": {"sleep": 0, "exit": 0}, "red-then-fixed": {"sleep": 0, "exit": 1},
            "slow-green": {"sleep": 60, "exit": 0}}


# --- project archetypes: varied complexity, gate AUTO-DETECTED (no config) --------------------------

def _files(repo, files):
    for rel, content in files.items():
        p = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(content)


PROJECTS = {
    "node": {"expected_gate": "npm test", "cwd": ".", "files": {
        "package.json": '{"name":"e2e-node","scripts":{"test":"node -e \'process.exit(0)\'"}}\n'}},
    "pnpm-ts": {"expected_gate": "pnpm ts:check", "cwd": ".", "files": {
        "package.json": '{"name":"e2e-ts","scripts":{"ts:check":"node -e \'process.exit(0)\'"}}\n',
        "pnpm-lock.yaml": "lockfileVersion: '9.0'\n"}},
    "php": {"expected_gate": "composer test", "cwd": ".", "files": {
        "composer.json": '{"name":"e2e/php","scripts":{"test":"php -r \'exit(0);\'"}}\n'}},
    "go": {"expected_gate": "go test ./...", "cwd": ".", "files": {
        "go.mod": "module e2e/gomod\n\ngo 1.21\n",
        "main.go": "package main\n\nfunc main() {}\n"}},
    "multi": {"expected_gate": "make test", "cwd": "packages/lib", "files": {
        "Makefile": "test:\n\t@true\n",
        "src/app/main.txt": "app\n",
        "packages/lib/lib.txt": "lib\n",
        "docs/README.md": "# multi\n"}},
}


def sh(cmd, cwd=None, timeout=300, env=None, check=False):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                       env=dict(os.environ, **(env or {})), shell=isinstance(cmd, str))
    if check and p.returncode != 0:
        raise RuntimeError(f"{cmd} -> rc={p.returncode}\n{p.stdout}\n{p.stderr}")
    return p.returncode, p.stdout.strip(), p.stderr.strip()


class Failure(Exception):
    pass


def expect(cond, what, evidence=""):
    if not cond:
        raise Failure(f"{what}\n--- evidence ---\n{evidence[-3000:]}")


# --- the sandbox forge: one small surface, GitHub via gh, GitLab via its REST API through glab -------

def gl_project():
    return f"projects/{quote(E2E_REPO, safe='')}"


def open_prs():
    """Open PRs/MRs as [{number, branch, draft}]."""
    if FORGE == "gitlab":
        _, out, _ = sh(["glab", "api", f"{gl_project()}/merge_requests?state=opened&per_page=100"],
                       check=True)
        return [{"number": m["iid"], "branch": m["source_branch"], "draft": bool(m.get("draft"))}
                for m in json.loads(out or "[]")]
    _, out, _ = sh(["gh", "pr", "list", "--repo", E2E_REPO, "--state", "open",
                    "--json", "number,headRefName,isDraft"], check=True)
    return [{"number": p["number"], "branch": p["headRefName"], "draft": p["isDraft"]}
            for p in json.loads(out or "[]")]


def branch_delete(branch):
    if FORGE == "gitlab":
        sh(["glab", "api", "-X", "DELETE", f"{gl_project()}/repository/branches/{quote(branch, safe='')}"])
    else:
        sh(["gh", "api", "-X", "DELETE", f"repos/{E2E_REPO}/git/refs/heads/{branch}"])


def pr_close(pr, branch=None, check=False):
    """Close the PR/MR; with `branch`, delete its head branch too."""
    if FORGE == "gitlab":
        sh(["glab", "api", "-X", "PUT", f"{gl_project()}/merge_requests/{pr['number']}",
            "-f", "state_event=close"], check=check)
    else:
        sh(["gh", "pr", "close", str(pr["number"]), "--repo", E2E_REPO], check=check)
    if branch:
        branch_delete(branch)


def branches():
    if FORGE == "gitlab":
        _, out, _ = sh(["glab", "api", f"{gl_project()}/repository/branches?per_page=100"], check=True)
        return [b["name"] for b in json.loads(out or "[]")]
    _, out, _ = sh(["gh", "api", f"repos/{E2E_REPO}/branches", "--jq", ".[].name"], check=True)
    return out.splitlines()


def gc_sandbox():
    for pr in open_prs():
        if pr["branch"].startswith(("e2e/", "need/")):
            pr_close(pr)
    for b in branches():
        if b.startswith(("e2e/", "need/")):
            branch_delete(b)


# --- scenario plumbing -------------------------------------------------------------------------------

def clone(workdir):
    if FORGE == "gitlab":
        sh(["git", "clone", "-q", f"git@gitlab.com:{E2E_REPO}.git", workdir], check=True)
    else:
        sh(["gh", "repo", "clone", E2E_REPO, workdir, "--", "-q"], check=True)
    sh(["git", "-C", workdir, "config", "user.email", "e2e@harness"], check=True)
    sh(["git", "-C", workdir, "config", "user.name", "harness-e2e"], check=True)
    sh(["git", "-C", workdir, "config", "commit.gpgsign", "false"], check=True)


def gate_config(repo, gate):
    cfg = {"green": {"gate": "true"},
           "red-then-fixed": {"gate": f"test -f {repo}/.git/gate-healed"},
           "timeout": {"gate": "sleep 5", "gate_timeout": 2},
           "none": {}, "auto": {}}[gate]
    if cfg:
        json.dump(cfg, open(os.path.join(repo, ".git", "ship-when-done.json"), "w"))


def baselines(repo, session):
    for script in (SHIP, REVIEW, WATCH):
        sh([sys.executable, script, "baseline", "--repo", repo, "--session", session], check=True)


def mode_env(sc):
    return {"HARNESS_AUTO_ENGAGE": "" if sc.get("mode") == "explicit" else "1"}


def stop(repo, session, transcript, active=False, env=None):
    payload = json.dumps({"cwd": repo, "session_id": session, "transcript_path": transcript,
                          "stop_hook_active": active})
    p = subprocess.run([sys.executable, SHIP_HOOK], input=payload, capture_output=True, text=True,
                       timeout=300, env=dict(os.environ, CLAUDE_PLUGIN_ROOT=SHIP_PLUGIN, **(env or {})))
    return p.stdout.strip()


def transcript_for(workdir, goal):
    tp = os.path.join(os.path.dirname(workdir), "transcript.jsonl")
    lines = [{"type": "user", "isSidechain": False, "message": {"role": "user", "content": goal}},
             {"type": "assistant", "message": {"role": "assistant",
                                               "content": [{"type": "text", "text": "Done."}]}}]
    open(tp, "w").write("\n".join(json.dumps(l) for l in lines))
    return tp


def work(repo, name, ci):
    open(os.path.join(repo, f"{name}.txt"), "w").write(f"work for {name}\n")
    json.dump(CI_PLANS[ci], open(os.path.join(repo, "ci-plan.json"), "w"))


COVERAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "coverage.json")


def harness_rev():
    """The last commit that changed the harness this lane exercises — a proof predates it, the proof
    is stale."""
    _, rev, _ = sh(["git", "-C", SKILLS, "log", "-1", "--format=%h", "--", *HARNESS])
    return rev


def coverage_read():
    try:
        return json.load(open(COVERAGE))
    except Exception:
        return {}


def coverage_record(label, runid, secs):
    cov = coverage_read()
    cov[label] = {"run": runid, "proven": time.strftime("%Y-%m-%d"), "secs": secs,
                  "harness": harness_rev()}
    json.dump(dict(sorted(cov.items())), open(COVERAGE, "w"), indent=2)


def scenario_label(sc):
    if sc.get("need"):
        label = f"need/{sc['need']}"
    elif sc.get("twist"):
        label = f"twist/{sc['twist']}"
    else:
        base = f"{sc.get('project', 'bare')}/{sc['flow']}/{sc['gate']}/{sc['ci']}"
        label = f"explicit/{base}" if sc.get("mode") == "explicit" else base
    return label if FORGE == "github" else f"{FORGE}/{label}"


def ledger_spaces():
    """Every situation the ledger tracks, as runnable scenarios — one inventory for report and fill."""
    return {
        "bare": [{"flow": f, "gate": g, "ci": c}
                 for f in DIMS["flow"] for g in DIMS["gate"] for c in DIMS["ci"]],
        "projects": [{"flow": "single-shot", "gate": "auto",
                      "ci": "red-then-fixed" if p == "multi" else "green", "project": p}
                     for p in PROJECTS],
        "twists": [{"twist": t} for t in TWISTS],
        "needs": [{"need": n} for n in NEEDS],
        "explicit": list(EXPLICIT_SET),
    }


def stale_scenarios():
    cov, cur = coverage_read(), harness_rev()
    return [sc for scs in ledger_spaces().values() for sc in scs
            if cov.get(scenario_label(sc), {}).get("harness") != cur]


def coverage_report():
    cov = coverage_read()
    cur = harness_rev()
    proven = sum(scenario_label(sc) in cov for scs in ledger_spaces().values() for sc in scs)
    print(f"coverage ledger ({FORGE}) — {proven} situation(s) proven · harness @ {cur}")
    for space, scs in ledger_spaces().items():
        keys = [scenario_label(sc) for sc in scs]
        missing = [k for k in keys if k not in cov]
        stale = [k for k in keys if k in cov and cov[k].get("harness") != cur]
        line = f"  {space}: {len(keys) - len(missing)}/{len(keys)} covered"
        if stale:
            line += f" · {len(stale)} STALE (proven before harness @ {cur})"
        if missing:
            line += f" — missing: {', '.join(missing)}"
        print(line)


def watch_until_resolved(repo, timeout=420, env=None):
    rc, out, err = sh([sys.executable, WATCH, "run", "--repo", repo, "--timeout", str(timeout)],
                      timeout=timeout + 60, env=env)
    return rc, out + ("\n" + err if err else "")


def pr_state(branch):
    """The OPEN PR for this exact head branch, else None — `gh pr view <branch>` also matches closed
    PRs from previous runs, which is a different question and broke cross-run isolation."""
    prs = [p for p in open_prs() if p["branch"] == branch]
    return {"state": "OPEN", "isDraft": prs[0]["draft"], "number": prs[0]["number"]} if prs else None


# --- the scenario executor ---------------------------------------------------------------------------

def run_scenario(sc, tag):
    if sc.get("need"):
        NEEDS[sc["need"]](tag)
        return "pass"
    if sc.get("twist"):
        TWISTS[sc["twist"]](tag)
        return "pass"
    workdir = os.path.join(tempfile.mkdtemp(prefix="harness-e2e-"), "repo")
    clone(workdir)
    project = PROJECTS.get(sc.get("project", "bare"))
    branch = f"e2e/{tag}-{sc.get('project', 'bare')}-{sc['flow']}-{sc['gate']}-{sc['ci']}"
    session = f"e2e-{tag}"
    sh(["git", "-C", workdir, "checkout", "-q", "-b", branch], check=True)
    if project:
        _files(workdir, project["files"])
        sh(["git", "-C", workdir, "add", "-A"], check=True)
        sh(["git", "-C", workdir, "commit", "-qm", "chore: project scaffold"], check=True)
    cwd = os.path.join(workdir, project["cwd"]) if project else workdir
    gate_config(workdir, sc["gate"])
    tp = transcript_for(workdir, f"E2E-1 {sc['flow']} delivery on {branch}")
    baselines(workdir, session)
    menv = mode_env(sc)

    if sc["flow"] == "multi-turn":
        work(workdir, "part1", sc["ci"])
        _, n0, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
        out = stop(cwd, session, tp, env=menv)
        if sc.get("mode") == "explicit":
            _, n1, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
            expect(n1 == n0 and "commit" not in out,
                   "explicit turn1: no declaration → no action, the work stays untouched", out)
        else:
            expect("push" in out or "commit" in out, "multi-turn turn1: partial work must commit+push", out)
        expect(pr_state(branch) is None, "multi-turn turn1: no PR before done", out)
        baselines(workdir, session)
    if sc["flow"] == "reedit":
        work(workdir, "feature", sc["ci"])
        open(os.path.join(workdir, "feature.txt"), "a").write("reedited content, same dirty file\n")

    work(workdir, "feature", sc["ci"])
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary",
        f"e2e {sc['flow']}", "--type", "feat"], check=True)

    out = stop(cwd, session, tp, env=menv)
    if sc["gate"] == "timeout":
        expect("gate-timeout" in out, "timeout gate: distinct withheld reason expected", out)
        ev = json.load(open(os.path.join(workdir, ".git", "swd-gate.json")))
        expect(ev.get("verdict") == "timeout", "timeout gate: evidence persisted", json.dumps(ev))
        expect(pr_state(branch) is None, "timeout gate: no PR", out)
        return "pass"
    if sc["gate"] == "none":
        expect("no-gate-detected" in out, "no gate: withheld reason must be said out loud", out)
        expect(pr_state(branch) is None, "no gate: no PR", out)
        return "pass"
    if sc["gate"] == "red-then-fixed":
        expect("gate-not-green" in out, "red gate: PR withheld visibly", out)
        open(os.path.join(workdir, ".git", "gate-healed"), "w").write("x")

    expect('"decision": "block"' in out and "merge-review" in out,
           "done work must be held for the merge-review pass (the block rides the FIRST stop, "
           "once per work-state — a red gate does not delay it)", out)
    expect(pr_state(branch) is None, "nothing on the forge before the review", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(cwd, session, tp, active=True, env=menv)
    pr = pr_state(branch)
    expect(pr is not None and pr["state"] == "OPEN" and pr["isDraft"],
           "reviewed work must reach the forge as a draft PR", out)

    rc, verdict = watch_until_resolved(workdir, env=menv)
    if sc["ci"] == "red-then-fixed":
        expect(rc == 1 and "ROOT" in verdict, "red CI: the watcher must hand back the fix contract",
               verdict)
        json.dump(CI_PLANS["green"], open(os.path.join(workdir, "ci-plan.json"), "w"))
        sh(["git", "-C", workdir, "add", "-A"], check=True)
        sh(["git", "-C", workdir, "commit", "-qm", "fix: heal the pipeline"], check=True)
        sh(["git", "-C", workdir, "push", "-q", "origin", branch], check=True)
        rc, verdict = watch_until_resolved(workdir, env=menv)
    expect(rc == 0 and "CI green" in verdict, "the pipeline must end green", verdict)
    if sc["gate"] == "auto":
        ev = json.load(open(os.path.join(workdir, ".git", "swd-gate.json")))
        expect(ev.get("cmd") == project["expected_gate"] and ev.get("verdict") == "pass",
               f"auto-detected gate must be '{project['expected_gate']}' and green", json.dumps(ev))

    pr_close(pr, branch)
    shutil.rmtree(os.path.dirname(workdir), ignore_errors=True)
    return "pass"


# --- twists: human behaviour that diverges from the nominal pipeline --------------------------------

def twist_setup(tag, name, ci="green"):
    workdir = os.path.join(tempfile.mkdtemp(prefix="harness-e2e-"), "repo")
    clone(workdir)
    branch = f"e2e/{tag}-twist-{name}"
    sh(["git", "-C", workdir, "checkout", "-q", "-b", branch], check=True)
    json.dump({"gate": "true"}, open(os.path.join(workdir, ".git", "ship-when-done.json"), "w"))
    open(os.path.join(workdir, ".mr-watchdog.json"), "w").write('{"poll_interval": 1}')
    tp = transcript_for(workdir, f"E2E-2 twist {name} on {branch}")
    return workdir, branch, f"e2e-{tag}", tp


def deliver(workdir, branch, session, tp, ci="green"):
    """The nominal reviewed delivery, up to the open draft PR."""
    baselines(workdir, session)
    work(workdir, "feature", ci)
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "twist", "--type", "feat"],
       check=True)
    out = stop(workdir, session, tp)
    expect('"decision": "block"' in out, "delivery must be held for review", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr and pr["state"] == "OPEN", "reviewed delivery must open the draft PR", out)
    return pr


def twist_preexisting_dirty(tag):
    """The safety guarantee: a tree dirty BEFORE the session is never swept up."""
    workdir, branch, session, tp = twist_setup(tag, "preexisting-dirty")
    open(os.path.join(workdir, "precious-wip.txt"), "w").write("someone else's uncommitted work\n")
    baselines(workdir, session)
    _, n0, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
    out = stop(workdir, session, tp)
    _, n, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
    expect(n == n0, "pre-existing dirty tree: no commit", out)
    expect(os.path.isfile(os.path.join(workdir, "precious-wip.txt")), "the dirty file is untouched", out)
    expect(pr_state(branch) is None, "nothing reached the forge", out)


def twist_wip_branch(tag):
    """The wip/ escape hatch: even completed work on a wip/ branch is left alone."""
    workdir, _, session, tp = twist_setup(tag, "wip-branch")
    sh(["git", "-C", workdir, "checkout", "-q", "-b", "wip/spike"], check=True)
    baselines(workdir, session)
    work(workdir, "spike", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "spike"], check=True)
    _, n0, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
    out = stop(workdir, session, tp)
    _, n, _ = sh(["git", "-C", workdir, "rev-list", "--count", "HEAD"])
    expect(n == n0, "wip/ branch: no commit, no ladder", out)


def twist_amend_after_push(tag):
    """HEAD rewritten while the watcher polls: it must stand down, never emit a verdict."""
    workdir, branch, session, tp = twist_setup(tag, "amend-after-push")
    deliver(workdir, branch, session, tp, ci="slow-green")
    proc = subprocess.Popen([sys.executable, WATCH, "run", "--repo", workdir],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(4)
    sh(["git", "-C", workdir, "commit", "--amend", "-m", "amended by the human"], check=True)
    out, _ = proc.communicate(timeout=90)
    expect("branch/HEAD moved" in out, "amended HEAD → the watcher stands down", out)
    expect("ok, all good" not in out and "ROOT" not in out, "no verdict for a rewritten HEAD", out)
    pr = pr_state(branch)
    if pr:
        pr_close(pr, branch)


def twist_mr_closed_mid_watch(tag):
    """The human closes the MR while the watcher polls: nothing left to watch, clean exit."""
    workdir, branch, session, tp = twist_setup(tag, "mr-closed-mid-watch")
    pr = deliver(workdir, branch, session, tp, ci="slow-green")
    pr_close(pr, check=True)
    rc, out, err = sh([sys.executable, WATCH, "run", "--repo", workdir], timeout=120)
    expect("no open merge request" in out + err, "closed MR → the watcher stands down", out + err)
    branch_delete(branch)


def twist_manual_push_midflow(tag):
    """The impatient human pushes by hand during the review hold: the pipeline still converges."""
    workdir, branch, session, tp = twist_setup(tag, "manual-push-midflow")
    baselines(workdir, session)
    work(workdir, "feature", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "manual"], check=True)
    out = stop(workdir, session, tp)
    expect('"decision": "block"' in out, "held for review first", out)
    sh(["git", "-C", workdir, "push", "-q", "-u", "origin", branch], check=True)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr and pr["state"] == "OPEN", "manual push absorbed, the PR still opens", out)
    pr_close(pr, branch)


def twist_review_loop(tag):
    """The review fails first (score under threshold): held without re-block churn, then the fix
    re-arms one new request, the pass ships it."""
    workdir, branch, session, tp = twist_setup(tag, "review-loop")
    baselines(workdir, session)
    work(workdir, "feature", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "loop"], check=True)
    out = stop(workdir, session, tp)
    expect('"decision": "block"' in out, "first stop requests the review", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "40"], check=True)
    out = stop(workdir, session, tp, active=True)
    expect('"decision": "block"' not in out, "failed review, unchanged state → no re-block churn", out)
    expect(pr_state(branch) is None, "still nothing on the forge", out)
    open(os.path.join(workdir, "feature.txt"), "a").write("finding fixed at the root\n")
    out = stop(workdir, session, tp, active=True)
    expect('"decision": "block"' in out, "new work-state → the review is re-requested", out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, session, tp, active=True)
    pr = pr_state(branch)
    expect(pr and pr["state"] == "OPEN", "passing review ships the loop's result", out)
    pr_close(pr, branch)


def twist_two_sessions(tag):
    """Two concurrent sessions on one clone: SB's turn starts mid-SA-delivery — SB's Stop must stay
    silent, SA's engagement must survive SB's baselines (the v1 multi-session map on a real forge)."""
    workdir, branch, session, tp = twist_setup(tag, "two-sessions")
    sa, sb = f"{session}-A", f"{session}-B"
    baselines(workdir, sa)
    work(workdir, "feature", "green")
    sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "two sessions",
        "--type", "feat"], check=True)
    baselines(workdir, sb)
    out_b = stop(workdir, sb, tp)
    expect(out_b == "" and pr_state(branch) is None, "SB (baselined on SA's dirty tree) must not ship",
           out_b)
    out = stop(workdir, sa, tp)
    expect('"decision": "block"' in out, "SA held for review — its engagement survived SB's baseline",
           out)
    sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
    out = stop(workdir, sa, tp, active=True)
    pr = pr_state(branch)
    expect(pr is not None and pr["state"] == "OPEN", "SA ships after review; SB never interfered", out)
    pr_close(pr, branch)


def twist_bg_writer(tag):
    """The original coverage-ledger incident, live: a background process holds a claim on a file it is
    mid-writing — the delivery ships around it, the half-written ledger never enters a commit."""
    workdir, branch, session, tp = twist_setup(tag, "bg-writer")
    baselines(workdir, session)
    work(workdir, "feature", "green")
    ledger = os.path.join(workdir, "ledger.json")
    writer = subprocess.Popen([sys.executable, "-c",
        "import sys,time; p=sys.argv[1]; open(p,'w').write('{\"partial\":'); time.sleep(120); "
        "open(p,'w').write('{\"complete\": true}')", ledger])
    try:
        sh([sys.executable, SHIP, "claim", "--repo", workdir, "--path", "ledger.json",
            "--pid", str(writer.pid)], check=True)
        sh([sys.executable, SHIP, "mark-done", "--repo", workdir, "--summary", "bg writer",
            "--type", "feat"], check=True)
        out = stop(workdir, session, tp)
        expect('"decision": "block"' in out, "delivery held for review with the writer mid-flight", out)
        _, names, _ = sh(["git", "-C", workdir, "show", "--pretty=", "--name-only", "HEAD"])
        expect("ledger.json" not in names, "the half-written ledger never entered the commit", names)
        sh([sys.executable, REVIEW, "record", "--repo", workdir, "--score", "95", "--passed"], check=True)
        out = stop(workdir, session, tp, active=True)
        pr = pr_state(branch)
        expect(pr is not None and pr["state"] == "OPEN", "the delivery shipped around the live writer", out)
        _, porc, _ = sh(["git", "-C", workdir, "status", "--porcelain"])
        expect("ledger.json" in porc, "the claimed file stayed in the tree, untouched", porc)
        pr_close(pr, branch)
    finally:
        writer.terminate()
        writer.wait()


TWISTS = {
    "preexisting-dirty": twist_preexisting_dirty,
    "wip-branch": twist_wip_branch,
    "amend-after-push": twist_amend_after_push,
    "mr-closed-mid-watch": twist_mr_closed_mid_watch,
    "manual-push-midflow": twist_manual_push_midflow,
    "review-loop": twist_review_loop,
    "two-sessions": twist_two_sessions,
    "bg-writer": twist_bg_writer,
}


# --- needs: delivery-conductor drives a stated need to a ready PR/MR; this driver plays the model -----

def conductor_hook(event, payload):
    """The conductor's hook as Claude Code runs it; an error, a traceback or unparseable output fails the
    scenario with the hook's full output, never reads as a silent hook."""
    p = subprocess.run([sys.executable, CONDUCTOR, "hook", "--event", event], input=json.dumps(payload),
                       capture_output=True, text=True, timeout=300)
    out = p.stdout.strip()
    try:
        reply = json.loads(out) if out else {}
    except ValueError:
        reply = None
    expect(p.returncode == 0 and not p.stderr.strip() and isinstance(reply, dict) and "systemMessage" not in reply,
           f"the conductor's {event} hook answers cleanly",
           f"rc={p.returncode}\nstdout:\n{out[-2000:]}\nstderr:\n{p.stderr[-2000:]}")
    return reply


def conductor_stop(repo, session):
    return conductor_hook("stop", {"cwd": repo, "session_id": session, "prompt_id": "e2e", "transcript_path": "",
                                   "stop_hook_active": False, "background_tasks": []}).get("reason", "")


def conductor_prompt(repo, session, prompt_id, prompt):
    reply = conductor_hook("prompt", {"cwd": repo, "session_id": session, "prompt_id": prompt_id,
                                      "prompt": prompt, "transcript_path": ""})
    return (reply.get("hookSpecificOutput") or {}).get("additionalContext", "")


def conductor_cli(what, *argv):
    rc, out, err = sh([sys.executable, CONDUCTOR, *argv])
    expect(rc == 0, what, out + err)
    return json.loads(out)


def remote_head(workdir, branch):
    _, out, _ = sh(["git", "-C", workdir, "ls-remote", "origin", f"refs/heads/{branch}"], check=True)
    return out.split()[0] if out else ""


def pof(what, *argv):
    rc, out, err = sh([sys.executable, POF, *argv])
    expect(rc == 0, what, out + err)
    return out


def open_need(tag, name, extra=(), record=True):
    """A need on a fresh clone, its first criterion `<name>.txt exists`; with `record`, that criterion's
    probe is recorded, failing, as the contract asks before any edit."""
    workdir = os.path.join(tempfile.mkdtemp(prefix="harness-e2e-"), "repo")
    clone(workdir)
    json.dump({"gate": "true"}, open(os.path.join(workdir, ".git", "ship-when-done.json"), "w"))
    session = f"e2e-{tag}"
    more = [a for text in extra for a in ("--criterion", text)]
    need = conductor_cli("the conductor opens the need", "open", "--repo", workdir, "--session", session,
                         "--summary", f"e2e need {name}", "--type", "feat", "--criterion", f"{name}.txt exists",
                         *more, "--prompt", f"E2E need {name} ({tag})")
    if record:
        pof("the criterion's probe is recorded, failing, before the work", "record", "--repo", workdir, "--need",
            need["need"], "--criterion", "c1", "--cmd", f"test -f {name}.txt")
    return workdir, session, need["branch"]


def drive(workdir, session, name, implement=True, turns=20, probes=None, fix=None):
    """Do what each conductor instruction names, as the model would, until the need is ready. The need is
    implemented once, and only when `implement`; the contract's probes come from `probes` (criterion id to
    command) and a red criterion is fixed by `fix(criterion)`; anything else the conductor says (a
    blocked need, a second request to implement, a silent Stop) fails with its full text and the output
    of the last background step (a red gate, CI or probe comes back as an instruction)."""
    need = sh(["git", "-C", workdir, "branch", "--show-current"], check=True)[1].split("/", 1)[-1]
    last = ""
    for _ in range(turns):
        why = conductor_stop(workdir, session)
        cmd = re.search(r"`([^`]+)`", why)
        if why.startswith("[conductor] Need ready"):
            return why
        if why.startswith("[conductor] Implement need") and implement:
            implement = False
            work(workdir, name, "green")
            open(os.path.join(workdir, ".mr-watchdog.json"), "w").write('{"poll_interval": 1}')
        elif why.startswith("[conductor] Before any edit, record the probe") and probes:
            for cid in re.findall(r"--criterion (\S+) --cmd", why):
                expect(cid in probes, f"the contract asks for a probe the scenario knows ({cid})", why)
                pof(f"criterion {cid}'s probe is recorded, failing", "record", "--repo", workdir, "--need", need,
                    "--criterion", cid, "--cmd", probes[cid])
        elif why.startswith("[conductor] The probe of criterion") and fix:
            fix(re.match(r"\[conductor\] The probe of criterion (\S+) ", why).group(1))
        elif why.startswith("[conductor] The need advanced through its script steps and ran out of hook time"):
            continue
        elif why.startswith("[conductor] Launch this with run_in_background") and cmd:
            rc, out, err = sh(cmd.group(1), timeout=900)
            last = f"\n--- last background step `{cmd.group(1)}`, exit {rc} ---\n{(out + err)[-1500:]}"
        elif why.startswith("[conductor] Review HEAD") and cmd:
            record = cmd.group(1).replace("<N>", "95").replace("'<JSON list of the findings still open>'", "'[]'")
            rc, out, err = sh(record)
            expect(rc == 0, "the review command the conductor names records the verdict", out + err)
        else:
            raise Failure(f"unexpected conductor instruction:\n{why[-2000:] or '(a silent Stop)'}{last}")
    raise Failure(f"the need never reached ready in {turns} Stops")


def finish(branch):
    pr = pr_state(branch)
    expect(pr and not pr["isDraft"], "a ready need leaves a PR/MR marked ready for review", json.dumps(pr))
    pr_close(pr, branch)


def need_ready(tag):
    workdir, session, branch = open_need(tag, "ready")
    report = drive(workdir, session, "ready")
    ci = next((line for line in report.splitlines() if line.startswith("ci: ")), "")
    head = remote_head(workdir, branch)
    expect(head and f'"sha": "{head}"' in ci and '"verdict": "green"' in ci,
           "the ready report carries a green CI verdict at the pushed head", f"remote {head}\n{report}")
    finish(branch)


def need_halt_resume(tag):
    workdir, session, branch = open_need(tag, "halt")
    expect(conductor_stop(workdir, session).startswith("[conductor] Implement need"),
           "a fresh need asks for its implementation")
    work(workdir, "halt", "green")
    halted = conductor_cli("halt blocks the need", "halt", "--repo", workdir, "--session", session)
    expect(halted.get("work_committed") is True, "halt commits the need's work on its held branch", json.dumps(halted))
    _, head, _ = sh(["git", "-C", workdir, "rev-parse", "HEAD"], check=True)
    expect(conductor_stop(workdir, session) == "", "a halted need is silent at Stop")
    conductor_cli("resume re-arms the need", "resume", "--repo", workdir, "--session", session)
    drive(workdir, session, "halt", implement=False)
    expect(remote_head(workdir, branch) == head, "the work halt committed is what ships, never redone",
           f"halted at {head}, shipped {remote_head(workdir, branch)}")
    finish(branch)


def need_follow_up(tag):
    workdir, session, branch = open_need(tag, "follow")
    drive(workdir, session, "follow")
    first, pr = remote_head(workdir, branch), pr_state(branch)
    nudge = conductor_prompt(workdir, session, f"{tag}-follow-up", "in that PR, also add follow-up.txt")
    expect(" reopen " in nudge, "a prompt on a ready need's branch offers to reopen that need", nudge)
    conductor_cli("a ready need reopens on its branch", "reopen", "--repo", workdir, "--session", session,
                  "--need", branch.split("/", 1)[1])
    work(workdir, "follow-up", "green")
    drive(workdir, session, "follow", implement=False)
    shipped = remote_head(workdir, branch)
    sh(["git", "-C", workdir, "fetch", "-q", "origin", branch], check=True)
    rc, _, _ = sh(["git", "-C", workdir, "cat-file", "-e", "FETCH_HEAD:follow-up.txt"])
    expect(shipped != first and rc == 0, "the follow-up ships on the need's branch, at a new head",
           f"first ready at {first}, now {shipped}, follow-up.txt shipped: {rc == 0}")
    after = pr_state(branch)
    expect(pr and after and after["number"] == pr["number"], "the follow-up ships on the same PR/MR",
           json.dumps([pr, after]))
    finish(branch)


def need_acceptance(tag):
    workdir, session, branch = open_need(tag, "accept", extra=["the change is documented"], record=False)
    need = branch.split("/", 1)[1]
    os.makedirs(os.path.join(workdir, "probes"), exist_ok=True)
    open(os.path.join(workdir, "probes", "accept.sh"), "w").write("test -f accept.txt\n")
    pof("the criterion's probe is recorded failing, its file pinned", "record", "--repo", workdir, "--need", need,
        "--criterion", "c1", "--file", "probes/accept.sh", "--cmd", "bash probes/accept.sh")
    pof("a criterion that is not behavioural is waived", "waive", "--repo", workdir, "--need", need,
        "--criterion", "c2", "--reason", "documentation, reviewed with the diff")
    report = drive(workdir, session, "accept")
    head = remote_head(workdir, branch)
    c1 = next((line for line in report.splitlines() if line.startswith("c1 ")), "")
    expect(c1.startswith("c1 (accept.txt exists): `bash probes/accept.sh` red (exit 1)")
           and f"green at {head[:12]}" in c1 and "(probes/accept.sh)" in c1,
           "the report proves c1 red, then green at the shipped head, its file pinned", f"remote {head}\n{report}")
    expect("c2 (the change is documented): waived: documentation, reviewed with the diff" in report,
           "the report shows c2's waiver", report)
    finish(branch)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def need_env_probe(tag):
    workdir, session, branch = open_need(tag, "envprobe", record=False)
    need, port = branch.split("/", 1)[1], free_port()
    json.dump({"serve": {"cmd": f"{shlex.quote(sys.executable)} -m http.server {port} --bind 127.0.0.1",
                         "base_url": f"http://127.0.0.1:{port}", "ready_path": "/", "timeout": 30}},
              open(os.path.join(workdir, ".git", "proof-of-fix.config.json"), "w"))
    open(os.path.join(workdir, "probe_env.py"), "w").write(
        'import os, urllib.request as u; u.urlopen(os.environ["HARNESS_BASE_URL"] + "/envprobe.txt")\n')
    pof("an env-aware probe is recorded red against the local target", "record", "--repo", workdir, "--need", need,
        "--criterion", "c1", "--env-aware", "--read-only", "--file", "probe_env.py", "--cmd",
        f"{shlex.quote(sys.executable)} probe_env.py")
    report = drive(workdir, session, "envprobe")
    expect("c1 (envprobe.txt exists)" in report and "red (exit 1)" in report and "green at" in report,
           "the env-aware criterion is red, then green against the local target", report)
    status = json.loads(pof("proof-of-fix reports the need", "status", "--repo", workdir, "--need", need))
    checked = status["c1"]["checked"]
    expect(checked.get("env") == "local", "its green run was against the local target, never production",
           json.dumps(checked))
    finish(branch)


def need_amend(tag):
    workdir, session, branch = open_need(tag, "amend")
    expect(conductor_stop(workdir, session).startswith("[conductor] Implement need"),
           "a need with its contract asks for the work")
    work(workdir, "amend", "green")
    open(os.path.join(workdir, ".mr-watchdog.json"), "w").write('{"poll_interval": 1}')
    conductor_cli("an amendment adds a criterion", "amend", "--repo", workdir, "--session", session,
                  "--criterion", "amend-2.txt exists")
    report = drive(workdir, session, "amend", implement=False, probes={"c2": "test -f amend-2.txt"},
                   fix=lambda cid: work(workdir, "amend-2", "green"))
    expect("c2 (amend-2.txt exists): `test -f amend-2.txt` red (exit 1)" in report
           and report.count("green at") >= 2, "the amended criterion was contracted red, then proven green", report)
    finish(branch)


NEEDS = {"ready": need_ready, "halt-resume": need_halt_resume, "follow-up": need_follow_up,
         "acceptance": need_acceptance, "env-probe": need_env_probe, "amend": need_amend}


# --- the watcher: generate, run, classify, self-heal, hand off ---------------------------------------

def generate(seed, count):
    rng = random.Random(seed)
    seen = {tuple(sorted(c.items())) for c in CANONICAL}
    out = list(CANONICAL)
    for _ in range(1000):
        if len(out) >= len(CANONICAL) + count:
            break
        c = {d: rng.choice(v) for d, v in DIMS.items()}
        if tuple(sorted(c.items())) not in seen:
            seen.add(tuple(sorted(c.items())))
            out.append(c)
    return out


def file_issue(sc, tag, err):
    what = scenario_label(sc)
    title = f"e2e: persistent failure — {what} (seed tag {tag})"
    repro = ("need:" + sc["need"] if sc.get("need") else "twist:" + sc["twist"] if sc.get("twist") else
             ("explicit:" if sc.get("mode") == "explicit" else "")
             + f"{sc['flow']}:{sc['gate']}:{sc['ci']}" + (f":{sc['project']}" if sc.get("project") else ""))
    body = (f"The E2E lane failed twice on the same generated scenario.\n\n"
            f"**Scenario**: `{json.dumps(sc)}`  ·  **tag**: `{tag}`\n"
            f"**Reproduce**: `python3 tests/e2e/e2e.py --forge {FORGE} --scenario {repro}`"
            f"\n\n```\n{str(err)[-4000:]}\n```")
    prefix = f"e2e: persistent failure — {what} ("
    _, out, _ = sh(["gh", "issue", "list", "--repo", ISSUE_REPO, "--state", "open", "--limit", "200",
                    "--json", "number,title"])
    try:
        open_issue = next((i["number"] for i in json.loads(out or "[]") if i["title"].startswith(prefix)), None)
    except Exception:
        open_issue = None
    if open_issue:
        rc, _, _ = sh(["gh", "issue", "comment", str(open_issue), "--repo", ISSUE_REPO, "--body", body])
        if rc == 0:
            return
    rc, _, _ = sh(["gh", "issue", "create", "--repo", ISSUE_REPO, "--title", title, "--body", body,
                   "--label", "e2e"])
    if rc != 0:
        sh(["gh", "issue", "create", "--repo", ISSUE_REPO, "--title", title, "--body", body])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=2)
    ap.add_argument("--repo", default=E2E_REPO)
    ap.add_argument("--forge", choices=("github", "gitlab"), default="github",
                    help="which sandbox forge to run against (the ledger keeps one proof per forge)")
    ap.add_argument("--scenario", help="one-off flow:gate:ci[:project], twist:<name> or need:<name>")
    ap.add_argument("--projects", action="store_true",
                    help="full-integration suite over the project archetypes (auto-detected gates)")
    ap.add_argument("--twists", action="store_true",
                    help="human-divergence situations (dirty start, amend, manual push, review loop…)")
    ap.add_argument("--needs", action="store_true",
                    help="delivery-conductor needs, driven from open to a ready PR/MR")
    ap.add_argument("--explicit", action="store_true",
                    help="the EXPLICIT-default set: declaration-driven pipeline, turn-1 inaction")
    ap.add_argument("--coverage", action="store_true", help="print the proven-situations ledger")
    ap.add_argument("--fill", action="store_true",
                    help="run exactly the situations (every space) the ledger has never proven for the "
                         "CURRENT harness (a stale proof is a hole)")
    args = ap.parse_args()
    globals()["E2E_REPO"] = args.repo
    globals()["FORGE"] = args.forge

    if args.coverage:
        coverage_report()
        return
    if args.scenario:
        parts = args.scenario.split(":")
        mode = {}
        if parts[0] == "explicit":
            mode, parts = {"mode": "explicit"}, parts[1:]
        if parts[0] == "twist":
            scenarios = [{"twist": parts[1]}]
        elif parts[0] == "need":
            scenarios = [{"need": parts[1]}]
        else:
            scenarios = [{"flow": parts[0], "gate": parts[1], "ci": parts[2],
                          **({"project": parts[3]} if len(parts) > 3 else {}), **mode}]
    elif args.fill:
        scenarios = stale_scenarios()
    elif args.twists:
        scenarios = ledger_spaces()["twists"]
    elif args.explicit:
        scenarios = ledger_spaces()["explicit"]
    elif args.needs:
        scenarios = ledger_spaces()["needs"]
    elif args.projects:
        scenarios = ledger_spaces()["projects"]
    else:
        scenarios = generate(args.seed, args.count)

    runid = format(int(time.time()) % 36 ** 4, "x")
    print(f"harness-e2e · forge={FORGE}:{E2E_REPO} · seed={args.seed} · run={runid} · {len(scenarios)} scenario(s)")
    sh([sys.executable, SHIP, "claim", "--repo", SKILLS, "--path", "tests/e2e/coverage.json",
        "--pid", str(os.getpid())])
    failures = 0
    try:
        gc_sandbox()
        for i, sc in enumerate(scenarios):
            tag = f"s{args.seed}n{i}r{runid}"
            label = scenario_label(sc)
            t0 = time.time()
            for attempt in (1, 2):
                try:
                    run_scenario(sc, f"{tag}a{attempt}")
                    coverage_record(label, runid, round(time.time() - t0))
                    print(f"  ✓ {label}  ({round(time.time() - t0)}s"
                          + (", flaky: passed on retry)" if attempt == 2 else ")"))
                    break
                except Failure as e:
                    if attempt == 1:
                        cause = str(e).splitlines()[0]
                        print(f"  ↻ {label} failed ({cause}) — retrying once to classify flake vs defect")
                        continue
                    failures += 1
                    print(f"  ✗ {label} — persistent:\n{e}")
                    file_issue(sc, tag, e)
                except Exception as e:
                    failures += 1
                    print(f"  ✗ {label} — infrastructure error: {e}")
                    break
        gc_sandbox()
    finally:
        sh([sys.executable, SHIP, "release", "--repo", SKILLS, "--path", "tests/e2e/coverage.json"])
    print(f"\n{'all green' if failures == 0 else f'{failures} persistent failure(s) — issues filed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
