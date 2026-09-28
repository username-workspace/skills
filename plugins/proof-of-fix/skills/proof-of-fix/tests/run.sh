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

# --- 11. the stage protocol: a need's proving stage, bound to the work state it was checked on -------
stage(){ python3 "$REPRO" stage --repo "$1" --need N1 --sessions "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin)
print(d["v"], d["stage"], d["state"], d["next"]["kind"], " ".join(d["next"].get("run", [])[2:4]))'; }
d12="$ROOT/t12"; mkrepo "$d12"
assert_eq "1 proving done none " "$(stage "$d12" A)" "11. no repro recorded by the need's sessions → done"
python3 "$REPRO" stage --repo "$d12" --need N1 >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "11. a proving stage asked without the need's sessions is refused, never a silent done"
out=$(python3 "$REPRO" record --repo "$d12" --session A --need N1 --cmd "test -f fixed.txt" 2>&1)
assert_absent 'fix the root cause' "$out" "11. record under a need prints a neutral line, no instruction"
assert_contains '"need": "N1"' "$(python3 "$REPRO" status --repo "$d12" --session A)" "11. the repro is bound to its need"
assert_eq "1 proving pending background check --need" "$(stage "$d12" B,A)" "11. unchecked repro → the background check, need token first"
python3 "$REPRO" check --repo "$d12" --session A --need N1 >/dev/null 2>&1
assert_eq "1 proving blocked skill " "$(stage "$d12" A)" "11. checked red at this work state → a fix step"
touch "$d12/fixed.txt"
assert_eq "1 proving pending background check --need" "$(stage "$d12" A)" "11. the tree moved → the red check no longer counts"
python3 "$REPRO" check --repo "$d12" --session A --need N1 >/dev/null 2>&1
assert_eq "1 proving done none " "$(stage "$d12" A)" "11. checked green at this work state → done"
echo more > "$d12/other.txt"
assert_eq "1 proving pending background check --need" "$(stage "$d12" A)" "11. a later change makes the green check stale"
d13="$ROOT/t13"; mkrepo "$d13"
echo 0 > "$d13/run.log"; git -C "$d13" add -A; git -C "$d13" commit -qm log
python3 "$REPRO" record --repo "$d13" --session A --need N1 --cmd 'echo x >> run.log; test -f fixed.txt' >/dev/null 2>&1
touch "$d13/fixed.txt"
python3 "$REPRO" check --repo "$d13" --session A --need N1 >/dev/null 2>&1
assert_eq "1 proving pending background check --need" "$(stage "$d13" A)" "11. a probe that moved the tree while it ran proves nothing"
python3 - "$d13/.git/proof-of-fix.json" "$(dirname "$REPRO")" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2]); import _kernel
st = json.load(open(sys.argv[1]))
st["sessions"]["A"]["started"] = "2000-01-01T00:00:00+00:00"
st["sessions"]["old"] = {"started": "2000-01-01T00:00:00+00:00", "cmd": "false"}
_kernel.write_sessions(sys.argv[1], st)
PY
kept=$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["sessions"])))' "$d13/.git/proof-of-fix.json")
assert_eq "A" "$kept" "11. the session GC keeps a need-bound repro and collects the stale one"

# --- 12. schema v2: probes keyed by need and criterion, red bound to a work state, files pinned ----
cstage(){ python3 "$REPRO" stage --repo "$1" --need N2 --stage "$2" --criteria "$3" | python3 -c 'import json,sys; d=json.load(sys.stdin)
print(d["stage"], d["state"], d["next"]["kind"])'; }
cinstr(){ python3 "$REPRO" stage --repo "$1" --need N2 --stage "$2" --criteria "$3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next"].get("instruction", ""))'; }
d14="$ROOT/t14"; mkrepo "$d14"
assert_eq "contracting pending skill" "$(cstage "$d14" contracting c1,c2)" "12. no probe yet → contracting asks for them"
assert_contains "--criterion c1" "$(cinstr "$d14" contracting c1,c2)" "12. and names the record command per open criterion"
python3 "$REPRO" stage --repo "$d14" --need N2 --stage contracting >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "12. contracting without the contract's criteria is refused, never a silent done"
python3 "$REPRO" stage --repo "$d14" --need N2 --stage proving >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "12. proving without criteria or sessions is refused"
python3 "$REPRO" record --repo "$d14" --need N2 --criterion c1 --cmd "true" >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "12. a passing probe is refused"
out=$(python3 "$REPRO" record --repo "$d14" --need N2 --criterion c1 --file tests/c1.sh --cmd "bash tests/c1.sh" 2>&1); rc=$?
assert_eq 1 "$rc" "12. a declared probe file that does not exist is refused (red would mean missing)"
assert_contains "tests/c1.sh" "$out" "12. and the refusal names it"
mkdir -p "$d14/tests"; echo 'test -f feature.txt' > "$d14/tests/c1.sh"
python3 "$REPRO" record --repo "$d14" --need N2 --criterion c1 --file tests/c1.sh --cmd "bash tests/c1.sh" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "12. a failing probe is recorded on a dirty tree, its file pinned"
assert_eq "$(git -C "$d14" rev-parse HEAD)" "$(python3 "$REPRO" status --repo "$d14" --need N2 | python3 -c 'import json,sys; print(json.load(sys.stdin)["c1"]["red"]["head"])')" "12. red is bound to the work state it failed at"
assert_eq "contracting pending skill" "$(cstage "$d14" contracting c1,c2)" "12. c2 still open"
python3 "$REPRO" waive --repo "$d14" --need N2 --criterion c2 >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "12. a waiver needs a reason"
python3 "$REPRO" waive --repo "$d14" --need N2 --criterion c2 --reason "docs only" >/dev/null
assert_eq "contracting done none" "$(cstage "$d14" contracting c1,c2)" "12. every criterion has a probe or a waiver → done"
assert_eq "proving pending background" "$(cstage "$d14" proving c1,c2)" "12. unchecked → the background check"
python3 "$REPRO" check --repo "$d14" --need N2 >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "12. check fails while a criterion is red"
assert_eq "proving blocked skill" "$(cstage "$d14" proving c1,c2)" "12. red at this work state → a fix step"
touch "$d14/feature.txt"
python3 "$REPRO" check --repo "$d14" --need N2 >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "12. green once implemented (the waived criterion is not run)"
assert_eq "proving done none" "$(cstage "$d14" proving c1,c2)" "12. every probe green at this work state → done"
echo 'true' > "$d14/tests/c1.sh"
python3 "$REPRO" check --repo "$d14" --need N2 >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "12. a pinned probe file edited after its red run fails the check"
assert_contains "re-record" "$(cinstr "$d14" proving c1,c2)" "12. and proving asks to record it again"
python3 "$REPRO" record --repo "$d14" --session A --cmd "false" >/dev/null 2>&1
assert_contains '"c2"' "$(python3 "$REPRO" status --repo "$d14" --need N2)" "12. a v1 session write keeps the need-keyed probes"
python3 "$REPRO" forget --repo "$d14" --need N2 >/dev/null
assert_eq "{}" "$(python3 "$REPRO" status --repo "$d14" --need N2)" "12. forget drops a need's probes"

# --- 13. a probe that cannot be red is recorded red-waived, with its reason ------------------------
d15="$ROOT/t15"; mkrepo "$d15"; echo x > "$d15/done.txt"
python3 "$REPRO" record --repo "$d15" --need N3 --criterion c1 --cmd "test -f done.txt" >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "13. already true → refused without a reason"
python3 "$REPRO" record --repo "$d15" --need N3 --criterion c1 --cmd "test -f done.txt" --red-waived "true before the need" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "13. recorded red-waived with its reason"
assert_contains '"waived": "true before the need"' "$(python3 "$REPRO" status --repo "$d15" --need N3)" "13. the reason is kept for the report"

# --- 14. one proving verdict for both schemas: a v1 caller never proves a need whose v2 probes are red
d16="$ROOT/t16"; mkrepo "$d16"; mkdir -p "$d16/tests"; echo 'test -f feature.txt' > "$d16/tests/c1.sh"
python3 "$REPRO" record --repo "$d16" --need N4 --criterion c1 --file tests/c1.sh --cmd "bash tests/c1.sh" >/dev/null 2>&1
v1stage(){ python3 "$REPRO" stage --repo "$1" --need N4 --sessions "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"])'; }
assert_eq "pending" "$(v1stage "$d16" S1)" "14. a stage asked by sessions still counts the need's recorded criteria"
python3 "$REPRO" check --repo "$d16" --need N4 --session S1 >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "14. the conductor's v1 check command runs the need's red probe too"
assert_eq "blocked" "$(v1stage "$d16" S1)" "14. and proving reads it red"
python3 "$REPRO" record --repo "$d16" --session S1 --need N4 --cmd "test -f bug-fixed.txt" >/dev/null 2>&1
touch "$d16/feature.txt"
python3 "$REPRO" check --repo "$d16" --need N4 --session S1 >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "14. a need-bound session repro still red fails the check"
touch "$d16/bug-fixed.txt"
python3 "$REPRO" check --repo "$d16" --need N4 --session S1 >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "14. both green → the check passes"
assert_eq "done" "$(v1stage "$d16" S1)" "14. and proving is done only now"

# --- 15. the v2 proving invariants: moved tree, stale green, missing criterion, red's work state ---
d17="$ROOT/t17"; mkrepo "$d17"; echo 0 > "$d17/run.log"; git -C "$d17" add -A; git -C "$d17" commit -qm log
python3 "$REPRO" record --repo "$d17" --need N5 --criterion c1 --cmd 'echo x >> run.log; test -f f.txt' >/dev/null 2>&1
touch "$d17/f.txt"; cp "$d17/run.log" "$ROOT/run17.before"
python3 "$REPRO" check --repo "$d17" --need N5 >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "15. a probe that moves the tree while it runs proves nothing"
assert_eq "proving pending background" "$(python3 "$REPRO" stage --repo "$d17" --need N5 --criteria c1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["stage"], d["state"], d["next"]["kind"])')" "15. and proving stays pending"
cp "$ROOT/run17.before" "$d17/run.log"
assert_eq "pending" "$(python3 "$REPRO" stage --repo "$d17" --need N5 --criteria c1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')" "15. even once the tree is back where the unstable check started"
d18="$ROOT/t18"; mkrepo "$d18"; echo dirty > "$d18/wip.txt"
python3 "$REPRO" record --repo "$d18" --need N6 --criterion c1 --cmd 'test -f g.txt' >/dev/null 2>&1
assert_eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import repro; print(repro.work_state(sys.argv[2])[1])' "$(dirname "$REPRO")" "$d18")" \
  "$(python3 "$REPRO" status --repo "$d18" --need N6 | python3 -c 'import json,sys; print(json.load(sys.stdin)["c1"]["red"]["dirty"])')" "15. red carries the dirty state it failed at"
touch "$d18/g.txt"; git -C "$d18" add -A; git -C "$d18" commit -qm impl
python3 "$REPRO" check --repo "$d18" --need N6 >/dev/null 2>&1
echo later > "$d18/later.txt"; git -C "$d18" add -A
assert_eq "pending" "$(python3 "$REPRO" stage --repo "$d18" --need N6 --criteria c1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')" "15. a change after a green check makes it stale"
assert_eq "blocked" "$(python3 "$REPRO" stage --repo "$d18" --need N6 --criteria c1,c9 | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')" "15. a contract criterion with no probe is never proven"

# --- 16. the CLI contract of the need-keyed commands --------------------------------------------------
d19="$ROOT/t19 x"; mkrepo "$d19"; mkdir -p "$d19/tests"; echo 'test -f h.txt' > "$d19/tests/{id}.sh"
python3 "$REPRO" record --repo "$d19" --need N7 --criterion c1 --file 'tests/{id}.sh' --cmd 'bash "tests/{id}.sh"' >/dev/null 2>&1
echo 'true' > "$d19/tests/{id}.sh"; python3 "$REPRO" check --repo "$d19" --need N7 >/dev/null 2>&1
out=$(python3 "$REPRO" stage --repo "$d19" --need N7 --criteria c1 2>&1)
assert_absent "Traceback" "$out" "16. a pinned path with braces never crashes the instruction"
rerecord=$(printf '%s' "$out" | python3 -c 'import json,re,sys; print(re.search(r"`([^`]+)`", json.load(sys.stdin)["next"]["instruction"]).group(1))')
echo 'test -f h.txt' > "$d19/tests/{id}.sh"
assert_contains "record --repo" "$rerecord" "16. proving names the full re-record command"
bash -c "$rerecord" >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "16. the re-record command it names runs as written, in a path with a space"
cmd=$(python3 "$REPRO" stage --repo "$d19" --need N7 --stage contracting --criteria c2 | python3 -c 'import json,re,sys; print(re.search(r"`([^`]+)`", json.load(sys.stdin)["next"]["instruction"]).group(1))')
assert_contains "t19 x' --need" "$cmd" "16. contracting's commands quote the repo path"
out=$(python3 "$REPRO" waive --repo "$d19" --need N7 --criterion c2 --reason '  ' 2>&1); rc=$?
assert_eq 2 "$rc" "16. a blank waiver reason is refused"
python3 "$REPRO" record --repo "$d19" --need N7 --criterion c3 --cmd true --red-waived ' ' >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "16. a blank red-waived reason is refused"
echo x > "$ROOT/outside.sh"
python3 "$REPRO" record --repo "$d19" --need N7 --criterion c4 --file ../outside.sh --cmd false >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "16. a probe file outside the repo is refused"
python3 "$REPRO" record --repo "$d19" --need N7 --cmd false --file tests/x.sh >/dev/null 2>&1; rc=$?
assert_eq 2 "$rc" "16. --file without --criterion is refused, never dropped"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
