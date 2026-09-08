#!/usr/bin/env bash
# session-orchestrator test suite — exercises orchestrator.py against a stub `claude` binary, a fake
# CLAUDE_CONFIG_DIR (jobs/ and sessions/ state files) and a throwaway ORCHESTRATOR_HOME, never the real ones.
set -u
ORCH="$(cd "$(dirname "$0")/.." && pwd)/scripts/orchestrator.py"
ROOT="$(mktemp -d)"
export ORCHESTRATOR_HOME="$ROOT/orchestrator"
export CLAUDE_CONFIG_DIR="$ROOT/config"
export CLAUDE_CODE_EXECPATH="$ROOT/bin/claude"
export CLAUDE_CODE_SESSION_ID="56cf0730-0000-4000-8000-000000000501"
export CLAUDE_CODE_BRIDGE_SESSION_ID="session_01PILOTPILOTPILOTPILOT01"
export CLAUDE_PID=501
STUB_AGENTS="$ROOT/agents.json"; export STUB_AGENTS

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"

mkdir -p "$ROOT/bin" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/jobs"
cat > "$ROOT/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2 $3" = "agents --json --all" ] && { cat "$STUB_AGENTS"; exit 0; }
echo "stub: unsupported $*" >&2; exit 1
STUB
chmod +x "$ROOT/bin/claude"

orch(){ python3 "$ORCH" "$@" 2>&1; }
session(){ printf '%s\n' "$2" > "$CLAUDE_CONFIG_DIR/sessions/$1.json"; }
job(){ mkdir -p "$CLAUDE_CONFIG_DIR/jobs/$1"; printf '%s\n' "$2" > "$CLAUDE_CONFIG_DIR/jobs/$1/state.json"; }

cat > "$STUB_AGENTS" <<'JSON'
[
 {"pid":501,"kind":"interactive","status":"busy","name":"pilot-mac","cwd":"/Users/me","sessionId":"56cf0730-0000-4000-8000-000000000501","startedAt":1},
 {"pid":502,"kind":"interactive","status":"idle","name":"workspace","cwd":"/Users/me/src/app","sessionId":"9192c7ef-0000-4000-8000-000000000502","startedAt":2},
 {"pid":504,"kind":"interactive","status":"busy","name":"builder","cwd":"/Users/me/src/infra","sessionId":"bbbb0000-0000-4000-8000-000000000504","startedAt":8},
 {"pid":503,"kind":"interactive","status":"waiting","waitingFor":"input needed","name":"reviewer","cwd":"/Users/me/src/app","sessionId":"aaaa0000-0000-4000-8000-000000000503","startedAt":9},
 {"id":"ab12cd34","kind":"background","state":"working","status":"busy","name":"refactor auth","cwd":"/Users/me/src/app","sessionId":"ab12cd34-0000-4000-8000-000000000001","startedAt":3},
 {"id":"ff00ff00","kind":"background","state":"blocked","status":"waiting","waitingFor":"permission prompt","name":"deploy staging","cwd":"/Users/me/src/infra","sessionId":"ff00ff00-0000-4000-8000-000000000002","startedAt":4},
 {"id":"d0d0d0d0","kind":"background","state":"done","name":"write changelog","cwd":"/Users/me/src/app","sessionId":"d0d0d0d0-0000-4000-8000-000000000003","startedAt":5}
]
JSON
session 501 '{"pid":501,"name":"pilot-mac","bridgeSessionId":"session_01PILOTPILOTPILOTPILOT01","cwd":"/Users/me"}'
session 502 '{"pid":502,"name":"workspace","bridgeSessionId":"session_01WORKSPACEWORKSPACE0001","cwd":"/Users/me/src/app"}'
printf 'secret-token' > "$CLAUDE_CONFIG_DIR/sessions/502.abcdef.key"
job ab12cd34 '{"state":"working","bridgeSessionId":"cse_01REFACTORREFACTOR000001","name":"refactor auth"}'
job ff00ff00 '{"state":"blocked","needs":"approve the terraform apply","bridgeSessionId":"cse_01DEPLOYDEPLOYDEPLOY0001","name":"deploy staging"}'
job d0d0d0d0 '{"state":"done","output":{"result":"CHANGELOG.md updated, 12 entries"},"bridgeSessionId":"cse_01CHANGELOGCHANGELOG0001","name":"write changelog","updatedAt":"2026-01-01T00:00:00.000Z"}'

echo "session-orchestrator tests"

# 1. empty registry → actionable message, pilot recognised from the harness, exit 0
out=$(orch list); code=$?
assert_contains 'pilot: pilot-mac' "$out" "1. pilot identified from CLAUDE_CODE_SESSION_ID"
assert_contains 'no target registered' "$out" "1. empty registry explains what to do"
assert_eq 0 "$code" "1. empty registry exits 0"

# 2. sync → every local session imported with the id the harness gives it, the pilot excluded
out=$(orch sync)
assert_contains 'synced 6 local session(s)' "$out" "2. six peers imported"
assert_absent 'pilot-mac' "$(orch list --json | grep '"name"')" "2. pilot never becomes a target"
listing=$(orch list)
assert_contains 'session_01WORKSPACEWORKSPACE0001' "$listing" "2. interactive bridge id read from sessions/<pid>.json"
assert_contains 'cse_01REFACTORREFACTOR000001' "$listing" "2. background bridge id read from jobs/<id>/state.json"
assert_contains 'ab12cd34' "$(orch list --json)" "2. background short id kept for claude logs/attach/stop"

# 3. list → the harness state is live, never cached: blocking reason and final result surface
assert_contains 'working' "$listing" "3. working state shown"
assert_contains 'blocked: approve the terraform apply (permission prompt)' "$listing" "3. the session's own reason first, the harness one after"
assert_contains 'waiting: input needed' "$listing" "3. waitingFor alone shown"
assert_contains 'done: CHANGELOG.md updated' "$listing" "3. final result shown"
assert_contains 'idle' "$listing" "3. interactive status shown"

# 4. .key token files sitting next to the registry are never read
assert_absent 'secret-token' "$(orch list --json)" "4. token files never read"

# 5. assign → busy target refused, live tag refused, the pilot refused
orch assign workspace T01 >/dev/null
assert_contains 'T01' "$(orch list)" "5. order recorded"
out=$(orch assign workspace T02); code=$?
assert_eq 2 "$code" "5. second order on a busy target refused"
assert_contains 'still running T01' "$out" "5. refusal names the running tag"
out=$(orch assign "refactor auth" T01); code=$?
assert_eq 2 "$code" "5. live tag reuse refused"
assert_contains 'already running on workspace' "$out" "5. refusal names the holder"
out=$(orch assign pilot-mac T09); code=$?
assert_eq 2 "$code" "5. assigning the pilot refused"
assert_contains 'this session' "$out" "5. refusal explains why"

# 5b. an order to a busy interactive session is accepted but warned: it will be read mid-turn
out=$(orch assign builder B-01); code=$?
assert_eq 0 "$code" "5b. busy interactive target still accepts the order"
assert_contains 'busy right now' "$out" "5b. warning says it will be read mid-turn"
assert_absent 'busy right now' "$(orch assign workspace T05 2>&1; orch resolve workspace ok --tag T05 >/dev/null 2>&1)" "5b. no warning on an idle target"

# 6. resolve → wrong tag refused, right tag frees the target
out=$(orch resolve workspace ok --tag T99); code=$?
assert_eq 2 "$code" "6. verdict for another tag refused"
orch resolve workspace ok --tag T01 >/dev/null
assert_eq 0 "$(orch assign workspace T02 >/dev/null 2>&1; echo $?)" "6. freed target accepts a new order"

# 7. report → harness buckets first, then orders, then registry-only knowledge
orch add pi-lab --machine pi --bridge-id session_01PILABPILABPILABPILAB01 >/dev/null
orch add ghost --machine "$(hostname -s)" >/dev/null
orch assign "refactor auth" R-01 >/dev/null
orch assign "write changelog" C-01 >/dev/null
out=$(orch report)
assert_contains '4 open order(s)' "$out" "7. open orders counted whatever the harness state"
assert_contains 'WORKING      refactor auth  working · order R-01 since' "$out" "7. a working target still shows its order"
assert_contains '→ resolve it' "$out" "7. a finished target with an open order asks for its verdict"
assert_contains 'NEEDS INPUT  deploy staging  blocked: approve the terraform apply (permission prompt)' "$out" "7. blocked session first, with its own reason and the harness one"
assert_contains 'WORKING      refactor auth' "$out" "7. working session listed"
assert_contains 'OPEN ORDER   workspace  T02 since' "$out" "7. open order with its age"
assert_contains 'FINISHED     write changelog  done: CHANGELOG.md updated, 12 entries · ' "$out" "7. finished session with its result"
assert_contains 'ago · claude rm d0d0d0d0 to clear' "$out" "7. finished session dated, with the command that clears it"
assert_contains 'NEEDS INPUT  reviewer  waiting: input needed' "$out" "7. interactive session waiting for input reported"
assert_contains 'remote       pi-lab' "$out" "7. other-machine target has no harness view"
assert_contains 'offline      ghost' "$out" "7. local target gone from the harness is offline"
assert_contains 'NO ID        ghost' "$out" "7. target without a claude.ai id flagged unreadable"
assert_absent 'NO ID        pi-lab' "$out" "7. remote target with an id is readable"

# 8. harness unavailable → the registry still answers, with a warning, exit 0
out=$(CLAUDE_CODE_EXECPATH="$ROOT/bin/missing" orch list); code=$?
assert_eq 0 "$code" "8. no harness exits 0"
assert_contains 'harness unavailable' "$out" "8. warning printed"
assert_contains 'workspace' "$out" "8. registry still listed"

# 9. sync is idempotent and follows a rename by local id
before=$(orch list --json | grep -c '"name": "workspace"')
orch sync >/dev/null
assert_eq "$before" "$(orch list --json | grep -c '"name": "workspace"')" "9. sync does not duplicate"
LC_ALL=C sed -i.bak 's/"name":"workspace"/"name":"workspace-renamed"/' "$STUB_AGENTS"
orch sync >/dev/null
assert_contains 'workspace-renamed' "$(orch list)" "9. renamed session followed"
assert_absent '"name": "workspace"' "$(orch list --json)" "9. old name gone"

# 10. corrupted registry degrades to empty instead of crashing
printf 'not json at all' > "$ORCHESTRATOR_HOME/registry.json"
out=$(orch list); code=$?
assert_eq 0 "$code" "10. corrupted registry exits 0"
assert_contains 'no target registered' "$out" "10. corrupted registry reads as empty"

# 11. forget → the target is dropped, an unknown one is an error
orch add gone --bridge-id session_01GONEGONEGONEGONEGONE01 >/dev/null
orch forget gone >/dev/null
assert_absent 'gone' "$(orch list)" "11. target dropped"
assert_eq 1 "$(orch forget nobody >/dev/null 2>&1; echo $?)" "11. forgetting an unknown target exits 1"

rm -rf "$ROOT"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
