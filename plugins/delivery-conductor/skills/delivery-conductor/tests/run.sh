#!/usr/bin/env bash
# delivery-conductor: a need driven from open to ready through the real sibling stage CLIs and the real
# hooks at the real wire format. Throwaway repos with a bare remote, a stubbed gh, a green gate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$(cd "$HERE/../../.." && pwd)"
CS="$PL/skills/delivery-conductor/scripts/conductor.py"
REPO_ROOT="$(cd "$PL/../.." && pwd)"
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
payload(){ # $1=repo $2=session $3=prompt_id [$4=prompt] [$5=background_tasks] [$6=source]
  python3 -c 'import json,sys; a=sys.argv[1:]
print(json.dumps({"session_id": a[1], "cwd": a[0], "prompt_id": a[2], "prompt": a[3], "transcript_path": "",
  "stop_hook_active": False, "background_tasks": json.loads(a[4] or "[]"), "source": a[5]}))' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}"; }
stop(){ payload "$1" "${2:-s1}" "${3:-p1}" "" "${4:-}" | hook stop; }
reason(){ python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t).get("reason","") if t else "")'; }
quoted(){ python3 -c 'import re,sys; m=re.search(r"`([^`]+)`", sys.stdin.read()); print(m.group(1) if m else "")'; }
ledger(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/.git/conductor.json"))'"$2"')' "$1"; }
open_need(){ python3 "$CS" open --repo "$1" --session "${2:-s1}" --summary "add a greeting" --criterion "hello.txt says hello" \
  --prompt "add a greeting" | python3 -c 'import json,sys; print(json.load(sys.stdin)["need"])'; }

echo "delivery-conductor"

# 1. a prompt with no need in flight: the contract nudge, and the liveness stamp the siblings rely on
d="$ROOT/r1"; new_repo "$d"
assert_contains "open a need" "$(payload "$d" s1 p0 "add a greeting" | hook prompt)" "1. a prompt in scope suggests opening a need"
assert_contains '"p0"' "$(cat "$ROOT/live/s1.json")" "1. the prompt hook stamps the conductor live for this prompt"
assert_eq "" "$(payload "$d" s1 p0 "<task-notification>x</task-notification>" | hook prompt)" "1. a machine envelope is never a need"

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
assert_contains "foreground" "$out" "3. and it runs in the foreground under drive"
python3 "$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py" record --repo "$d" --sha HEAD --score 95 >/dev/null
watch=$(stop "$d" | reason | quoted)
assert_contains "run --need $nid" "$watch" "3. reviewed → shipped by script steps, then the CI watcher as a background step"
assert_eq "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d.git" rev-parse "need/$nid")" "3. the branch is pushed at HEAD"
bash -c "$watch" >/dev/null 2>&1
out=$(stop "$d" | reason)
assert_contains "Need ready" "$out" "3. CI green → marked ready and reported"
assert_contains "pr ready" "$(cat "$ROOT/gh.log")" "3. the draft PR is marked ready"
assert_eq "{}" "$(ledger "$d" "['needs']")" "3. a ready need leaves the ledger: its branch is not driven any more"
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
assert_eq "{}" "$(ledger "$d" "['needs']")" "7. release takes it out of the ledger"

# 8. open refuses what it cannot drive, and a corrupt ledger is surfaced, never a traceback
d="$ROOT/r8"; new_repo "$d"; echo dirty > "$d/x.txt"
python3 "$CS" open --repo "$d" --session s1 --summary x >/dev/null 2>&1; assert_eq 1 "$?" "8. open refuses a tree with changes the need did not produce"
rm "$d/x.txt"
env -u HARNESS_AUTO_ENGAGE python3 "$CS" open --repo "$d" --session s1 --summary x >/dev/null 2>&1; assert_eq 1 "$?" "8. open refuses a repo outside the AUTO scope"
echo '{not json' > "$d/.git/conductor.json"
out=$(stop "$d")
assert_contains "systemMessage" "$out" "8. a corrupt ledger is surfaced at Stop"
assert_absent "Traceback" "$out" "8. never as a traceback"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
