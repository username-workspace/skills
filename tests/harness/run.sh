#!/usr/bin/env bash
# Delivery-harness composition suite — ship-when-done × merge-review × mr-watchdog on real throwaway
# repos, driven through the real hooks. Encodes the end-to-end contract the three plugins promise
# together: single-shot deliveries are reviewed and watched, the gate runs once per work-state, every
# user-facing outcome reaches a rendered channel, and block-continuations advance the pipeline without
# a human prompt (bounded — never an infinite Stop loop).
set -u
ROOT="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIP="$REPO_ROOT/plugins/ship-when-done/skills/ship-when-done/scripts/ship.py"
WATCH="$REPO_ROOT/plugins/mr-watchdog/skills/mr-watchdog/scripts/watch.py"
REVIEW="$REPO_ROOT/plugins/merge-review/skills/merge-review/scripts/review.py"
SHIP_HOOK="$REPO_ROOT/plugins/ship-when-done/hooks/stop-hook.py"
SHIP_PLUGIN="$REPO_ROOT/plugins/ship-when-done"
GH_LOG="$ROOT/gh.log"; : > "$GH_LOG"

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1   # this suite pins the AUTO lanes; the explicit default is pinned in its own block

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
key="\$(pwd | tr '/' '_')"
case "\$1 \$2" in
  "pr merge") echo "MERGE-CALLED" >> "$GH_LOG"; exit 0;;
  "pr view") if [ -f "$ROOT/pr-\$key-\$3" ]; then echo '{"state":"OPEN"}'; exit 0; else echo "no pull requests found" >&2; exit 1; fi;;
  "pr checks") echo '[{"bucket":"pending"}]'; exit 0;;
  "pr create")
     head=""; while [ \$# -gt 0 ]; do [ "\$1" = "--head" ] && head="\$2"; shift; done
     [ -n "\$head" ] && touch "$ROOT/pr-\$key-\$head"
     echo "https://example.test/pr/1"; exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

new_repo(){ # $1=dir  [$2=--remote]  [$3=forge-host, default github.com]
  local d="$1" host="${3:-github.com}"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  if [ "${2:-}" = "--remote" ]; then
    git init -q --bare "$d.git"; git -C "$d.git" config receive.advertisePushOptions true
    git -C "$d" remote add origin "$d.git"
    git -C "$d" config remote.origin.pushurl "$d.git"
    git -C "$d" config remote.origin.url "https://$host/test/repo.git"
    git -C "$d" push -q -u origin main 2>/dev/null
  fi
}
stop_payload(){ printf '{"cwd":"%s","session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$1" "$2" "$3" "$4"; }
prompt_baselines(){ python3 "$SHIP" baseline --repo "$1" --session "$2" >/dev/null
  python3 "$REVIEW" baseline --repo "$1" --session "$2" >/dev/null
  python3 "$WATCH" baseline --repo "$1" --session "$2" >/dev/null; }
pr_creates(){ grep -c 'pr create' "$GH_LOG" || true; }

tp="$ROOT/transcript.jsonl"
cat > "$tp" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"ZV-9 ship the gizmo"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done — gizmo shipped and verified."}]}}
J

echo "delivery-harness composition tests"

# --- 1. B1: the quality gate runs once per work-state, not on every Stop ---------------------------
d="$ROOT/b1"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"gate":"echo run >> %s"}' "$ROOT/gate1.log" > "$d/.git/ship-when-done.json"; : > "$ROOT/gate1.log"
python3 "$SHIP" baseline --repo "$d" --session s1 >/dev/null
echo work > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. first engage with work → gate ran once"
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "1. work committed"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. idle Stops with unchanged work-state → gate NOT re-run"
echo more > "$d/a.txt"
python3 "$SHIP" engage --repo "$d" --session s1 >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate1.log" | tr -d ' ')" "1. work-state changed → gate runs again"

# --- 2. B2: single-shot branch-first delivery is held for review (not silently shipped) ------------
d="$ROOT/ss"; new_repo "$d" --remote
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"
prompt_baselines "$d" ss
echo gizmo > "$d/gizmo.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "ship the gizmo" --type feat >/dev/null
before=$(pr_creates)
out=$(stop_payload "$d" ss "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$out" "2. single-shot done → Stop blocks with a review request"
assert_contains 'merge-review' "$out" "2. the block asks for the merge-review pass"
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ko "2. nothing pushed before the review" || ok "2. nothing pushed before the review"
assert_eq "$before" "$(pr_creates)" "2. no PR opened before the review"
assert_eq 2 "$(git -C "$d" rev-list --count HEAD)" "2. the work IS committed (anti-loss)"

# --- 3. B4: after the review pass, the re-entrant Stop ships it (no human prompt needed) ------------
python3 "$REVIEW" record --repo "$d" --score 95 --passed >/dev/null
out2=$(stop_payload "$d" ss "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ok "3. re-entrant Stop pushed the reviewed branch" || ko "3. re-entrant Stop pushed the reviewed branch"
assert_eq "$((before + 1))" "$(pr_creates)" "3. re-entrant Stop opened the PR"
grep -q 'MERGE-CALLED' "$GH_LOG" && ko "3. GUARDRAIL: never merged" || ok "3. GUARDRAIL: never merged"

# --- 4. B2b: the watchdog is handed the MR the pipeline just opened (no Stop-hook race) -------------
assert_contains 'run --repo' "$out2" "4. PR opened → the same Stop hands off the watcher launch"
assert_contains 'run_in_background' "$out2" "4. the launch instruction is the background-watch contract"
assert_eq "yes" "$(python3 "$WATCH" engaged --repo "$d" --session ss)" "4. watchdog engaged on the branch ship pushed"

# --- 5. loop safety: a re-entrant Stop with unchanged state never re-blocks (bounded continuation) --
out3=$(stop_payload "$d" ss "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_absent '"decision": "block"' "$out3" "5. same state again → no second block (no infinite Stop loop)"
assert_eq "$((before + 1))" "$(pr_creates)" "5. no duplicate PR"

# --- 6. loop safety: an unanswered review request is not re-blocked for the same work-state ---------
d6="$ROOT/b6"; new_repo "$d6" --remote
printf '{"gate":"true"}' > "$d6/.git/ship-when-done.json"
prompt_baselines "$d6" s6
echo w > "$d6/w.txt"
python3 "$SHIP" mark-done --repo "$d6" --summary w >/dev/null
o1=$(stop_payload "$d6" s6 "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
o2=$(stop_payload "$d6" s6 "$tp" true | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$o1" "6. first Stop → review block"
assert_absent '"decision": "block"' "$o2" "6. review not done, state unchanged → no re-block"

# --- 7. B3: a no-CLI forge surfaces the PR URL on a rendered channel (systemMessage), not bare stdout
d7="$ROOT/b3"; new_repo "$d7" --remote bitbucket.org; git -C "$d7" checkout -q -b feat
printf '{"gate":"true"}' > "$d7/.git/ship-when-done.json"
python3 "$SHIP" baseline --repo "$d7" --session s7 >/dev/null
echo x > "$d7/x.txt"
python3 "$SHIP" mark-done --repo "$d7" --summary "bb work" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d7" --session s7)
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "systemMessage" in d' 2>/dev/null \
  && ok "7. engage output is hook JSON with a systemMessage" || ko "7. engage output is hook JSON with a systemMessage — got [$out]"
assert_contains 'pull-requests/new' "$out" "7. the bitbucket PR-creation URL is in the rendered message"

# --- 8. visibility: done but NO gate detectable → the withheld PR is said out loud ------------------
d8="$ROOT/nogate"; new_repo "$d8" --remote; git -C "$d8" checkout -q -b feat
python3 "$SHIP" baseline --repo "$d8" --session s8 >/dev/null
echo x > "$d8/x.txt"
python3 "$SHIP" mark-done --repo "$d8" --summary "no gate here" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d8" --session s8)
assert_contains 'no-gate-detected' "$out" "8. no detectable gate → withheld reason names it"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "no-gate" in d.get("systemMessage","")' 2>/dev/null \
  && ok "8. the notice is on the rendered channel" || ko "8. the notice is on the rendered channel — got [$out]"

# --- 9. detect_gate is stack-horizontal, not a JS/PHP allowlist -------------------------------------
gd(){ python3 -c "
import sys, importlib.util as u
sp = u.spec_from_file_location('ship', '$SHIP'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
print(m.detect_gate(sys.argv[1], {'gate': None}) or 'NONE')" "$1"; }
g="$ROOT/g"; mkdir -p "$g/go" "$g/rust" "$g/py" "$g/mk" "$g/yarn" "$g/phpno" "$g/phpyes"
echo 'module t' > "$g/go/go.mod"
echo '[package]' > "$g/rust/Cargo.toml"
printf '[tool.pytest.ini_options]\n' > "$g/py/pyproject.toml"
printf 'test:\n\ttrue\n' > "$g/mk/Makefile"
printf '{"scripts":{"test":"jest"}}' > "$g/yarn/package.json"; : > "$g/yarn/yarn.lock"
printf '{"require":{}}' > "$g/phpno/composer.json"
printf '{"scripts":{"test":"phpunit"}}' > "$g/phpyes/composer.json"
assert_eq "go test ./..." "$(gd "$g/go")" "9. go.mod → go test"
assert_eq "cargo test" "$(gd "$g/rust")" "9. Cargo.toml → cargo test"
assert_contains "pytest" "$(gd "$g/py")" "9. pyproject pytest config → pytest"
assert_eq "make test" "$(gd "$g/mk")" "9. Makefile test target → make test"
assert_eq "yarn test" "$(gd "$g/yarn")" "9. yarn.lock → yarn, not npm"
assert_eq "NONE" "$(gd "$g/phpno")" "9. composer.json without a test script → no blind 'composer test'"
assert_eq "composer test" "$(gd "$g/phpyes")" "9. composer.json with a test script → composer test"

# --- 10. a timed-out gate is transient evidence: distinct reason, never cached ----------------------
d10="$ROOT/b10"; new_repo "$d10" --remote; git -C "$d10" checkout -q -b feat
printf '{"gate":"echo run >> %s; sleep 3","gate_timeout":1}' "$ROOT/gate10.log" > "$d10/.git/ship-when-done.json"; : > "$ROOT/gate10.log"
python3 "$SHIP" baseline --repo "$d10" --session s10 >/dev/null
echo w > "$d10/w.txt"
python3 "$SHIP" mark-done --repo "$d10" --summary w >/dev/null
out=$(python3 "$SHIP" engage --repo "$d10" --session s10)
assert_contains 'gate-timeout' "$out" "10. timed-out gate → distinct visible reason (not gate-not-green)"
python3 "$SHIP" engage --repo "$d10" --session s10 >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10.log" | tr -d ' ')" "10. timeout NOT cached → gate re-runs on the next Stop"

# --- 10b. real usage: a transient red gate self-heals — only GREEN verdicts are cached --------------
d="$ROOT/b10b"; new_repo "$d" --remote; git -C "$d" checkout -q -b feat
printf '{"gate":"echo run >> %s; test -f %s"}' "$ROOT/gate10b.log" "$ROOT/healed" > "$d/.git/ship-when-done.json"
: > "$ROOT/gate10b.log"; rm -f "$ROOT/healed"
python3 "$SHIP" baseline --repo "$d" --session sb >/dev/null
echo w > "$d/w.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "transient" >/dev/null
out=$(python3 "$SHIP" engage --repo "$d" --session sb)
assert_contains 'gate-not-green' "$out" "10b. red gate → PR withheld, visibly"
assert_contains '"verdict": "fail"' "$(cat "$d/.git/swd-gate.json" 2>/dev/null)" "10b. the gate run leaves evidence (verdict persisted)"
touch "$ROOT/healed"
before=$(pr_creates)
python3 "$SHIP" engage --repo "$d" --session sb >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10b.log" | tr -d ' ')" "10b. fail NOT cached → gate re-ran on the idle Stop and healed"
assert_eq "$((before + 1))" "$(pr_creates)" "10b. healed gate → the PR opens without any tree change"
python3 "$SHIP" engage --repo "$d" --session sb >/dev/null 2>&1
assert_eq 2 "$(wc -l < "$ROOT/gate10b.log" | tr -d ' ')" "10b. green verdict IS cached → no re-run on the next idle Stop"

# --- 11. watchdog handoff survives the forge's check-registration window (silent first answer) ------
d="$ROOT/b11"; new_repo "$d"
cat > "$ROOT/fakewatch.py" <<EOF
import json, os
flag = os.path.join("$ROOT", "b11-second-call")
if os.path.exists(flag):
    print(json.dumps({"decision": "block", "reason": "launch run --repo X with run_in_background"}))
else:
    open(flag, "w").write("x")
EOF
printf '{"session":"s11","script":"%s","branches":{}}' "$ROOT/fakewatch.py" > "$d/.git/mr-watchdog-session.json"
out=$(python3 -c "
import importlib.util as u
sp = u.spec_from_file_location('ship', '$SHIP'); m = u.module_from_spec(sp); sp.loader.exec_module(m)
print(m.watchdog_handoff('$d', 's11') or 'NONE')")
assert_contains 'run_in_background' "$out" "11. silent first answer (checks not registered yet) → retried, nudge captured"

# --- 12. impacted-suite selection: the gate runs only what the diff touches (FULL stays the truth) --
sel(){ python3 "$REPO_ROOT/scripts/impacted.py" "$@"; }
assert_eq "plugins/find-session" "$(sel plugins/find-session/skills/find-session/scripts/x.py)" "12. impacted: plugin file → its plugin"
assert_eq "FULL" "$(sel scripts/readme.py)" "12. impacted: shared script → full run"
assert_eq "FULL" "$(sel .claude-plugin/marketplace.json plugins/find-session/web.json)" "12. impacted: mixed shared+plugin → full"
assert_eq "plugins/a
plugins/b" "$(sel plugins/a/x plugins/b/y)" "12. impacted: two plugins → both"
assert_eq "FULL" "$(sel </dev/null)" "12. impacted: no changed paths → conservative full"
assert_eq "plugins/a" "$(printf 'plugins/a/x\nplugins/a/y\n' | python3 "$REPO_ROOT/scripts/impacted.py")" "12. impacted: stdin paths, deduped"

# sandbox repo: --impacted runs exactly the touched plugin's suite + the harness; shared path → full
sb="$ROOT/sandbox"; mkdir -p "$sb/scripts" "$sb/plugins/a/tests" "$sb/plugins/b/tests" "$sb/tests/harness"
cp "$REPO_ROOT/scripts/run-tests.sh" "$REPO_ROOT/scripts/impacted.py" "$sb/scripts/" 2>/dev/null
RUNLOG="$ROOT/impacted-ran.log"          # outside the sandbox repo — the log must not dirty it
printf '#!/usr/bin/env bash\necho a >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/plugins/a/tests/run.sh"
printf '#!/usr/bin/env bash\necho b >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/plugins/b/tests/run.sh"
printf '#!/usr/bin/env bash\necho h >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/tests/harness/run.sh"
echo lib > "$sb/plugins/a/lib.py"
git -C "$sb" init -q -b main; git -C "$sb" config user.email t@t.t; git -C "$sb" config user.name t; git -C "$sb" config commit.gpgsign false
git -C "$sb" add -A; git -C "$sb" commit -qm init
git -C "$sb" checkout -q -b feat
echo x > "$sb/plugins/a/file.py"; git -C "$sb" add -A; git -C "$sb" commit -qm "touch a"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
h" "$(sort "$RUNLOG")" "12. --impacted: exactly the touched plugin + the harness ran"
echo y > "$sb/scripts/shared.py"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: a dirty shared path forces the FULL run"
rm -f "$sb/scripts/shared.py"
# a broken base ref can never under-select: conservative full
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted no-such-base >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: unknown base → conservative FULL, never under-selects"
# INCIDENT (review): rename collapsing dropped the donor side — both feeds must see old AND new path
git -C "$sb" checkout -q -b mv-cross main
git -C "$sb" mv plugins/a/lib.py plugins/b/lib.py; git -C "$sb" commit -qm "move a→b"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: committed cross-plugin rename runs BOTH sides' suites"
git -C "$sb" checkout -q -b mv-shared main
echo s > "$sb/scripts/util.py"; git -C "$sb" add -A; git -C "$sb" commit -qm "shared util"
git -C "$sb" mv scripts/util.py plugins/b/util.py
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: staged rename OUT of scripts/ → FULL (the donor is shared)"
git -C "$sb" checkout -qf feat 2>/dev/null
# INCIDENT: a suite that reads stdin ate the gate's suite list — every suite sorting after it was
# silently skipped (the gate loop shared its stdin with the suites it ran)
git -C "$sb" checkout -qf main 2>/dev/null
printf '#!/usr/bin/env bash\ncat >/dev/null\necho a >> "%s"\nexit 0\n' "$RUNLOG" > "$sb/plugins/a/tests/run.sh"
git -C "$sb" add -A; git -C "$sb" commit -qm "plugin a suite now slurps stdin"
: > "$RUNLOG"; bash "$sb/scripts/run-tests.sh" >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. a stdin-eating suite can NOT swallow the suites after it"
git -C "$sb" checkout -qf feat 2>/dev/null

# INCIDENT (review): a failing `git status` was masked by the pipeline's exit status → under-selection
mkdir -p "$sb/shim"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = status ] && exit 128; done\nexec "%s" "$@"\n' "$(command -v git)" > "$sb/shim/git"
chmod +x "$sb/shim/git"
: > "$RUNLOG"; env PATH="$sb/shim:$PATH" bash "$sb/scripts/run-tests.sh" --impacted main >/dev/null 2>&1
assert_eq "a
b
h" "$(sort "$RUNLOG")" "12. --impacted: git status failure → FULL, never a silent under-selection"

# 13. the vendored kernel cannot silently diverge from lib/_kernel.py (the lockstep-patch incident class)
out=$(python3 "$REPO_ROOT/scripts/kernel-sync.py" --check 2>&1) \
  && ok "13. vendored kernel copies in sync with lib/_kernel.py" \
  || ko "13. vendored kernel drifted — $out"

# --- 14. INCIDENT (real usage): a branch created MID-TURN escaped the pre-push gate ------------------
# The session started on a detached HEAD (worktree pattern) so no baseline was ever stamped; the branch
# was created and pushed inside one turn → engaged()=false → two PRs pushed unreviewed. The session's
# work was observable all along in ship-when-done's provenance file: the gate must couple on it.
d="$ROOT/b14"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat
echo gizmo > "$d/g.txt"; echo sp > "$d/café.txt"; git -C "$d" add -A; git -C "$d" commit -qm work
printf '{"v":1,"sessions":{"s14":{"paths":["g.txt"]},"s-q":{"paths":["café.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. no-baseline branch + swd provenance carried by the branch → gate engaged"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s-q)" \
  "14. a carried path git C-quotes (non-ASCII) still intersects"
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s-other)" \
  "14. another session's provenance does not engage this one"
d="$ROOT/b14b"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat
echo x > "$d/x.txt"; git -C "$d" add -A; git -C "$d" commit -qm work
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. absent sibling provenance → inert (a teammate's branch is never gated)"
printf '{"v":1,"sessions":{"s14":{"paths":["other.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. disjoint provenance (prov ∩ carried = ∅) does NOT engage — intersection, not mere presence"
printf 'null' > "$d/.git/swd-provenance.json"
assert_eq "no" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. wrong-shape provenance (valid JSON, wrong schema) → inert, never a crash"
d="$ROOT/b14c"; new_repo "$d" --remote
git -C "$d" checkout -q -b feat
echo dirty >> "$d/README.md"
echo new > "$d/café-dirty.txt"
printf '{"v":1,"sessions":{"s14":{"paths":["README.md"]},"s-qd":{"paths":["café-dirty.txt"]}}}' > "$d/.git/swd-provenance.json"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s14)" \
  "14. worktree-only edit (leading-space porcelain line) is carried evidence too"
assert_eq "yes" "$(python3 "$REVIEW" engaged --repo "$d" --session s-qd)" \
  "14. untracked non-ASCII path (porcelain C-quotes it) is carried evidence too"

# --- 14b. AUTO is scoped: never from a session launched outside a repo, never under an excluded path
dS="$ROOT/scope/side"; new_repo "$dS" --remote; git -C "$dS" checkout -q -b feat
python3 "$REVIEW" baseline --repo "$dS" --session s-sc >/dev/null
echo w > "$dS/w.txt"; git -C "$dS" add -A; git -C "$dS" commit -qm w
mkdir -p "$ROOT/scope/home"
engaged_in(){ env CLAUDE_PROJECT_DIR="$1" HARNESS_AUTO_ENGAGE_EXCLUDE="$2" python3 "$REVIEW" engaged --repo "$dS" --session s-sc; }
assert_eq "yes" "$(engaged_in "$dS" "")" "14b. session launched in the repo → AUTO engages"
assert_eq "no" "$(engaged_in "$ROOT/scope/home" "")" "14b. session launched in a plain folder (\$HOME) → explicit only"
assert_eq "no" "$(engaged_in "$dS" "$ROOT/scope")" "14b. repo under an excluded path → explicit only"
assert_eq "no" "$(engaged_in "$dS/.." "")" "14b. launch dir that is not a work tree, even above the repo → explicit only"
dX="$ROOT/scope-x"; new_repo "$dX"
assert_eq "no" "$(engaged_in "$dX" "$dX")" "14b. session launched in an excluded repo → explicit for every repo it touches"
assert_eq "yes" "$(engaged_in "$dS" "/nonexistent:$ROOT/scope-x")" "14b. exclusions elsewhere leave a side project AUTO"
assert_eq "no" "$(engaged_in "$dS" "/nonexistent: $ROOT/scope ")" "14b. a padded exclusion entry still excludes"
assert_eq "no" "$(env HARNESS_E2E_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$dS" HARNESS_AUTO_ENGAGE_EXCLUDE='$HARNESS_E2E_ROOT/scope' python3 "$REVIEW" engaged --repo "$dS" --session s-sc)" \
  "14b. an exclusion written with \$VAR (a JSON settings value is not shell-expanded) still excludes"
assert_eq "no" "$(engaged_in "$dS" "relative/tree")" "14b. an entry that cannot resolve to an absolute path fails closed"
assert_eq "no" "$(engaged_in "$dS" '/x/$HARNESS_UNSET_VAR/tree')" "14b. an unexpanded \$VAR anywhere in an entry fails closed"
swapped="$(dirname "$ROOT")/$(basename "$ROOT" | tr 'a-zA-Z' 'A-Za-z')/scope"
if [ -d "$swapped" ]; then
  assert_eq "no" "$(engaged_in "$dS" "$swapped")" "14b. case-insensitive filesystem: an entry spelled with another case still excludes"
else
  ok "14b. case-sensitive filesystem: another spelling is another tree (nothing to assert)"
fi
python3 "$SHIP" mark-done --repo "$dS" --summary w >/dev/null
assert_eq "yes" "$(engaged_in "$ROOT/scope/home" "")" "14b. an explicit declaration still engages outside the AUTO scope"

# --- 15. EXPLICIT MODE (the default — HARNESS_AUTO_ENGAGE unset): a DECLARED single-shot delivery
# flows through the whole pipeline exactly like AUTO. The prompt hooks still RECORD (presence files
# the siblings couple on — the review hold, the watcher handoff); engagement itself is never inferred,
# it comes from the mark-done declaration alone.
dE="$ROOT/bexp"; new_repo "$dE" --remote
printf '{"gate":"true"}' > "$dE/.git/ship-when-done.json"
prompt_baselines "$dE" se
echo gizmo > "$dE/gizmo.txt"
python3 "$SHIP" mark-done --repo "$dE" --summary "ship the gizmo" --type feat >/dev/null
beforeE=$(pr_creates)
outE=$(stop_payload "$dE" se "$tp" false | env -u HARNESS_AUTO_ENGAGE CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
assert_contains '"decision": "block"' "$outE" "15. declared delivery → Stop blocks for the review (engagement from the declaration alone)"
assert_eq "$beforeE" "$(pr_creates)" "15. no PR before the review"
python3 "$REVIEW" record --repo "$dE" --score 95 --passed >/dev/null
outE2=$(stop_payload "$dE" se "$tp" true | env -u HARNESS_AUTO_ENGAGE CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK")
git -C "$dE.git" rev-parse --verify -q zv-9-work >/dev/null && ok "15. reviewed → pushed" || ko "15. reviewed → pushed"
assert_eq "$((beforeE + 1))" "$(pr_creates)" "15. PR opened after the review"
assert_eq "yes" "$(env -u HARNESS_AUTO_ENGAGE python3 "$WATCH" engaged --repo "$dE" --session se)" \
  "15. watchdog engaged via ship's handoff stamp — no inference"
dF="$ROOT/bexp2"; new_repo "$dF" --remote; git -C "$dF" checkout -q -b feat
echo w > "$dF/w.txt"; git -C "$dF" add -A; git -C "$dF" commit -qm w
assert_eq "no" "$(env -u HARNESS_AUTO_ENGAGE python3 "$REVIEW" engaged --repo "$dF" --session sf)" \
  "15. no declaration → a manual push is never gated by default"
python3 "$SHIP" mark-done --repo "$dF" --summary w >/dev/null
assert_eq "yes" "$(env -u HARNESS_AUTO_ENGAGE python3 "$REVIEW" engaged --repo "$dF" --session sf)" \
  "15. declared delivery in flight → the pre-push gate arms"

# --- 16. E2E ledger staleness tracks the plugins the lane exercises, not the whole marketplace -------
dL="$ROOT/ledger"; new_repo "$dL"
mkdir -p "$dL/tests/e2e" "$dL/plugins/ship-when-done" "$dL/plugins/claude-remote-spawn" \
  "$dL/plugins/proof-of-fix" "$dL/lib"
cp "$REPO_ROOT/tests/e2e/e2e.py" "$dL/tests/e2e/"
touch "$dL/plugins/ship-when-done/a"; git -C "$dL" add -A; git -C "$dL" commit -qm harness
harness_sha=$(git -C "$dL" rev-parse --short HEAD)
ledger_rev(){ python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import e2e; print(e2e.harness_rev())' "$dL/tests/e2e"; }
touch "$dL/plugins/claude-remote-spawn/b"; git -C "$dL" add -A; git -C "$dL" commit -qm crs
assert_eq "$harness_sha" "$(ledger_rev)" "16. a commit to a plugin the lane never runs leaves every proof fresh"
touch "$dL/plugins/proof-of-fix/c"; git -C "$dL" add -A; git -C "$dL" commit -qm pof
assert_eq "$(git -C "$dL" rev-parse --short HEAD)" "$(ledger_rev)" "16. proof-of-fix runs in the needs space: a change there makes the ledger stale"
touch "$dL/lib/_kernel.py"; git -C "$dL" add -A; git -C "$dL" commit -qm kernel
assert_eq "$(git -C "$dL" rev-parse --short HEAD)" "$(ledger_rev)" "16. a kernel change makes the ledger stale"
fill_labels(){ python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import e2e
print(" ".join(sorted(e2e.scenario_label(sc) for sc in e2e.stale_scenarios())))' "$dL/tests/e2e"; }
all=$(fill_labels)
for space in 'bare/' 'twist/' 'explicit/' 'multi/' 'need/'; do
  assert_contains " $space" " $all" "16. an empty ledger → --fill proves the ${space%/} situations too"
done
python3 - "$dL/tests/e2e" <<'PY'
import json, sys; sys.path.insert(0, sys.argv[1]); import e2e
cur = e2e.harness_rev()
labels = sorted(e2e.scenario_label(sc) for sc in e2e.stale_scenarios())
cov = {l: {"harness": cur} for l in labels}
cov[labels[-1]]["harness"] = "0000000"
json.dump(cov, open(e2e.COVERAGE, "w"))
PY
last=$(python3 -c 'import sys; print(sorted(sys.argv[1].split())[-1])' "$all")
assert_eq "$last" "$(fill_labels)" "16. --fill re-proves exactly the stale situation, whatever its space"
mkdir -p "$ROOT/ghdup"; export GHDUP_LOG="$ROOT/ghdup.log"; : > "$GHDUP_LOG"
cat > "$ROOT/ghdup/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GHDUP_LOG"
[ "$1 $2" = "issue list" ] && echo '[{"number":67,"title":"e2e: persistent failure — twist/wip-branch (seed tag s1)"}]'
[ "$1 $2" = "issue comment" ] && exit "${GHDUP_COMMENT_RC:-0}"
exit 0
EOF
chmod +x "$ROOT/ghdup/gh"
file_issue(){ PATH="$ROOT/ghdup:$PATH" python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import e2e
e2e.FORGE = sys.argv[3]
e2e.file_issue(json.loads(sys.argv[2]), "s9", "boom")' "$dL/tests/e2e" "$1" "${2:-github}"; }
file_issue '{"twist": "wip-branch"}'
assert_contains "issue comment 67" "$(cat "$GHDUP_LOG")" "16. a scenario already failing in an open issue gets a comment there"
assert_absent "issue create" "$(cat "$GHDUP_LOG")" "16. never a duplicate issue for the same scenario"
: > "$GHDUP_LOG"; file_issue '{"twist": "preexisting-dirty"}'
assert_contains "issue create" "$(cat "$GHDUP_LOG")" "16. a new failing scenario still files its own issue"
: > "$GHDUP_LOG"; GHDUP_COMMENT_RC=1 file_issue '{"twist": "wip-branch"}'
assert_contains "issue create" "$(cat "$GHDUP_LOG")" "16. a comment that fails still leaves a record (falls back to a new issue)"
assert_absent "--search" "$(cat "$GHDUP_LOG")" "16. the open-issue lookup lists directly, never through the lagging search index"
: > "$GHDUP_LOG"; file_issue '{"flow": "single-shot", "gate": "green", "ci": "green"}' gitlab
assert_contains "e2e.py --forge gitlab --scenario single-shot:green:green" "$(cat "$GHDUP_LOG")" \
  "16. a GitLab failure's issue carries a command that reproduces it on GitLab"
mkdir -p "$ROOT/forgedown"
for cli in gh glab; do printf '#!/usr/bin/env bash\necho "401 Unauthorized" >&2; exit 1\n' > "$ROOT/forgedown/$cli"; done
chmod +x "$ROOT/forgedown/gh" "$ROOT/forgedown/glab"
forge_listing(){ PATH="$ROOT/forgedown:$PATH" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import e2e
e2e.FORGE = sys.argv[2]
try:
    print("returned", getattr(e2e, sys.argv[3])())
except RuntimeError:
    print("raised")' "$dL/tests/e2e" "$1" "$2"; }
for forge in github gitlab; do
  for listing in open_prs branches; do
    assert_eq "raised" "$(forge_listing $forge $listing)" \
      "16. $forge $listing: a forge that cannot answer is an error, never an empty sandbox"
  done
done

# --- 17. a linked worktree works under the repo's trusted config, not a config of its own ------------
dW="$ROOT/wtrepo"; new_repo "$dW"
printf '{"gate":"echo ran >> %s"}' "$ROOT/gate17.log" > "$dW/.git/ship-when-done.json"; : > "$ROOT/gate17.log"
printf '{"threshold":95}' > "$dW/.git/merge-review.json"
git -C "$dW" worktree add -q -b feat .claude/worktrees/w; w="$dW/.claude/worktrees/w"
python3 "$SHIP" baseline --repo "$w" --session s17 >/dev/null
echo work > "$w/a.txt"
python3 "$SHIP" engage --repo "$w" --session s17 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate17.log" | tr -d ' ')" "17. a delivery from a worktree runs the repo's gate"
review_threshold(){ python3 "$REVIEW" context --repo "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["threshold"])'; }
assert_eq 95 "$(review_threshold "$w")" "17. the repo's review threshold holds in its worktree"
printf '{"threshold":70}' > "$(git -C "$w" rev-parse --git-dir)/merge-review.json"
assert_eq 70 "$(review_threshold "$w")" "17. a worktree's own git dir may still override the repo's config"
assert_eq 95 "$(review_threshold "$dW")" "17. that override stays in its worktree"

# --- 18. owner CLIs for every cross-plugin write: ship-when-done hands engagement to the siblings
# through their own `handoff`; merge-review present with prepush_gate off never holds the push --------
d="$ROOT/b17"; new_repo "$d" --remote
printf '{"gate":"true"}' > "$d/.git/ship-when-done.json"; printf '{"prepush_gate":false}' > "$d/.git/merge-review.json"
prompt_baselines "$d" s17
echo g > "$d/g.txt"
python3 "$SHIP" mark-done --repo "$d" --summary "ship the gizmo" --type feat >/dev/null
stop_payload "$d" s17 "$tp" false | CLAUDE_PLUGIN_ROOT="$SHIP_PLUGIN" python3 "$SHIP_HOOK" >/dev/null
git -C "$d.git" rev-parse --verify -q zv-9-work >/dev/null && ok "18. prepush_gate off: pushed with no review hold" \
  || ko "18. prepush_gate off: pushed with no review hold"
handed(){ python3 -c 'import json,sys; st=json.load(open(sys.argv[1]))
print(((st["sessions"].get("s17") or {}).get("branches") or {}).get("zv-9-work", {}).get("engaged"))' "$1"; }
assert_eq True "$(handed "$d/.git/merge-review-session.json")" "18. merge-review engaged through review.py handoff"
assert_eq True "$(handed "$d/.git/mr-watchdog-session.json")" "18. mr-watchdog engaged through watch.py handoff"

# --- 19. discovery: after one prompt every owner's script path is stamped in .git, and a repo that opted
# an owner out hears it from that owner's own stage CLI, never from a stamp that may be stale ------------
REPRO="$REPO_ROOT/plugins/proof-of-fix/skills/proof-of-fix/scripts/repro.py"
d="$ROOT/b18"; new_repo "$d" --remote; git -C "$d" checkout -q -b need/n1
prompt_baselines "$d" s18; python3 "$REPRO" nudge --repo "$d" --session s18 --prompt "hello" >/dev/null
for f in swd-session merge-review-session mr-watchdog-session proof-of-fix; do
  s=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("script",""))' "$d/.git/$f.json" 2>/dev/null)
  [ -n "$s" ] && [ -f "$s" ] && ok "19. $f stamps its owner's script path" || ko "19. $f stamps its owner's script path"
done
printf '{"enabled":false}' > "$d/.ship-when-done.json"; printf '{"enabled":false}' > "$d/.git/merge-review.json"
printf '{"enabled":false}' > "$d/.mr-watchdog.json"; printf '{"enabled":false}' > "$d/.proof-of-fix.json"
optout(){ "$@" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["evidence"].get("enabled"))'; }
assert_eq "blocked False" "$(optout python3 "$SHIP" stage --repo "$d" --need N --stage gating)" "19. ship-when-done opted out → its stage says so"
assert_eq "blocked False" "$(optout python3 "$REVIEW" stage --repo "$d" --need N)" "19. merge-review opted out → its stage says so"
assert_eq "blocked False" "$(optout python3 "$WATCH" stage --repo "$d" --need N)" "19. mr-watchdog opted out → its stage says so"
assert_eq "blocked False" "$(optout python3 "$REPRO" stage --repo "$d" --need N --sessions s18)" "19. proof-of-fix opted out → its stage says so"

# --- 20. the stage command each SKILL.md documents runs exactly as written (the conductor and the model
# read those lines) ------------------------------------------------------------------------------------
d="$ROOT/b19"; new_repo "$d" --remote; git -C "$d" checkout -q -b need/n1
for p in ship-when-done merge-review mr-watchdog proof-of-fix; do
  line=$(grep -o '`scripts/[a-z]*\.py stage [^`]*`' "$REPO_ROOT/plugins/$p/skills/$p/SKILL.md" | head -1 | tr -d '`')
  cmd=$(printf '%s' "$line" | sed -e "s#^scripts/#$REPO_ROOT/plugins/$p/skills/$p/scripts/#" -e "s# R # $d #" \
    -e 's# N # N1 #; s# N$# N1#; s# S$# gating#; s# S # gating #; s#S1,S2#s1#')
  [ -n "$line" ] && python3 $cmd >/dev/null 2>&1 && ok "20. $p: the documented stage command runs" \
    || ko "20. $p: the documented stage command runs [$line]"
done

# --- 17b. a bare repository shipped inside a clone is never a source of trusted config -------------
dE="$ROOT/embedded"; new_repo "$dE"; git init -q --bare "$dE/vendor/evil"
printf '{"gate":"touch %s"}' "$ROOT/pwned" > "$dE/vendor/evil/ship-when-done.json"
git -C "$dE" add -A; git -C "$dE" commit -qm "vendor an embedded bare repo"
python3 "$SHIP" gate --repo "$dE/vendor/evil" --need n17 >/dev/null 2>&1
[ -e "$ROOT/pwned" ] && ko "17b. a gate from an embedded bare repo never runs" || ok "17b. a gate from an embedded bare repo never runs"
git -C "$dE/vendor/evil" symbolic-ref HEAD refs/heads/embedded-branch
git -C "$dE/vendor/evil" config remote.origin.url https://gitlab.com/evil/repo.git
assert_eq "None gitlab-no" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import _kernel as k
e = sys.argv[2]; print(k.cur_branch(e), "gitlab-" + ("yes" if k.detect_forge(e, {}, k.remote_name(e)) == "gitlab" else "no"))' "$REPO_ROOT/lib" "$dE/vendor/evil")" \
  "17b. no harness git call reads an embedded bare repo's HEAD or config"
git clone -q --bare "$dW" "$ROOT/real.git"; git -C "$ROOT/real.git" worktree add -q -b feat17b "$ROOT/real-wt"
printf '{"gate":"echo ran >> %s"}' "$ROOT/gate17b.log" > "$ROOT/real.git/ship-when-done.json"; : > "$ROOT/gate17b.log"
git -C "$ROOT/real-wt" config user.email t@t.t; git -C "$ROOT/real-wt" config user.name t
echo w > "$ROOT/real-wt/w.txt"; git -C "$ROOT/real-wt" add -A; git -C "$ROOT/real-wt" commit -qm w
python3 "$SHIP" gate --repo "$ROOT/real-wt" --need n17 >/dev/null 2>&1
assert_eq 1 "$(wc -l < "$ROOT/gate17b.log" | tr -d ' ')" "17b. a worktree of a real bare repository keeps its trusted gate"
dH="$ROOT/hooked"; new_repo "$dH" --remote; git -C "$dH" checkout -q -b feat17b; git init -q --bare "$ROOT/cache17b.git"
printf '#!/bin/sh\ncd %s && git rev-parse --git-dir >/dev/null\n' "$ROOT/cache17b.git" > "$dH/.git/hooks/pre-commit"; chmod +x "$dH/.git/hooks/pre-commit"
echo x > "$dH/x.txt"
assert_contains '"committed": true' "$(python3 "$SHIP" commit --need n17 --repo "$dH" --summary x --type chore 2>&1)" \
  "17b. the user's own hooks never inherit the guard (a pre-commit hook using a bare cache still works)"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]
