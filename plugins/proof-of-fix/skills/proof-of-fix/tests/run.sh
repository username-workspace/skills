#!/usr/bin/env bash
# proof-of-fix test suite — the evidence-first loop on real throwaway git repos, driven through the
# real hooks: record refuses a passing probe, check proves with the same probe, the prompt hook
# nudges once per session on bug-shaped prompts, and the Stop hook re-runs an open repro itself
# (auto-prove on green, bounded block on red).
set -u
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
REPRO="$PLUGIN/skills/proof-of-fix/scripts/repro.py"
PROMPT_HOOK="$PLUGIN/hooks/prompt-hook.py"
STOP_HOOK="$PLUGIN/hooks/stop-hook.py"
ROOT="$(mktemp -d)"
unset CLAUDE_CODE_SESSION_ID

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"

mkrepo(){ local d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init; }
prompt_payload(){ printf '{"cwd":"%s","session_id":"%s","prompt":"%s"}' "$1" "$2" "$3"; }
stop_payload(){ printf '{"cwd":"%s","session_id":"%s"}' "$1" "$2"; }

echo "proof-of-fix tests"

# --- 1. record refuses a probe that passes (a repro must FAIL) -------------------------------------
d="$ROOT/t1"; mkrepo "$d"
out=$(python3 "$REPRO" record --repo "$d" --cmd "true" 2>&1); rc=$?
assert_eq 1 "$rc" "1. passing probe → record refused (exit 1)"
assert_contains 'does not reproduce' "$out" "1. refusal says why"
[ -f "$d/.git/proof-of-fix.json" ] && ko "1. no state written on refusal" || ok "1. no state written on refusal"

# --- 2. record accepts a failing probe; check fails until fixed, passes after ----------------------
out=$(python3 "$REPRO" record --repo "$d" --cmd "test -f fixed.txt" 2>&1); rc=$?
assert_eq 0 "$rc" "2. failing probe → recorded"
assert_contains 'failing repro recorded' "$out" "2. record confirms"
out=$(python3 "$REPRO" check --repo "$d" 2>&1); rc=$?
assert_eq 1 "$rc" "2. unfixed → check fails"
assert_contains 'still failing' "$out" "2. check says still failing"
touch "$d/fixed.txt"
out=$(python3 "$REPRO" check --repo "$d" 2>&1); rc=$?
assert_eq 0 "$rc" "2. fixed → check passes"
assert_contains 'fix proven' "$out" "2. check proves the fix"
assert_contains '"status": "proven"' "$(python3 "$REPRO" status --repo "$d")" "2. status is proven"

# --- 3. prompt hook: bug-shaped prompt nudges once per session, silent otherwise -------------------
d3="$ROOT/t3"; mkrepo "$d3"
out=$(prompt_payload "$d3" s1 "fix the login bug, it crashes on empty email" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "3. bug prompt → protocol injected"
assert_contains 'record --repo' "$out" "3. the injected protocol carries the record command"
out=$(prompt_payload "$d3" s1 "still broken, please fix it again" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "3. same session → no second nudge"
out=$(prompt_payload "$d3" s2 "corrige la régression sur le panier" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "3. new session, french bug prompt → nudges again"
d3b="$ROOT/t3b"; mkrepo "$d3b"
out=$(prompt_payload "$d3b" s1 "add a dark-mode toggle to the settings page" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "3. feature prompt → silent"
out=$(prompt_payload "$ROOT/nogit" s1 "fix the bug" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "3. no git repo → silent"

# --- 4. stop hook: open repro re-run by the hook — block on red, auto-prove on green ----------------
d4="$ROOT/t4"; mkrepo "$d4"
python3 "$REPRO" record --repo "$d4" --session s1 --cmd "test -f done.txt" >/dev/null 2>&1
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains '"decision": "block"' "$out" "4. open repro still red → Stop blocks"
assert_contains 'check --repo' "$out" "4. the block carries the check command"
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "4. same work-state → no re-block (no Stop loop)"
echo edit > "$d4/work.txt"
touch "$d4/done.txt"
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains 'systemMessage' "$out" "4. work-state changed, probe green → auto-proven"
assert_contains 'fix proven' "$out" "4. the auto-proof is announced"
assert_contains '"status": "proven"' "$(python3 "$REPRO" status --repo "$d4" --session s1)" "4. state flipped to proven"
out=$(stop_payload "$d4" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "4. proven repro → Stop silent"

# --- 5. nag cap: an unconverging repro stops blocking after MAX_NAGS attempts -----------------------
d5="$ROOT/t5"; mkrepo "$d5"
python3 "$REPRO" record --repo "$d5" --session s1 --cmd "false" >/dev/null 2>&1
blocks=0
for i in 1 2 3 4 5 6 7; do
  echo "edit $i" > "$d5/w$i.txt"
  out=$(stop_payload "$d5" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
  case "$out" in *'"decision": "block"'*) blocks=$((blocks+1));; esac
done
assert_eq 5 "$blocks" "5. blocks capped at 5 even across changing work-states"

# --- 5b. a content-only re-edit of an already-dirty file re-triggers the Stop probe -----------------
d5b="$ROOT/t5b"; mkrepo "$d5b"
echo v1 > "$d5b/app.txt"; git -C "$d5b" add -A; git -C "$d5b" commit -qm app
python3 "$REPRO" record --repo "$d5b" --session s1 --cmd "grep -q fixed app.txt" >/dev/null 2>&1
echo "v2 still broken" > "$d5b/app.txt"
out=$(stop_payload "$d5b" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains '"decision": "block"' "$out" "5b. dirty file, probe red → block"
echo "v3 fixed" > "$d5b/app.txt"
out=$(stop_payload "$d5b" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains 'fix proven' "$out" "5b. same file re-edited (M stays M) → probe re-run, auto-proven"

# --- 6. opt-out, clear, root anchoring --------------------------------------------------------------
d6="$ROOT/t6"; mkrepo "$d6"
printf '{"enabled":false}' > "$d6/.proof-of-fix.json"
out=$(prompt_payload "$d6" s1 "fix the bug" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "6. enabled:false → prompt hook silent"
rm "$d6/.proof-of-fix.json"
python3 "$REPRO" record --repo "$d6" --session s1 --cmd "false" >/dev/null 2>&1
printf '{"enabled":false}' > "$d6/.proof-of-fix.json"
out=$(stop_payload "$d6" s1 | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "6. enabled:false → stop hook silent"
python3 "$REPRO" clear --repo "$d6" --session s1 >/dev/null
assert_eq "{}" "$(python3 "$REPRO" status --repo "$d6" --session s1)" "6. clear removes the session's repro"
d7="$ROOT/t7"; mkrepo "$d7"; mkdir -p "$d7/src/deep"
python3 "$REPRO" record --repo "$d7/src/deep" --cmd "false" >/dev/null 2>&1
[ -f "$d7/.git/proof-of-fix.json" ] && ok "6. root-anchor: record from subdir → state at repo root" || ko "6. root-anchor subdir"

# --- 7. check without a recorded repro --------------------------------------------------------------
d8="$ROOT/t8"; mkrepo "$d8"
out=$(python3 "$REPRO" check --repo "$d8" 2>&1); rc=$?
assert_eq 1 "$rc" "7. check without record → fails"
assert_contains 'no recorded repro' "$out" "7. and says why"

# --- 8. concurrent sessions in one checkout: each owns its nudge and its repro ----------------------
d9="$ROOT/t9"; mkrepo "$d9"
out=$(prompt_payload "$d9" A "fix the checkout crash" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "8. session A nudged"
out=$(prompt_payload "$d9" B "fix the login bug" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "8. concurrent session B nudged"
out=$(prompt_payload "$d9" A "still failing, fix it" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "8. B's nudge does not re-arm A's"
CLAUDE_CODE_SESSION_ID=A python3 "$REPRO" record --repo "$d9" --cmd "test -f a-fixed.txt" >/dev/null 2>&1
out=$(stop_payload "$d9" B | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_eq "" "$out" "8. B's Stop neither runs nor blocks on A's repro"
CLAUDE_CODE_SESSION_ID=B python3 "$REPRO" record --repo "$d9" --cmd "test -f b-fixed.txt" >/dev/null 2>&1
out=$(stop_payload "$d9" A | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$STOP_HOOK")
assert_contains 'a-fixed.txt' "$out" "8. A's repro survives B's record — A's Stop re-runs A's probe"
touch "$d9/a-fixed.txt"
out=$(CLAUDE_CODE_SESSION_ID=A python3 "$REPRO" check --repo "$d9" 2>&1); rc=$?
assert_eq 0 "$rc" "8. A's check proves A's fix"
out=$(CLAUDE_CODE_SESSION_ID=B python3 "$REPRO" check --repo "$d9" 2>&1); rc=$?
assert_eq 1 "$rc" "8. B's repro is still open — A's fix did not close it"

# --- 9. harness envelopes (task notifications, agent hand-backs) are not the user asking for a fix --
d10="$ROOT/t10"; mkrepo "$d10"
json_prompt(){ python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"session_id":sys.argv[2],"prompt":sys.argv[3]}))' "$@"; }
out=$(json_prompt "$d10" s1 $'<task-notification>\n<task-id>b1</task-id>\n<status>failed</status>\n<summary>tests failing, 2 bugs fixed</summary>\n</task-notification>' | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "9. task notification → silent"
out=$(json_prompt "$d10" s1 $'<agent-message from="a1">\n[Subagent hand-back] fixed the regression, one test still fails\n</agent-message>' | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "9. subagent hand-back → silent"
out=$(json_prompt "$d10" s1 $'Another Claude session sent a message:\n<cross-session-message from="uds:/tmp/x.sock">\nthe fix is pushed, CI failed once\n</cross-session-message>' | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_eq "" "$out" "9. cross-session message → silent"
out=$(prompt_payload "$d10" s1 "the export crashes, fix it" | CLAUDE_PLUGIN_ROOT="$PLUGIN" python3 "$PROMPT_HOOK")
assert_contains 'additionalContext' "$out" "9. the session's one nudge is still there for the human bug report"

# --- 10. a terminal without a session never gets a false "cleared": it is told whose repro is open ---
d11="$ROOT/t11"; mkrepo "$d11"
python3 "$REPRO" record --repo "$d11" --session X --cmd "false" >/dev/null 2>&1
out=$(python3 "$REPRO" clear --repo "$d11" 2>&1); rc=$?
assert_eq 1 "$rc" "10. clear with no repro for this session → exit 1"
assert_contains "X" "$out" "10. clear names the session that holds the open repro"
out=$(python3 "$REPRO" status --repo "$d11" 2>&1)
assert_contains "X" "$out" "10. status names the session that holds the open repro"
out=$(python3 "$REPRO" clear --repo "$d11" --session X 2>&1); rc=$?
assert_eq 0 "$rc" "10. clear --session X → clears X's repro"
assert_eq "{}" "$(python3 "$REPRO" status --repo "$d11" --session X 2>/dev/null)" "10. X's repro is gone"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
