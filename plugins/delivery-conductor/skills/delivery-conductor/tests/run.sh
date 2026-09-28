#!/usr/bin/env bash
# delivery-conductor: a need driven from open to ready through the real sibling stage CLIs and the real
# hooks at the real wire format. Throwaway repos with a bare remote, a stubbed gh, a green gate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$(cd "$HERE/../../.." && pwd)"
CS="$PL/skills/delivery-conductor/scripts/conductor.py"
REPO_ROOT="$(cd "$PL/../.." && pwd)"
POF="$REPO_ROOT/plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py"
ROOT="$(mktemp -d)"
. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1 HARNESS_LIVE_DIR="$ROOT/live" CLAUDE_PID=4242
unset CLAUDE_CODE_SESSION_ID

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$ROOT/gh.log"
case "\$1 \$2" in
  "pr create") echo "https://example.test/pr/1";;
  "pr view") echo '{"state":"OPEN","isDraft":true,"url":"https://example.test/pr/1","number":1}';;
  "pr list") echo '[]';;
  "pr checks") echo '[{"bucket":"pass"}]';;
  api*) case "\$*" in *check-runs*) echo '{"check_runs":[{"status":"completed","conclusion":"success"}]}';; *) echo '{}';; esac;;
esac
exit 0
EOF
chmod +x "$ROOT/bin/gh"; export PATH="$ROOT/bin:$PATH"

new_repo(){ local d="$1"; git init -q -b main "$d"
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" config remote.origin.pushurl "$d.git"; git -C "$d" config remote.origin.url "https://github.com/test/repo.git"
  git -C "$d" push -q -u origin main 2>/dev/null
  printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; }
hook(){ CLAUDE_PLUGIN_ROOT="$PL" python3 "$PL/hooks/hook.py" "$1"; }
payload(){ # $1=repo $2=session $3=prompt_id [$4=prompt] [$5=background_tasks] [$6=source] [$7=transcript]
  python3 -c 'import json,sys; a=sys.argv[1:]
print(json.dumps({"session_id": a[1], "cwd": a[0], "prompt_id": a[2], "prompt": a[3], "transcript_path": a[6],
  "stop_hook_active": False, "background_tasks": json.loads(a[4] or "[]"), "source": a[5]}))' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"; }
stop(){ payload "$1" "${2:-s1}" "${3:-p1}" "" "${4:-}" | hook stop; }
reason(){ python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t).get("reason","") if t else "")'; }
quoted(){ python3 -c 'import re,sys; m=re.search(r"`([^`]+)`", sys.stdin.read()); print(m.group(1) if m else "")'; }
ledger(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/.git/conductor.json"))'"$2"')' "$1"; }
open_need(){ local n; n=$(python3 "$CS" open --repo "$1" --session "${2:-s1}" --summary "add a greeting" --criterion "hello.txt says hello" \
  --prompt "add a greeting" | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])')
  python3 "$POF" waive --repo "$1" --need "$n" --criterion c1 --reason "not what this case proves" >/dev/null; echo "$n"; }

echo "delivery-conductor"

# 1. a prompt with no need in flight: the contract nudge, and the liveness stamp the siblings rely on
d="$ROOT/r1"; new_repo "$d"
assert_contains "open a need" "$(payload "$d" s1 p0 "add a greeting" | hook prompt)" "1. a prompt in scope suggests opening a need"
assert_contains '"p0"' "$(cat "$ROOT/live/s1.json")" "1. the prompt hook stamps the conductor live for this prompt"
assert_eq "" "$(payload "$d" s1 p0 "<task-notification>x</task-notification>" | hook prompt)" "1. a machine envelope is never a need"
assert_eq "absent" "$([ -e "$d/.git/conductor.json" ] && echo present || echo absent)" "1. a prompt with nothing to record writes no ledger"

# 2. open: the need's own branch and its ledger entry
nid=$(open_need "$d")
assert_eq "need/$nid" "$(git -C "$d" branch --show-current)" "2. open checks out the need's branch"
assert_eq "active" "$(ledger "$d" "['needs']['$nid']['state']")" "2. the need is active in the ledger"
assert_eq "True" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k
k.stamp_live("s1", "p1", True); print(k.driven(sys.argv[2], "s1", "p1"))' "$REPO_ROOT/lib" "$d")" "2. its branch is driven: every sibling stands down"

# 3. from open to ready: every step named by its owner, only judgment steps handed to the model
assert_contains "Implement need $nid" "$(stop "$d" | reason)" "3. no work yet → the model is asked to implement"
echo hello > "$d/hello.txt"
out=$(stop "$d" | reason); gate=$(echo "$out" | quoted)
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "3. the conductor commits the work itself"
assert_contains "gate --need $nid" "$gate" "3. the gate comes back as a background step carrying the need token"
assert_eq "" "$(stop "$d" s1 p1 "[{\"id\":\"t1\",\"status\":\"running\",\"command\":\"$gate\"}]")" "3. while that step runs the conductor waits (no instruction, no stall)"
bash -c "$gate" >/dev/null 2>&1
out=$(stop "$d" | reason)
assert_contains "merge-review" "$out" "3. gate green, nothing to prove → the review is the next judgment step"
assert_contains "need:$nid" "$out" "3. and it names the need token the review subagent must carry"
python3 "$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py" record --repo "$d" --sha HEAD --score 95 >/dev/null
watch=$(stop "$d" | reason | quoted)
assert_contains "run --need $nid" "$watch" "3. reviewed → shipped by script steps, then the CI watcher as a background step"
assert_eq "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d.git" rev-parse "need/$nid")" "3. the branch is pushed at HEAD"
bash -c "$watch" >/dev/null 2>&1
out=$(stop "$d" | reason)
assert_contains "Need ready" "$out" "3. CI green → marked ready and reported"
assert_contains "pr ready" "$(cat "$ROOT/gh.log")" "3. the draft PR is marked ready"
assert_eq "ready" "$(ledger "$d" "['needs']['$nid']['state']")" "3. a ready need is marked ready"
payload "$d" s1 p5 "thanks" | hook prompt >/dev/null
assert_eq "{}" "$(ledger "$d" "['needs']")" "3. and leaves the ledger at the next prompt: its branch is not driven any more"
assert_eq "$nid" "$(ledger "$d" "['history'][-1]['id']")" "3. and it is kept in the history"
assert_eq "" "$(stop "$d")" "3. after ready the conductor is silent"

# 4. a stall: the same blocking decision three times with no change blocks the need, and says so once
d="$ROOT/r4"; new_repo "$d"; nid=$(open_need "$d")
stop "$d" >/dev/null; stop "$d" >/dev/null
out=$(stop "$d" | reason)
assert_contains "is blocked: no progress" "$out" "4. the third identical blocking decision blocks the need"
assert_eq "blocked" "$(ledger "$d" "['needs']['$nid']['state']")" "4. the ledger holds it blocked (branch still driven)"
assert_eq "" "$(stop "$d")" "4. a blocked need is reported once, then silent"

# 5. every human prompt is classified before the need advances; halt holds the branch, resume re-arms
d="$ROOT/r5"; new_repo "$d"; nid=$(open_need "$d")
assert_contains "Classify this prompt" "$(payload "$d" s1 p2 "wait, stop" | hook prompt)" "5. a human prompt during a need asks for its classification"
assert_contains "Classify the user's last prompt" "$(stop "$d" s1 p2 | reason)" "5. the need does not advance past an unclassified prompt"
echo wip > "$d/wip.txt"
python3 "$CS" halt --repo "$d" --session s1 >/dev/null
assert_eq "blocked" "$(ledger "$d" "['needs']['$nid']['state']")" "5. halt blocks the need"
assert_eq "" "$(git -C "$d" status --porcelain)" "5. halt commits the uncommitted work locally"
assert_eq "" "$(stop "$d" s1 p2)" "5. a halted need is silent at Stop"
python3 "$CS" resume --repo "$d" --session s1 >/dev/null
assert_eq "active" "$(ledger "$d" "['needs']['$nid']['state']")" "5. resume re-arms it"

# 6. compaction or /clear keeps the need bound to the same Claude process
payload "$d" s2 "" "" "" compact | hook session >/dev/null
assert_eq "s2" "$(ledger "$d" "['needs']['$nid']['session']")" "6. a compaction in the same process re-binds the need"
assert_contains "driven by need $nid" "$(CLAUDE_PID=9999 payload "$d" s3 "" "" "" startup | CLAUDE_PID=9999 hook session)" "6. another session on the branch is told who drives it"

# 7. abandon keeps the branch held; release hands it back
python3 "$CS" abandon --repo "$d" --session s2 >/dev/null
assert_eq "abandoned" "$(ledger "$d" "['needs']['$nid']['state']")" "7. abandon keeps the need, and its branch held"
python3 "$CS" release --repo "$d" --session s2 >/dev/null
payload "$d" s2 p7 "ok" | hook prompt >/dev/null
assert_eq "{}" "$(ledger "$d" "['needs']")" "7. release takes it out of the ledger at the next prompt"

# 8. open refuses what it cannot drive, and a corrupt ledger is surfaced, never a traceback
d="$ROOT/r8"; new_repo "$d"; echo dirty > "$d/x.txt"
python3 "$CS" open --repo "$d" --session s1 --summary x --criterion y >/dev/null 2>&1; assert_eq 1 "$?" "8. open refuses a tree with changes the need did not produce"
rm "$d/x.txt"
env -u HARNESS_AUTO_ENGAGE python3 "$CS" open --repo "$d" --session s1 --summary x --criterion y >/dev/null 2>&1; assert_eq 1 "$?" "8. open refuses a repo outside the AUTO scope"
echo '{not json' > "$d/.git/conductor.json"
out=$(stop "$d")
assert_contains "systemMessage" "$out" "8. a corrupt ledger is surfaced at Stop"
assert_absent "Traceback" "$out" "8. never as a traceback"

# 9. a need starts from the base: work already on the current branch is never the need's
d="$ROOT/r9"; new_repo "$d"; git -C "$d" checkout -q -b feature; echo old > "$d/old.txt"; git -C "$d" add -A; git -C "$d" commit -qm "old work"
nid=$(open_need "$d")
assert_contains "Implement need $nid" "$(stop "$d" | reason)" "9. a need opened on a branch with commits still starts with no work of its own"

# 10. one need per worktree; a mismatch is bounded; another session on a driven branch is not nudged to open
python3 "$CS" open --repo "$d" --session s9b --summary other --criterion y >/dev/null 2>&1; assert_eq 1 "$?" "10. a second need in the same worktree is refused"
assert_eq "" "$(payload "$d" s9b q1 "do something else" | hook prompt)" "10. another session on a driven branch is not nudged to open a need"
git -C "$d" checkout -q main
for i in 1 2; do stop "$d" s1 m1 >/dev/null; done
assert_contains "is blocked: no progress" "$(stop "$d" s1 m1 | reason)" "10. a need left on another branch trips the stall breaker"

# 11. resume re-arms the wall clock too
d="$ROOT/r11"; new_repo "$d"; nid=$(open_need "$d")
python3 "$CS" halt --repo "$d" --session s1 >/dev/null
python3 -c 'import json,sys; p=sys.argv[1]+"/.git/conductor.json"; l=json.load(open(p)); n=l["needs"][sys.argv[2]]
n["created"]="2020-01-01T00:00:00+00:00"; n["clock"]="2020-01-01T00:00:00+00:00"; json.dump(l, open(p,"w"))' "$d" "$nid"
python3 "$CS" resume --repo "$d" --session s1 >/dev/null
assert_contains "Implement need $nid" "$(stop "$d" | reason)" "11. a need resumed after a long halt drives again"

# 12. a driven review in a subagent is waited on, like a shell step
d="$ROOT/r12"; new_repo "$d"; nid=$(open_need "$d"); echo w > "$d/w.txt"
gate=$(stop "$d" | reason | quoted); bash -c "$gate" >/dev/null 2>&1
assert_contains "need:$nid" "$(stop "$d" | reason)" "12. the review instruction names the need token for the subagent's description"
task="[{\"id\":\"a1\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"review need:$nid\"}]"
for i in 1 2 3; do out=$(stop "$d" s1 p1 "$task"); done
assert_eq "" "$out" "12. while the review subagent runs the conductor waits"
assert_eq "active" "$(ledger "$d" "['needs']['$nid']['state']")" "12. and the wait never trips the stall breaker"

# 13. the per-stage budget counts failures, not the instructions of a stage that keeps moving
for i in 1 2 3 4; do echo "v$i" > "$d/w.txt"; stop "$d" >/dev/null; gate=$(stop "$d" | reason | quoted); [ -n "$gate" ] && bash -c "$gate" >/dev/null 2>&1; stop "$d" >/dev/null; done
assert_eq "active" "$(ledger "$d" "['needs']['$nid']['state']")" "13. four review requests on four new heads never exhaust the review budget"

# 14. leaving the driven state takes effect at the next prompt, so no sibling speaks in the deciding turn
d="$ROOT/r14"; new_repo "$d"; nid=$(open_need "$d"); echo hi > "$d/hi.txt"
gate=$(stop "$d" | reason | quoted); bash -c "$gate" >/dev/null 2>&1; stop "$d" >/dev/null
python3 "$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py" record --repo "$d" --sha HEAD --score 95 >/dev/null
watch=$(stop "$d" | reason | quoted); bash -c "$watch" >/dev/null 2>&1
assert_contains "Need ready" "$(stop "$d" | reason)" "14. the need reaches ready"
assert_eq "True" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k
print(k.driven(sys.argv[2], "s1", "p1"))' "$REPO_ROOT/lib" "$d")" "14. its branch stays driven for the rest of that prompt"
( unset HARNESS_AUTO_ENGAGE; payload "$d" s2 q1 "hi" | hook prompt ) >/dev/null
assert_eq "False" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k
print(k.driven(sys.argv[2], "s2", "q1"))' "$REPO_ROOT/lib" "$d")" "14. but not for a session out of scope on that branch, which never purges the ledger"
python3 "$CS" resume --repo "$d" --session s1 --need "$nid" >/dev/null 2>&1; assert_eq 1 "$?" "14. a ready need is past resume"
payload "$d" s1 p9 "thanks" | hook prompt >/dev/null
assert_eq "{}" "$(ledger "$d" "['needs']")" "14. the next prompt hands the branch back"

# 15. the prompt a need opens with is the one the hook captured, never a transcription
d="$ROOT/r15"; new_repo "$d"
payload "$d" s1 p1 "fix the user's \"cart\" bug; don't touch prices" | hook prompt >/dev/null
nid=$(python3 "$CS" open --repo "$d" --session s1 --summary "fix cart" --criterion "cart ok" | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])')
assert_eq "fix the user's \"cart\" bug; don't touch prices" "$(ledger "$d" "['needs']['$nid']['prompt']")" "15. open stores the captured prompt verbatim"

# 16. a follow-up on a ready need re-opens it on its branch
d="$ROOT/r14"; nid=$(ledger "$d" "['history'][-1]['id']")
out=$(payload "$d" s1 p10 "in that PR, rename hi.txt to hello.txt" | hook prompt)
assert_contains "reopen --need $nid" "$(echo "$out" | sed 's/ --repo [^ ]*//g')" "16. a prompt on a ready need's branch offers to reopen that need"
python3 "$CS" reopen --repo "$d" --session s1 --need "$nid" >/dev/null
assert_eq "active" "$(ledger "$d" "['needs']['$nid']['state']")" "16. reopen drives the need again"
assert_eq "in that PR, rename hi.txt to hello.txt" "$(ledger "$d" "['needs']['$nid']['prompt']")" "16. with the follow-up as its prompt"
before=$(git -C "$d" rev-list --count HEAD); git -C "$d" mv hi.txt hello.txt
assert_contains "gate --need $nid" "$(stop "$d" s1 p10 | reason)" "16. the follow-up is committed on the need's branch and gated again"
assert_eq "$((before + 1))" "$(git -C "$d" rev-list --count HEAD)" "16. stacked on the ready need's work"

# 17. a need's work is measured against the base it was cut from, even when the local default is stale
d="$ROOT/r17"; new_repo "$d"; git -C "$d" checkout -q -b mate; echo mate > "$d/mate.txt"; git -C "$d" add -A
git -C "$d" commit -qm "a teammate's merged work"; git -C "$d" push -q origin mate:main; git -C "$d" checkout -q main; git -C "$d" branch -q -D mate
nid=$(open_need "$d")
assert_contains "Implement need $nid" "$(stop "$d" | reason)" "17. a teammate's commit on the remote default is never the need's work"

# 18. in a fork clone the need is pushed where a branch with no upstream goes, never to the parent
d="$ROOT/r18"; new_repo "$d"; git init -q --bare "$d-parent.git"; git -C "$d" remote add upstream "$d-parent.git"
git -C "$d" push -q upstream main; git -C "$d" branch -q -u upstream/main main
nid=$(open_need "$d")
git -C "$d" rev-parse --abbrev-ref "need/$nid@{u}" >/dev/null 2>&1; assert_eq 128 "$?" "18. the need's branch tracks nothing"
assert_eq "origin" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k; print(k.remote_name(sys.argv[2]))' "$REPO_ROOT/lib" "$d")" "18. so it ships to origin"
assert_eq "origin/main" "$(ledger "$d" "['needs']['$nid']['base']")" "18. from the base of the remote it ships to"

# 19. a need opened in a turn no human prompt started carries no human prompt
d="$ROOT/r19"; new_repo "$d"
payload "$d" s1 p1 "what does the cart do? don't change anything" | hook prompt >/dev/null
payload "$d" s1 p2 "<task-notification>done</task-notification>" | hook prompt >/dev/null
nid=$(python3 "$CS" open --repo "$d" --session s1 --summary "x" --criterion y | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])')
assert_eq "" "$(ledger "$d" "['needs']['$nid']['prompt']")" "19. an earlier prompt is never presented as this need's"

# 20. three failing reviews block the need
d="$ROOT/r20"; new_repo "$d"; nid=$(open_need "$d")
for i in 1 2 3; do echo "v$i" > "$d/w.txt"; gate=$(stop "$d" | reason | quoted); bash -c "$gate" >/dev/null 2>&1
  python3 "$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py" record --repo "$d" --sha HEAD --score 10 >/dev/null; out=$(stop "$d" | reason); done
assert_contains "used its 3 attempts" "$out" "20. the third failing review blocks the need"

# 21. a need needs at least one criterion
d="$ROOT/r21"; new_repo "$d"
python3 "$CS" open --repo "$d" --session s1 --summary x >/dev/null 2>&1; assert_eq 1 "$?" "21. open without a criterion is refused"
assert_eq "main" "$(git -C "$d" branch --show-current)" "21. and creates no branch"

# 22. the contract comes first: each criterion's probe, red before the work, green at ready, in the report
d="$ROOT/r22"; new_repo "$d"
out=$(python3 "$CS" open --repo "$d" --session s1 --summary "add a greeting" --criterion "hello.txt says hello")
nid=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])')
assert_contains "--criterion c1" "$out" "22. open's reply names the probe to record first"
assert_contains "record the probe" "$(stop "$d" | reason)" "22. the first Stop asks for the probe, not the work"
python3 "$POF" record --repo "$d" --need "$nid" --criterion c1 --cmd "test -f hello.txt" >/dev/null
out=$(stop "$d" | reason)
assert_contains "Implement need $nid" "$out" "22. contract recorded → implement"
assert_contains "c1: hello.txt says hello" "$out" "22. the implement step lists the criteria by id"
echo hello > "$d/hello.txt"
gate=$(stop "$d" | reason | quoted); bash -c "$gate" >/dev/null 2>&1
check=$(stop "$d" | reason | quoted)
assert_contains "check --need $nid" "$check" "22. proving runs the criterion's probe"
bash -c "$check" >/dev/null 2>&1
python3 "$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py" record --repo "$d" --sha HEAD --score 95 >/dev/null
watch=$(stop "$d" | reason | quoted); bash -c "$watch" >/dev/null 2>&1
tx="$ROOT/projects/p/s1.jsonl"; mkdir -p "$ROOT/projects/p/s1/subagents"
python3 - "$tx" "$ROOT/projects/p/s1/subagents/agent-a.jsonl" <<'PY'
import json, sys
from datetime import datetime, timezone
ts = datetime.now(timezone.utc).isoformat()[:23] + "Z"
def entry(mid, model, i, o, when=ts):
    return json.dumps({"type": "assistant", "timestamp": when, "message": {"id": mid, "model": model,
        "usage": {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
open(sys.argv[1], "w").write("\n".join([entry("m1", "m-main", 100, 10), entry("m1", "m-main", 100, 10),
                                         entry("m0", "m-main", 9999, 9999, "2000-01-01T00:00:00.000Z")]) + "\n")
open(sys.argv[2], "w").write(entry("a1", "m-sub", 50, 5) + "\n")
PY
out=$(payload "$d" s1 p1 "" "" "" "$tx" | hook stop | reason)
assert_contains "Need ready" "$out" "22. the need reaches ready"
assert_contains 'c1 (hello.txt says hello): `test -f hello.txt` red (exit 1)' "$out" "22. the report shows each criterion's red run"
assert_contains "green at" "$out" "22. and its green run"
assert_contains "m-main in 100 out 10" "$out" "22. tokens per model, each message once, none from before the need"
assert_contains "m-sub in 50 out 5" "$out" "22. the subagents' tokens too"
assert_contains "driven " "$out" "22. and the driven time"

# 23. an amended criterion sends the need back to contracting
d="$ROOT/r23"; new_repo "$d"; nid=$(open_need "$d")
python3 "$CS" amend --repo "$d" --session s1 --criterion "greets in French" >/dev/null
assert_contains "--criterion c2" "$(stop "$d" | reason)" "23. an amended criterion sends the need back to contracting"
python3 "$CS" amend --repo "$d" --session s1 >/dev/null 2>&1; assert_eq 1 "$?" "23. an amendment without a criterion is refused"

# 24. a need that falls off the history has its probes forgotten, through their owner
d="$ROOT/r24"; new_repo "$d"
python3 "$POF" waive --repo "$d" --need h1 --criterion c1 --reason old >/dev/null
python3 - "$d" <<'PY'
import json, sys
hist = [{"id": f"h{i}", "branch": f"need/h{i}", "state": "ready"} for i in range(1, 21)]
json.dump({"v": 1, "needs": {"n21": {"id": "n21", "branch": "need/n21", "state": "ready", "closed_prompt": "old"}},
           "history": hist}, open(sys.argv[1] + "/.git/conductor.json", "w"))
PY
payload "$d" s1 p24 "hi" | hook prompt >/dev/null
assert_eq "{}" "$(python3 "$POF" status --repo "$d" --need h1)" "24. the probes of a need gone from the history are forgotten"
assert_eq "h2" "$(ledger "$d" "['history'][0]['id']")" "24. the history keeps the last 20"

# 25. the report reads each probe's evidence whole, however verbose the probe
d="$ROOT/r25"; new_repo "$d"
nid=$(python3 "$CS" open --repo "$d" --session s1 --summary "add a greeting" --criterion "hello.txt says hello" | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])')
python3 "$POF" record --repo "$d" --need "$nid" --criterion c1 \
  --cmd "python3 -c \"import os,sys; sys.stderr.write('x' * 3000); sys.exit(0 if os.path.exists('hello.txt') else 1)\"" >/dev/null 2>&1
stop "$d" >/dev/null; echo hello > "$d/hello.txt"
gate=$(stop "$d" | reason | quoted); bash -c "$gate" >/dev/null 2>&1
check=$(stop "$d" | reason | quoted); bash -c "$check" >/dev/null 2>&1
python3 "$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py" record --repo "$d" --sha HEAD --score 95 >/dev/null
watch=$(stop "$d" | reason | quoted); bash -c "$watch" >/dev/null 2>&1
out=$(stop "$d" | reason)
assert_contains "red (exit 1)" "$out" "25. a verbose probe's red run is in the report"
assert_contains "green at" "$out" "25. and its green run"

# 26. driven time: every active interval counts once, blocked time never
d="$ROOT/r26"; new_repo "$d"; nid=$(open_need "$d")
backdate(){ python3 -c 'import json,sys; from datetime import datetime,timedelta,timezone
p=sys.argv[1]+"/.git/conductor.json"; l=json.load(open(p)); n=l["needs"][sys.argv[2]]
n["active_since"]=(datetime.now(timezone.utc)-timedelta(hours=float(sys.argv[3]))).isoformat(timespec="seconds"); json.dump(l, open(p,"w"))' "$d" "$nid" "$1"; }
driven(){ python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import json, conductor
print(int(conductor.driven_seconds(json.load(open(sys.argv[2]+"/.git/conductor.json"))["needs"][sys.argv[3]]) // 60))' "$(dirname "$CS")" "$d" "$nid"; }
backdate 2; python3 "$CS" halt --repo "$d" --session s1 >/dev/null
assert_eq 120 "$(driven)" "26. halt closes the active interval"
python3 "$CS" resume --repo "$d" --session s1 >/dev/null; backdate 1
python3 "$CS" resume --repo "$d" --session s1 >/dev/null
assert_eq 180 "$(driven)" "26. resuming a need already active keeps its time"
backdate 0.5; python3 "$CS" halt --repo "$d" --session s1 >/dev/null
assert_eq 210 "$(driven)" "26. every active interval adds up"

# 27. tokens: only while the need was driven, each message once across its sessions' files
python3 - "$ROOT/tok" "$(dirname "$CS")" <<'PY'
import json, os, sys
root = sys.argv[1]
os.makedirs(f"{root}/p/s1/subagents/workflows/wf_1", exist_ok=True)
def entry(mid, ts, n, model="m"):
    return json.dumps({"timestamp": ts, "message": {"id": mid, "model": model, "usage": {"input_tokens": n, "output_tokens": 0}}})
open(f"{root}/p/s1.jsonl", "w").write("\n".join([entry("a", "2026-01-01T10:30:00.000Z", 10), entry("b", "2026-01-01T12:30:00.000Z", 5000),
    entry("c", "2026-01-01T14:30:00.000Z", 100), entry("s", "2026-01-01T10:31:00.000Z", 7, "<synthetic>")]) + "\n")
open(f"{root}/p/s2.jsonl", "w").write(entry("a", "2026-01-01T10:30:00.000Z", 10) + "\n")
open(f"{root}/p/s1/subagents/workflows/wf_1/agent-x.jsonl", "w").write(entry("w", "2026-01-01T10:40:00.000Z", 1) + "\n")
PY
tok=$(python3 - "$ROOT/tok" "$(dirname "$CS")" <<'PY'
import sys; sys.path.insert(0, sys.argv[2]); import conductor
windows = [["2026-01-01T10:00:00+00:00", "2026-01-01T11:00:00+00:00"], ["2026-01-01T14:00:00+00:00", "2026-01-01T15:00:00+00:00"]]
print(conductor.usage(sys.argv[1] + "/p/s1.jsonl", ["s1", "s2"], windows))
PY
)
assert_eq "{'m': [111, 0, 0, 0]}" "$tok" "27. tokens inside the driven windows only, a copied message once, workflow agents included, no synthetic line"

# 28. a test-first probe file committed alone is not the work: the first red proving asks to implement
d="$ROOT/r28"; new_repo "$d"
nid=$(python3 "$CS" open --repo "$d" --session s1 --summary "add a greeting" --criterion "hello.txt says hello" | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])')
mkdir -p "$d/tests"; echo 'test -f hello.txt' > "$d/tests/hello.sh"
python3 "$POF" record --repo "$d" --need "$nid" --criterion c1 --file tests/hello.sh --cmd "bash tests/hello.sh" >/dev/null
gate=$(stop "$d" | reason | quoted); bash -c "$gate" >/dev/null 2>&1
check=$(stop "$d" | reason | quoted); bash -c "$check" >/dev/null 2>&1
out=$(stop "$d" | reason)
assert_contains "Implement need $nid" "$out" "28. the probe's own file committed alone → the need is asked for its work"
assert_contains "c1: hello.txt says hello" "$out" "28. with its criteria"
check=$(stop "$d" | reason | quoted); bash -c "$check" >/dev/null 2>&1
assert_contains "still fails" "$(stop "$d" | reason)" "28. once asked, a red probe is a fix step"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
