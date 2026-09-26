#!/usr/bin/env bash
# One voice while driven: when delivery-conductor holds a branch for a need, every sibling stands down
# on every channel it owns (Stop, UserPromptSubmit nudge, PreToolUse reason), and re-engages the moment
# the conductor is no longer running. Real hooks at the real wire format, throwaway repos, stubbed gh;
# the conductor is played by a stand-in that writes exactly what the conductor writes.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P="$REPO_ROOT/plugins"
LIB="$REPO_ROOT/lib"
ROOT="$(mktemp -d)"; GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
unset HARNESS_AUTO_ENGAGE CLAUDE_CODE_SESSION_ID

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "pr view") echo '{"state":"OPEN"}';;
  "pr checks") echo '[{"bucket":"pending"}]';;
  "pr create") echo "https://example.test/pr/1";;
  api*check-runs*) echo '{"check_runs":[{"status":"in_progress","conclusion":null}]}';;
esac
exit 0
EOF
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir: a repo with a GitHub-looking remote, on the need's branch
  local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" config remote.origin.pushurl "$d.git"
  git -C "$d" config remote.origin.url "https://github.com/test/repo.git"
  git -C "$d" push -q -u origin main 2>/dev/null
  git -C "$d" checkout -q -b need/n1
  printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
}
hold(){ printf '{"v":1,"needs":{"n1":{"branch":"need/n1"}}}' > "$1/.git/conductor.json"; }
conductor_at(){ # $1=repo $2=session $3=prompt_id: the conductor's hooks ran in that session for that prompt
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k
k.stamp_live(sys.argv[2], sys.argv[3], True)' "$LIB" "$2" "$3"; }
transcript(){ # $1=file, then the prompt ids of the turns so far, oldest first
  local f="$1"; shift; : > "$f"
  for p in "$@"; do printf '{"type":"user","promptId":"%s","message":{"content":"x"}}\n' "$p" >> "$f"; done; }
payload(){ printf '{"session_id":"%s","cwd":"%s","prompt_id":"%s","prompt":"%s","transcript_path":"%s","stop_hook_active":false}' \
  "$1" "$2" "$3" "${4:-}" "${5:-}"; }
hook(){ # $1=plugin $2=hook file, stdin=payload
  CLAUDE_PLUGIN_ROOT="$P/$1" python3 "$P/$1/hooks/$2"; }

# every sibling primed to speak at its next Stop on need/n1
prime(){ # $1=repo $2=session
  echo work > "$1/work.txt"
  python3 "$P/ship-when-done/skills/ship-when-done/scripts/ship.py" mark-done --repo "$1" --summary "the need" >/dev/null
  printf '{"v":1,"sessions":{"%s":{"branches":{"need/n1":{"engaged":true}}}}}' "$2" > "$1/.git/mr-watchdog-session.json"
  python3 "$P/proof-of-fix/skills/proof-of-fix/scripts/repro.py" record --repo "$1" --session "$2" --cmd false >/dev/null 2>&1
}
stops(){ # $1=repo $2=session $3=prompt_id: every sibling's Stop, outputs concatenated
  for h in ship-when-done mr-watchdog proof-of-fix; do payload "$2" "$1" "$3" | hook "$h" stop-hook.py; done; }
commits(){ git -C "$1" rev-list --count HEAD; }

echo "driven one-voice tests"

# --- D1. control: no need in the ledger, every sibling speaks ----------------------------------------
d="$ROOT/d1"; new_repo "$d"; prime "$d" d1
out=$(stops "$d" d1 p1)
assert_contains 'run --repo' "$out" "D1. undriven: mr-watchdog asks for the watcher"
assert_contains 'STILL fails' "$out" "D1. undriven: proof-of-fix hands back the red repro"
assert_eq 2 "$(commits "$d")" "D1. undriven: ship-when-done commits the work"

# --- D2. a need holds the branch and the conductor runs in this session: siblings silent -------------
d="$ROOT/d2"; new_repo "$d"; prime "$d" d2; hold "$d"; conductor_at "$d" d2 p1
before=$(grep -c . "$GH_LOG")
out=$(stops "$d" d2 p1)
assert_eq "" "$out" "D2. driven: no sibling speaks at the Stop"
assert_eq 1 "$(commits "$d")" "D2. driven: ship-when-done commits nothing"
git -C "$d.git" rev-parse --verify -q need/n1 >/dev/null && ko "D2. driven: nothing pushed" || ok "D2. driven: nothing pushed"
assert_eq "$before" "$(grep -c . "$GH_LOG")" "D2. driven: no forge call at all"

# --- D3. the ledger outlives a disabled conductor: without the conductor running, it is inert --------
d="$ROOT/d3"; new_repo "$d"; prime "$d" d3; hold "$d"
out=$(stops "$d" d3 p1)
assert_contains 'STILL fails' "$out" "D3. ledger but no running conductor: siblings speak"

# --- D4. a corrupt ledger under a running conductor holds the branch (fail closed) -------------------
d="$ROOT/d4"; new_repo "$d"; prime "$d" d4; conductor_at "$d" d4 p1
printf '{not json' > "$d/.git/conductor.json"
assert_eq "" "$(stops "$d" d4 p1)" "D4. corrupt ledger, running conductor: siblings silent"

# --- D4b. a ledger whose need entry is not an object is corrupt too: held, never a traceback that
# silences the Stop with no evidence or lets a push through the pre-push gate with no deny at all
d="$ROOT/d4b"; new_repo "$d"; prime "$d" d4b; conductor_at "$d" d4b p1
printf '{"v":1,"needs":{"n1":"need/n1"}}' > "$d/.git/conductor.json"
assert_eq "" "$(stops "$d" d4b p1 2>&1)" "D4b. non-object need entry, running conductor: siblings silent, no traceback"
git -C "$d" add -A; git -C "$d" commit -qm w
out=$(printf '{"session_id":"d4b","cwd":"%s","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"git push -u origin need/n1"}}' "$d" \
  | hook merge-review prepush-hook.py)
assert_contains 'delivery-conductor' "$out" "D4b. and a push by hand is still denied, pointing back to the conductor"

# --- D5. only the held branch is driven ----------------------------------------------------------------
d="$ROOT/d5"; new_repo "$d"; hold "$d"; conductor_at "$d" d5 p1
git -C "$d" checkout -q -b other; prime "$d" d5
assert_contains 'STILL fails' "$(stops "$d" d5 p1)" "D5. a branch no need holds: siblings speak"

# --- D6. proof-of-fix's nudge gives way to the conductor's contract step ------------------------------
d="$ROOT/d6"; new_repo "$d"
out=$(payload d6 "$d" p1 "fix the crash" | hook proof-of-fix prompt-hook.py)
assert_contains 'additionalContext' "$out" "D6. no conductor: the bug prompt is nudged"
d="$ROOT/d6b"; new_repo "$d"; conductor_at "$d" d6 p1
out=$(payload d6 "$d" p1 "fix the crash" | hook proof-of-fix prompt-hook.py)
assert_eq "" "$out" "D6. conductor running in scope: proof-of-fix stays silent"

# --- D7. a push by hand on a driven branch is sent back to the conductor ------------------------------
d="$ROOT/d7"; new_repo "$d"; hold "$d"; conductor_at "$d" d7 p1
python3 "$P/ship-when-done/skills/ship-when-done/scripts/ship.py" mark-done --repo "$d" --summary x >/dev/null
echo w > "$d/w.txt"; git -C "$d" add -A; git -C "$d" commit -qm w
out=$(printf '{"session_id":"d7","cwd":"%s","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"git push -u origin need/n1"}}' "$d" \
  | hook merge-review prepush-hook.py)
assert_contains 'delivery-conductor' "$out" "D7. driven push by hand: the deny points back to the conductor"
assert_absent 'merge-readiness review' "$out" "D7. and carries no second instruction"

# --- Q1. liveness, not a stamp written once: /reload-plugins disables the conductor inside the same
# session (same id, same CLAUDE_PID); from the next prompt on nothing refreshes it, the siblings re-engage
d="$ROOT/q1"; new_repo "$d"; prime "$d" q1; hold "$d"; conductor_at "$d" q1 p1
assert_eq "" "$(stops "$d" q1 p1)" "Q1. conductor ran for this prompt: siblings silent at its Stop"
out=$(stops "$d" q1 p2)
assert_contains 'STILL fails' "$out" "Q1. next prompt, conductor no longer running: siblings re-engage at the Stop"
assert_contains 'run --repo' "$out" "Q1. every sibling re-engages, not only one"
tp="$ROOT/q1.jsonl"; dn="$ROOT/q1n"; new_repo "$dn"; conductor_at "$dn" q1 p1
transcript "$tp" p1 p2
out=$(payload q1 "$dn" p2 "fix the crash" "$tp" | hook proof-of-fix prompt-hook.py)
assert_eq "" "$out" "Q1. prompt right after the conductor's last run: its stamp still counts at UserPromptSubmit"
transcript "$tp" p1 p2 p3
out=$(payload q1 "$dn" p3 "fix the crash" "$tp" | hook proof-of-fix prompt-hook.py)
assert_contains 'additionalContext' "$out" "Q1. one prompt later: proof-of-fix nudges again"
python3 -c 'import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"content": "x" * 1200000}}) + "\n")
    f.write(json.dumps({"type": "user", "promptId": "p4", "message": {"content": "x"}}) + "\n")' "$tp"
dm="$ROOT/q1m"; new_repo "$dm"; conductor_at "$dm" q1 p3
out=$(payload q1 "$dm" p4 "fix the crash" "$tp" | hook proof-of-fix prompt-hook.py)
assert_eq "" "$out" "Q1. previous prompt found beyond a 1 MiB tail with no other promptId in it"

# --- Q2. a session launched outside the conductor's scope ($HOME, explicit mode) on a driven branch:
# the repo-wide mark-done marker the conductor wrote would let its ship-when-done commit, push and open
# the need's PR. Its conductor runs, silently, and at this prompt the session had no repo at all.
d="$ROOT/q2"; new_repo "$d"; hold "$d"; home="$ROOT/home"; mkdir -p "$home"
python3 "$P/ship-when-done/skills/ship-when-done/scripts/ship.py" mark-done --repo "$d" --summary "the need" >/dev/null
echo work > "$d/work.txt"
tp="$ROOT/q2.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$d/work.txt" > "$tp"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k
k.stamp_live(sys.argv[2], sys.argv[3], False)' "$LIB" s2 p1 2>/dev/null
out=$(payload s2 "$home" p1 "" "$tp" | CLAUDE_PROJECT_DIR="$home" hook ship-when-done stop-hook.py)
assert_eq "" "$out" "Q2. out-of-scope session on the driven branch: ship-when-done stands down"
assert_eq 1 "$(commits "$d")" "Q2. nothing committed"
git -C "$d.git" rev-parse --verify -q need/n1 >/dev/null && ko "Q2. nothing pushed" || ok "Q2. nothing pushed"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
