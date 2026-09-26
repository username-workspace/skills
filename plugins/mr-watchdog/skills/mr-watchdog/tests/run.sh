#!/usr/bin/env bash
# mr-watchdog test suite. The watcher is read-only (polls CI, surfaces the failing log) — it never
# commits/pushes/merges and runs no model. Stubs gh/glab on PATH; throwaway repos with a bare remote.
set -u
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)/scripts"
WATCH="$SCRIPTS/watch.py"
ROOT="$(mktemp -d)"; PASS=0; FAIL=0

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1   # this suite pins the AUTO lanes; the explicit default is pinned in its own block

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
ci="${STUB_CI:-pending}"
case "$1 $2" in
  "pr view")   echo "{\"state\":\"${STUB_MR_STATE:-OPEN}\"}";;
  "pr checks") case "$ci" in success) echo '[{"bucket":"pass"}]';; failed) echo '[{"bucket":"fail"}]';; pending) echo '[{"bucket":"pending"}]';; none) echo '[]';; esac;;
  api*check-runs*) echo "$2" >> "${GH_API_LOG:-/dev/null}"
     case "$ci" in
       success) echo '{"check_runs":[{"status":"completed","conclusion":"success"}]}';;
       failed)  echo '{"check_runs":[{"status":"completed","conclusion":"failure"}]}';;
       pending) echo '{"check_runs":[{"status":"in_progress","conclusion":null}]}';;
       none)    echo '{"check_runs":[]}';;
     esac;;
  "run list")  echo '[{"databaseId":1}]';;
  "run view")  echo "JOB FAILED: AssertionError at app.py:7";;
  *) exit 0;;
esac
EOF
# glab speaks the real GitLab REST shapes: pipelines come from $STUB_GL_PIPELINES (a JSON list; when
# absent, one pipeline for HEAD on the current branch in the $STUB_CI state), filtered by the query's
# sha/ref and ordered newest first like the API; failed jobs from $STUB_GL_JOBS; traces per job id.
# `ci status` prints glab 1.90's human format; `ci trace` is the interactive job picker — never usable.
cat > "$ROOT/bin/glab" <<'EOF'
#!/usr/bin/env bash
ci="${STUB_CI:-pending}"
case "$1 $2" in
  "mr list")   echo "[{\"iid\":4,\"state\":\"${STUB_MR_STATE_GL:-opened}\"}]";;
  "ci status") if [ "$ci" = none ]; then echo "No pipeline found for branch x"; exit 1; fi
               printf 'https://gitlab.com/t/r/-/pipelines/1\nSHA: x\nPipeline state: %s\n' "$ci";;
  "ci trace")  echo "INTERACTIVE-PICKER"; exit 1;;
  api*) echo "$2" >> "${GL_API_LOG:-/dev/null}"
     case "$2" in
       *"/pipelines?"*) python3 - "$2" "$ci" <<'PY'
import json, os, subprocess, sys
from urllib.parse import parse_qs, urlsplit
q = {k: v[0] for k, v in parse_qs(urlsplit(sys.argv[1]).query).items()}
fx = os.environ.get("STUB_GL_PIPELINES")
if fx:
    arr = json.load(open(fx))
else:
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    br = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
    st = {"success": "success", "failed": "failed", "pending": "running"}.get(sys.argv[2])
    arr = [{"id": 1, "sha": head, "ref": br, "status": st}] if st else []
arr = [p for p in arr if all(p.get(k) == q[k] for k in ("sha", "ref") if k in q)]
arr.sort(key=lambda p: -p["id"])
print(json.dumps(arr[: int(q.get("per_page", 20))]))
PY
       ;;
       *"/jobs?"*)  if [ -n "${STUB_GL_JOBS:-}" ]; then cat "$STUB_GL_JOBS"
                    else echo '[{"id":7,"name":"test","status":"failed","allow_failure":false}]'; fi;;
       */jobs/*/trace) echo "JOB ${2//[^0-9]/} FAILED: AssertionError at app.py:7";;
       *"/merge_requests?"*) if [ -n "${STUB_GL_MRS:-}" ]; then cat "$STUB_GL_MRS"; else echo '[]'; fi;;
       */merge_requests/*) cat "${STUB_GL_MR:-/dev/null}";;
       */repository/commits/*) cat "${STUB_GL_COMMIT:-/dev/null}";;
       *) echo '[]';;
     esac;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh" "$ROOT/bin/glab"; export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir [$2=host] [$3=branch]
  local d="$1" host="${2:-github.com}" br="${3:-feat}"
  mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" config remote.origin.pushurl "$d.git"
  git -C "$d" config remote.origin.url "https://$host/test/repo.git"
  git -C "$d" push -q -u origin main 2>/dev/null
  [ "$br" != main ] && git -C "$d" checkout -q -b "$br"
  printf '{}' > "$d/.mr-watchdog.json"
}
tick(){ python3 "$WATCH" tick --repo "$1" 2>&1; }
guard_reason(){ python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch
try:
    watch.guard_state('$1', dict(watch.load_config('$1'))); print('OK')
except ValueError as e: print(str(e))"; }
count(){ git -C "$1" rev-list --count "$2" 2>/dev/null || echo -1; }

echo "mr-watchdog tests"

# 1. pure: fake-green pattern detection (used by `verify`)
cat > "$ROOT/t1.py" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"1. "+m)
bad=["--no-verify","run || true","@pytest.mark.skip","it.skip('x')","# type: ignore","allow_failure: true",
     "continue-on-error: true","@ts-ignore","@ts-expect-error","xit('x')",".skip(","assert True","--maxfail=0",
     "when: never","skip_tests=1","eslint-disable no-console","self.skipTest('x')"]
for b in bad: ck(watch.bypass_in_diff(b), "fake-green flagged: "+b[:24])
good=["def f(): return 1","assert x==2","# noqa: E501 url","fixed the off-by-one","const y=2","return None"]
for g in good: ck(watch.bypass_in_diff(g) is None, "honest change allowed: "+g[:24])
ck(watch.added_lines("+++ b/f\n+bad || true\n-old\n ctx")=="bad || true","added_lines extracts + only")
PY
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t1.py" "$SCRIPTS")

# 2. pure: ci_status mapping (github + gitlab) + mr_open via stubs
cat > "$ROOT/t2.py" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); R=sys.argv[2]; import watch
def ck(c,m): print(("PASS " if c else "FAIL ")+"2. "+m)
for forge in ("github","gitlab"):
    for want in ("success","failed","pending","none"):
        os.environ["STUB_CI"]=want
        ck(watch.ci_status(R, forge, "feat")==want, f"ci_status {forge}:{want}")
ck(watch.mr_open(R,"github","feat") is True, "mr_open github OPEN")
os.environ["STUB_MR_STATE"]="MERGED"; ck(watch.mr_open(R,"github","feat") is False, "mr_open github not-open")
PY
new_repo "$ROOT/t2repo" gitlab.com
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done < <(python3 "$ROOT/t2.py" "$SCRIPTS" "$ROOT/t2repo")

# 2g. GitLab: the verdict is the exact commit's pipelines on THIS branch (or its MR refs), latest per
# ref — never another ref sharing the sha (policy, workload pipelines), never a human-format parse;
# the failing log comes from the failed jobs' traces, never the interactive `glab ci trace` picker.
new_repo "$ROOT/gl" gitlab.com
echo w > "$ROOT/gl/w.txt"; git -C "$ROOT/gl" add -A; git -C "$ROOT/gl" commit -qm w
cat > "$ROOT/t2g.py" <<'PY'
import json, os, sys; sys.path.insert(0, sys.argv[1]); R=sys.argv[2]; import watch, subprocess
def ck(c,m): print(("PASS " if c else "FAIL ")+"2g. "+m)
sha = subprocess.run(["git","-C",R,"rev-parse","HEAD"],capture_output=True,text=True).stdout.strip()
fx = os.path.join(os.path.dirname(R), "pipelines.json"); os.environ["STUB_GL_PIPELINES"] = fx
def at(pipes):
    json.dump([dict(p, sha=p.get("sha", sha)) for p in pipes], open(fx, "w"))
    return watch.ci_status_at(R, "gitlab", sha, "feat")
ck(at([{"id":9,"ref":"refs/workloads/abc","status":"success"},{"id":5,"ref":"feat","status":"failed"}])=="failed",
   "a newer pipeline of another ref on the same sha is not this branch's verdict")
ck(at([{"id":5,"ref":"feat","status":"failed"},{"id":6,"ref":"feat","status":"success"}])=="success",
   "a re-run pipeline supersedes the failed one (latest per ref)")
ck(at([{"id":2,"ref":"feat","status":"skipped"}])!="success", "a skipped pipeline is never a green verdict")
ck(at([{"id":2,"ref":"feat","status":"manual"}])!="success", "a manual (blocked) pipeline is never a green verdict")
ck(at([{"id":2,"ref":"feat","status":"success","sha":"0"*40}])=="none", "a pipeline for another sha is no verdict")
ck(at([])=="none", "no pipeline yet → none (keep polling)")
json.dump([{"id":8,"ref":"feat","status":"success","sha":sha}], open(fx,"w"))
os.environ["STUB_CI"]="failed"
ck(watch.ci_status(R, "gitlab", "feat")=="success",
   "branch status reads the pipeline state, not job lines (allowed-to-fail jobs don't turn it red)")
json.dump([{"id":8,"ref":"feat","status":"failed","sha":sha}], open(fx,"w"))
jobs = os.path.join(os.path.dirname(R), "jobs.json"); os.environ["STUB_GL_JOBS"] = jobs
json.dump([{"id":7,"name":"test","status":"failed","allow_failure":False},
           {"id":31,"name":"lint","status":"failed","allow_failure":True}], open(jobs,"w"))
log = watch.failing_log(R, "gitlab", "feat", sha)
ck("JOB 7 FAILED" in log, "failing log = the failed job's trace")
ck("JOB 31" not in log, "an allowed-to-fail job is not the failure")
ck("INTERACTIVE-PICKER" not in log, "never the interactive glab ci trace")
ck("JOB 7 FAILED" in watch.failing_log(R, "gitlab", "feat"), "branch-level failing log resolves the latest pipeline")
# With an open MR, GitLab's own gate decides: the MR's head pipeline, whatever its kind. A merged-results
# or train pipeline runs on a merge commit whose parents include the watched sha.
d = os.path.dirname(R)
mrs, mr, commit = (os.path.join(d, n) for n in ("mrs.json", "mr.json", "commit.json"))
os.environ.update(STUB_GL_MRS=mrs, STUB_GL_MR=mr, STUB_GL_COMMIT=commit)
def with_mr(mr_sha, hp, parents=()):
    json.dump([{"iid": 4, "sha": mr_sha, "project_id": 1, "source_project_id": 1}], open(mrs, "w"))
    json.dump({"iid": 4, "sha": mr_sha, "head_pipeline": hp}, open(mr, "w"))
    json.dump({"id": (hp or {}).get("sha"), "parent_ids": list(parents)}, open(commit, "w"))
json.dump([{"id":9,"ref":"feat","status":"skipped","sha":sha}], open(fx,"w"))
merge = {"id": 20, "ref": "refs/merge-requests/4/merge", "sha": "m"*40, "status": "failed"}
with_mr(sha, merge, parents=("b"*40, sha))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="failed",
   "a failed merged-results pipeline gates the MR, a skipped branch pipeline on the sha is not a green")
ck(watch.ci_status(R, "gitlab", "feat")=="failed", "branch status follows the MR's gate too")
with_mr(sha, dict(merge, status="success"), parents=("b"*40, sha))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="success", "a green merged-results pipeline for this sha is the verdict")
with_mr(sha, dict(merge, status="success"), parents=("b"*40, "c"*40))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="none", "a merged-results pipeline built for an older head is no verdict yet")
with_mr("c"*40, dict(merge, status="success", sha="c"*40))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="none", "an MR not yet updated to the watched sha gives no verdict")
with_mr(sha, None)
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="none", "an MR with no pipeline yet gives no verdict")
with_mr(sha, {"id": 3, "ref": "refs/merge-requests/4/head", "sha": sha, "status": "running"})
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="pending", "the MR pipeline still running keeps the verdict pending")
with_mr(sha, merge, parents=("b"*40, sha))
json.dump([{"id":7,"name":"test","status":"failed","allow_failure":False}], open(jobs,"w"))
ck("JOB 7 FAILED" in watch.failing_log(R, "gitlab", "feat", sha), "the failing log comes from the MR's gating pipeline")
with_mr(sha, {"id": 21, "ref": "feat", "sha": "d"*40, "status": "success"}, parents=(sha,))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="none",
   "a stale branch pipeline built on a child commit is not this sha's verdict (the parent rule is for merge refs)")
with_mr(sha, dict(merge, ref="refs/merge-requests/4/train", status="success"), parents=("b"*40, sha))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="success", "a merge-train pipeline for this sha is the verdict")
json.dump([{"iid": 9, "sha": "f"*40, "project_id": 1, "source_project_id": 2}], open(mrs, "w"))
json.dump([{"id":30,"ref":"feat","status":"failed","sha":sha}], open(fx,"w"))
ck(watch.ci_status_at(R, "gitlab", sha, "feat")=="failed",
   "another contributor's fork MR on the same branch name is not this branch's MR")
log_path = os.path.join(d, "glapi.log"); os.environ["GL_API_LOG"] = log_path; open(log_path, "w").close()
with_mr(sha, dict(merge, project_id=77), parents=("b"*40, sha))
watch.failing_log(R, "gitlab", "feat", sha)
ck("projects/77/pipelines/20/jobs" in open(log_path).read(), "jobs of a pipeline that lives in another project are read from that project")
PY
out=$(python3 "$ROOT/t2g.py" "$SCRIPTS" "$ROOT/gl" 2>&1); rc=$?
while IFS= read -r l; do case "$l" in PASS*) ok "${l#PASS }";; FAIL*) ko "${l#FAIL }";; esac; done <<< "$out"
assert_eq 0 "$rc" "2g. the GitLab verdict probe ran to the end — ${out##*$'\n'}"

# 3. guard refusals
d="$ROOT/g_main"; new_repo "$d" github.com main
assert_eq "on-default-branch" "$(guard_reason "$d")" "3. refuse on default branch"
d="$ROOT/g_dev"; new_repo "$d" github.com develop
assert_eq "on-default-branch" "$(guard_reason "$d")" "3. refuse on a common trunk (develop)"
d="$ROOT/g_feat"; new_repo "$d" github.com feat
assert_eq "OK" "$(guard_reason "$d")" "3. allow on a feature branch"
d="$ROOT/g_wip"; new_repo "$d" github.com wip/spike
assert_eq "skip-marker" "$(guard_reason "$d")" "3. refuse a wip/ branch"
d="$ROOT/g_det"; new_repo "$d" github.com feat; git -C "$d" checkout -q --detach HEAD
assert_eq "detached-or-unborn" "$(guard_reason "$d")" "3. refuse detached HEAD"
d="$ROOT/g_unk"; new_repo "$d" example.com feat
assert_eq "no-forge-cli" "$(guard_reason "$d")" "3. refuse unknown forge (no CLI)"

# 4. tick: green / pending / no-mr / branch-changed
d="$ROOT/t_green"; new_repo "$d"; assert_contains '"green"' "$(STUB_CI=success tick "$d")" "4. CI success → green"
d="$ROOT/t_pend"; new_repo "$d";  assert_contains '"continue"' "$(STUB_CI=pending tick "$d")" "4. CI pending → continue"
d="$ROOT/t_nomr"; new_repo "$d";  assert_contains '"no-mr"' "$(STUB_CI=failed STUB_MR_STATE=CLOSED tick "$d")" "4. no open MR → no-mr"

# 5. tick: failed → needs-fix WITH the failing log, and READ-ONLY (no commit, HEAD unchanged)
d="$ROOT/t_fail"; new_repo "$d"; before=$(count "$d" HEAD)
out=$(STUB_CI=failed tick "$d")
assert_contains '"needs-fix"' "$out" "5. CI failed → needs-fix (handoff, no autonomous fix)"
assert_contains 'AssertionError' "$out" "5. the failing job log is carried into the handoff"
assert_eq "$before" "$(count "$d" HEAD)" "5. READ-ONLY: tick made no commit"
git -C "$d" diff --quiet && ok "5. READ-ONLY: working tree untouched" || ko "5. working tree untouched"

# 6. verify: honest fix passes; every fake-green is caught (exit 1)
d="$ROOT/v"; new_repo "$d"
printf 'def pay(a,b):\n    return a+b\n' > "$d/app.py"; mkdir -p "$d/tests"
printf 'from app import pay\ndef test_pay():\n    assert pay(2,2)==4\n' > "$d/tests/test_app.py"
git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm base
printf 'def pay(a,b):\n    return a+b  # real fix\n' > "$d/app.py"   # honest edit
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "6. honest fix → verify passes (exit 0)"
assert_contains 'no bypass' "$out" "6. honest fix → reported clean"
git -C "$d" checkout -- app.py
printf 'run-tests || true\n' >> "$d/ci.sh"                          # bypass marker in a new file
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "6. '|| true' → verify fails (exit 1)"
assert_contains 'fake-green' "$out" "6. bypass marker flagged as fake-green"
rm -f "$d/ci.sh"
git -C "$d" rm -q tests/test_app.py                                  # delete a test
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "6. deleting a test → verify fails"
assert_contains 'deleted-test' "$out" "6. deleted test flagged"
git -C "$d" reset -q --hard HEAD
printf 'from app import pay\ndef test_pay():\n    assert True\n' > "$d/tests/test_app.py"   # gut a test
out=$(python3 "$WATCH" verify --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "6. gutting a test (assert True) → verify fails"
assert_contains 'green' "$out" "6. weakened/assert-True test flagged"

# 7. run (the bg watcher): poll until the pipeline resolves, then exit with the verdict (read-only)
d="$ROOT/run"; new_repo "$d"; before=$(count "$d" HEAD)
printf '{"poll_interval":1}' > "$d/.mr-watchdog.json"
out=$(STUB_CI=success python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_contains "ok, all good" "$out" "7. green → the wake word"
assert_eq 0 "$rc" "7. green → exit 0"
out=$(STUB_CI=failed python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_contains 'ROOT CAUSE' "$out" "7. red → hands the failure back to fix the root cause"
assert_contains 'AssertionError' "$out" "7. red → carries the failing job log"
assert_contains 'verify' "$out" "7. red → verify before commit"
assert_eq 1 "$rc" "7. red → exit 1 (so the harness re-invokes with a failure)"
assert_eq "$before" "$(count "$d" HEAD)" "7. READ-ONLY: the watcher made no commit"
git -C "$d" diff --quiet && ok "7. READ-ONLY: working tree untouched" || ko "7. working tree untouched"
assert_contains 'no open merge request' "$(STUB_CI=failed STUB_MR_STATE=CLOSED python3 "$WATCH" run --repo "$d" 2>&1)" "7. MR closed → watcher exits, does not watch"
printf '{"on_red":"notify","poll_interval":1}' > "$d/.mr-watchdog.json"
out=$(STUB_CI=failed python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_absent 'ROOT CAUSE' "$out" "7. on_red=notify → no fix directive"
assert_contains 'CI red' "$out" "7. on_red=notify → passive red report"
assert_eq 1 "$rc" "7. on_red=notify → still exit 1"
printf '{}' > "$d/.mr-watchdog.json"

# 7b. the verdict is bound to the WATCHED SHA — a stale branch-level red (previous run, fresh push)
# must never produce a red verdict while this sha has no registered checks yet
d="$ROOT/flip"; new_repo "$d"
printf '{"poll_interval":1}' > "$d/.mr-watchdog.json"
mkdir -p "$ROOT/flipbin"
cat > "$ROOT/flipbin/gh" <<FLIPGH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view") echo '{"state":"OPEN"}';;
  "pr checks") echo '[{"bucket":"fail"}]';;
  api*check-runs*) echo "\$2" >> "$ROOT/gh-api.log"
     if [ -f "$ROOT/flip-done" ]; then echo '{"check_runs":[{"status":"completed","conclusion":"success"}]}'
     else touch "$ROOT/flip-done"; echo '{"check_runs":[]}'; fi;;
  *) exit 0;;
esac
FLIPGH
chmod +x "$ROOT/flipbin/gh"; : > "$ROOT/gh-api.log"
out=$(env PATH="$ROOT/flipbin:$PATH" python3 "$WATCH" run --repo "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "7b. branch-level stale red + sha not yet registered → green, never a false red"
assert_contains 'ok, all good' "$out" "7b. the verdict belongs to the watched sha"
grep -q "$(git -C "$d" rev-parse HEAD)" "$ROOT/gh-api.log" && ok "7b. the status query carries the watched sha" || ko "7b. the status query carries the watched sha"

# 9. engagement: a branch is watched only if THIS session pushed it (no opt-in file needed)
d="$ROOT/eng"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session S)" "9. baseline, no new push → not engaged (just visiting)"
echo z > "$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
assert_eq "yes" "$(python3 "$WATCH" engaged --repo "$d" --session S)" "9. session pushed the branch → engaged"
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session OTHER)" "9. a different session (no baseline) → not engaged"
printf '{"enabled":false}' > "$d/.mr-watchdog.json"
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session S)" "9. enabled:false opts the repo out"
dm="$ROOT/em"; new_repo "$dm" github.com main
python3 "$WATCH" baseline --repo "$dm" --session S >/dev/null
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$dm" --session S)" "9. default branch → never engaged"
d="$ROOT/o2"; new_repo "$d"
assert_contains 'no open merge request' "$(STUB_MR_STATE=CLOSED python3 "$WATCH" run --repo "$d" 2>&1)" "9. no open MR → the watcher exits immediately (nothing to watch)"
# two concurrent sessions: the second baseliner must not erase the first session's engagement
d="$ROOT/eng2"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session SA >/dev/null
echo z > "$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session SB >/dev/null
assert_eq "yes" "$(python3 "$WATCH" engaged --repo "$d" --session SA)" "9. SA still engaged after SB baselined"
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session SB)" "9. SB (baselined on the pushed tip) → not engaged"
# the legacy single-session migration window (one minor) is CLOSED: a pre-v1 file is ignored
printf '{"session":"OLD","branches":{"feat":{"engaged":true}}}' > "$d/.git/mr-watchdog-session.json"
assert_eq "no" "$(python3 "$WATCH" engaged --repo "$d" --session OLD)" "9. legacy pre-v1 file → ignored (migration window closed)"

# 10. GUARDRAILS: the watcher is read-only — no commit / push / merge anywhere in the source
grep -Eq "['\"]merge['\"]" "$WATCH" && ko "10. never merges (no merge command)" || ok "10. never merges (no merge command in source)"
grep -Eq 'git[^\n]*(commit|push)|"-A"|reset[^\n]*hard|checkout[^\n]*--' "$WATCH" && ko "10. read-only: no git mutation in the watcher" || ok "10. read-only: never commits, pushes, or mutates the tree"
grep -q 'claude' "$WATCH" && ko "10. runs no model itself" || ok "10. runs no model itself (no 'claude' anywhere in the watcher)"

# 11. hook (Stop-hook launch trigger): engaged + open MR + live CI → block to launch the bg watcher
d="$ROOT/hk"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w
git -C "$d" push -q origin feat 2>/dev/null     # this session pushed the branch → engaged
out=$(STUB_CI=pending python3 "$WATCH" hook --repo "$d" --session S)
assert_contains '"decision": "block"' "$out" "11. engaged + open MR + CI running → block to launch a bg watcher"
assert_contains 'run_in_background' "$out" "11. the block tells the session to launch it in the background"
assert_contains 'run --repo' "$out" "11. the block carries the watcher command"
assert_eq "" "$(STUB_CI=pending python3 "$WATCH" hook --repo "$d" --session S)" "11. asked once per HEAD → silent next time"
assert_eq "" "$(STUB_CI=pending python3 "$WATCH" hook --repo "$d" --session OTHER)" "11. different session (not engaged) → silent"
d="$ROOT/hk2"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
assert_eq "" "$(STUB_CI=none python3 "$WATCH" hook --repo "$d" --session S)" "11. no pipeline yet → silent (nothing to watch)"
assert_eq "" "$(STUB_CI=pending STUB_MR_STATE=CLOSED python3 "$WATCH" hook --repo "$d" --session S)" "11. no open MR → silent"
# INCIDENT: CI already green at the Stop instant → the session was never told the verdict (it would
# announce stale state or re-check by hand). The hook must hand the green over, once per HEAD,
# bound to the EXACT sha — never the branch-level status
d="$ROOT/hk3"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session S >/dev/null
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
GH_API_LOG="$ROOT/hk3-api.log"; : > "$GH_API_LOG"
out=$(STUB_CI=success GH_API_LOG="$GH_API_LOG" python3 "$WATCH" hook --repo "$d" --session S)
assert_contains '"decision": "block"' "$out" "11. CI already green at Stop → the verdict is handed to the session"
assert_contains 'ok, all good' "$out" "11. the green handoff carries the wake word"
assert_contains 'never merges' "$out" "11. the handoff restates the read-only guardrail"
grep -q "$(git -C "$d" rev-parse HEAD)" "$GH_API_LOG" && ok "11. the green verdict is bound to the exact sha" || ko "11. the green verdict is bound to the exact sha"
assert_eq "" "$(STUB_CI=success python3 "$WATCH" hook --repo "$d" --session S)" "11. green handoff once per HEAD → silent next time"

# 12. Stop-hook plumbing: resolves the repo, gated on engagement; emits the launch block; re-entrancy
PLUGIN="$(cd "$(dirname "$WATCH")/../../.." && pwd)"
HOOK="$PLUGIN/hooks/stop-hook.py"
d="$ROOT/sh"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session X >/dev/null
out=$(echo "{\"cwd\":\"$d\",\"session_id\":\"X\",\"stop_hook_active\":false}" | STUB_CI=pending CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK" 2>/dev/null)
assert_eq "" "$out" "12. not engaged (no push this session) → Stop hook silent"
echo z>"$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
out=$(echo "{\"cwd\":\"$d\",\"session_id\":\"X\",\"stop_hook_active\":false}" | STUB_CI=pending CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK" 2>/dev/null)
assert_contains '"decision": "block"' "$out" "12. engaged + open MR + CI running → Stop hook emits the launch block"
out=$(echo "{\"cwd\":\"$d\",\"session_id\":\"X\",\"stop_hook_active\":true}" | STUB_CI=pending CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$HOOK" 2>/dev/null)
assert_eq "" "$out" "12. re-entrancy: stop_hook_active → hook silent"

# 13. resolve: active repo (subdir / push command / transcript), root-anchored
rr="$ROOT/r13"; new_repo "$rr"   # on branch feat, with origin
rsub="$rr/a/b/c"; mkdir -p "$rsub"; rtop="$(git -C "$rr" rev-parse --show-toplevel)"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --cwd "$rsub")" "13. resolve: deep subdir → repo root"
rnr="$ROOT/r13-nr"; mkdir -p "$rnr"
assert_eq "" "$(python3 "$WATCH" resolve --cwd "$rnr")" "13. resolve: non-repo cwd → empty"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --command "git -C $rr push origin feat")" "13. resolve: git -C X push → X root"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --command "cd $rr && git push")" "13. resolve: cd X && git push → X root"
rtp="$ROOT/r13.jsonl"; printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/app.txt"}}]}}\n' "$rsub" > "$rtp"
assert_eq "$rtop" "$(python3 "$WATCH" resolve --cwd "$rnr" --transcript "$rtp")" "13. resolve: transcript last-edit → its repo root"
python3 "$WATCH" baseline --repo "$rsub" --session s1
[ -f "$rtop/.git/mr-watchdog-session.json" ] && ok "13. root-anchor: baseline from subdir → state at repo root" || ko "13. root-anchor subdir"

# 14. EXPLICIT MODE (the default — HARNESS_AUTO_ENGAGE unset): upstream-advance inference is off;
# only ship-when-done's handoff stamp engages the watcher.
d="$ROOT/exp"; new_repo "$d"; git -C "$d" push -q -u origin feat 2>/dev/null
python3 "$WATCH" baseline --repo "$d" --session SX >/dev/null
echo z > "$d/z"; git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -qm w; git -C "$d" push -q origin feat 2>/dev/null
assert_eq "no" "$(env -u HARNESS_AUTO_ENGAGE python3 "$WATCH" engaged --repo "$d" --session SX)" \
  "14. pushed-since-baseline inference → OFF by default"
printf '{"v":1,"sessions":{"SX":{"started":"2030-01-01T00:00:00+00:00","branches":{"feat":{"engaged":true}}}}}' > "$d/.git/mr-watchdog-session.json"
assert_eq "yes" "$(env -u HARNESS_AUTO_ENGAGE python3 "$WATCH" engaged --repo "$d" --session SX)" \
  "14. ship's handoff stamp → engaged regardless of mode"

# 15. malformed numeric config coerces to the default — never a ValueError mid-watch (poll/log/timeout)
cfgnum(){ python3 -c "import sys; sys.path.insert(0,'$SCRIPTS'); import watch; print(watch.load_config('$1')['$2'])"; }
d="$ROOT/cfgnum"; new_repo "$d"
printf '{"poll_interval":"abc","log_lines":"x","watch_timeout":[]}' > "$d/.mr-watchdog.json"
assert_eq 30   "$(cfgnum "$d" poll_interval)" "15. non-numeric poll_interval → default 30"
assert_eq 200  "$(cfgnum "$d" log_lines)"     "15. non-numeric log_lines → default 200"
assert_eq 3600 "$(cfgnum "$d" watch_timeout)" "15. non-numeric watch_timeout → default 3600"
printf '{"poll_interval":5}' > "$d/.mr-watchdog.json"
assert_eq 5 "$(cfgnum "$d" poll_interval)" "15. a valid numeric override is preserved"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
