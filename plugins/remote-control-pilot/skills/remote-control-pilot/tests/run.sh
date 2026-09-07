#!/usr/bin/env bash
# remote-control-pilot test suite — exercises rc-sessions.sh against a throwaway HOME holding a
# fake ~/.claude/sessions registry, never the real one.
set -u
RC="$(cd "$(dirname "$0")/.." && pwd)/scripts/rc-sessions.sh"
ROOT="$(mktemp -d)"
FAKE_HOME="$ROOT/home"
SESSIONS="$FAKE_HOME/.claude/sessions"

. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"

rc(){ env HOME="$FAKE_HOME" bash "$RC" "$@" 2>&1; }
register(){ mkdir -p "$SESSIONS"; printf '%s\n' "$2" > "$SESSIONS/$1.json"; }

echo "remote-control-pilot tests"

# 1. empty registry → explicit message, exit 1
mkdir -p "$SESSIONS"
out=$(rc); rc_code=$?
assert_contains 'aucune session enregistree' "$out" "1. empty registry → explicit message"
assert_eq 1 "$rc_code" "1. empty registry exits 1"

# 2. a Remote Control session → name and bridge session ID on one row
register 101 '{"pid":101,"sessionId":"d06074e3-0000-4000-8000-000000000101","cwd":"/Users/me/src/app","version":"2.1.260","kind":"interactive","entrypoint":"cli","name":"workspace","nameSource":"user","bridgeSessionId":"session_01AAAAAAAAAAAAAAAAAAAAAA"}'
out=$(rc); rc_code=$?
assert_contains 'NOM' "$out" "2. header row printed"
assert_contains 'workspace' "$out" "2. session name printed"
assert_contains 'session_01AAAAAAAAAAAAAAAAAAAAAA' "$out" "2. bridge session ID printed"
assert_contains '/Users/me/src/app' "$out" "2. cwd printed"
assert_eq 0 "$rc_code" "2. listing exits 0"

# 3. a session without bridgeSessionId is flagged as not connected to Remote Control
register 102 '{"pid":102,"sessionId":"d06074e3-0000-4000-8000-000000000102","cwd":"/tmp/x","version":"2.1.260","kind":"interactive","entrypoint":"cli","name":"local-only"}'
out=$(rc)
assert_contains 'local-only' "$out" "3. non-RC session still listed"
assert_contains '(pas en Remote Control)' "$out" "3. missing bridgeSessionId flagged"

# 4. a session without a name shows the placeholder
register 103 '{"pid":103,"sessionId":"d06074e3-0000-4000-8000-000000000103","cwd":"/tmp/y","version":"2.1.260","kind":"interactive","entrypoint":"cli","bridgeSessionId":"session_01BBBBBBBBBBBBBBBBBBBBBB"}'
out=$(rc)
assert_contains '(sans nom)' "$out" "4. unnamed session shows placeholder"

# 5. --json prints the raw registry lines, one session per line
out=$(rc --json)
assert_contains '"bridgeSessionId":"session_01AAAAAAAAAAAAAAAAAAAAAA"' "$out" "5. --json keeps raw JSON"
assert_eq 3 "$(printf '%s\n' "$out" | grep -c '"pid"')" "5. --json prints one line per session"

# 6. .key token files next to the registry are never read
printf 'secret-token' > "$SESSIONS/101.abcdef.key"
out=$(rc --json)
assert_absent 'secret-token' "$out" "6. .key files are ignored"

# 7. --help prints the usage header, exit 0
out=$(rc --help); rc_code=$?
assert_contains 'Usage' "$out" "7. --help prints usage"
assert_eq 0 "$rc_code" "7. --help exits 0"

# 8. unknown argument → exit 2
out=$(rc --bogus); rc_code=$?
assert_contains 'argument inconnu' "$out" "8. unknown argument reported"
assert_eq 2 "$rc_code" "8. unknown argument exits 2"

# 9. --ssh without a host → usage error
out=$(rc --ssh); rc_code=$?
assert_contains 'hote manquant' "$out" "9. --ssh without host reported"
assert_eq 1 "$rc_code" "9. --ssh without host fails"

# 10. --ssh runs the reader through a stubbed ssh(1), never touching the local registry
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/ssh.cap"
printf '%s\n' '{"pid":7,"name":"remote-box","bridgeSessionId":"session_01CCCCCCCCCCCCCCCCCCCCCC","cwd":"/home/pi","kind":"interactive","entrypoint":"cli","version":"2.1.260"}'
EOF
chmod +x "$ROOT/bin/ssh"
out=$(env HOME="$FAKE_HOME" PATH="$ROOT/bin:$PATH" bash "$RC" --ssh pi5 2>&1)
assert_contains 'remote-box' "$out" "10. --ssh lists the remote registry"
assert_contains 'session_01CCCCCCCCCCCCCCCCCCCCCC' "$out" "10. --ssh prints the remote bridge ID"
assert_absent 'workspace' "$out" "10. --ssh does not mix in the local registry"
assert_contains 'BatchMode=yes' "$(cat "$ROOT/ssh.cap")" "10. ssh is non-interactive (BatchMode)"
assert_contains 'pi5' "$(cat "$ROOT/ssh.cap")" "10. ssh targets the given host"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
