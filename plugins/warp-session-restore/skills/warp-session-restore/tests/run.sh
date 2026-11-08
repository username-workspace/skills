#!/usr/bin/env bash
# warp-session-restore test suite — a throwaway Claude Code session registry, git repositories and fake
# claude processes; never the real Warp, ~/.claude or ~/.warp.
set -u
WS="$(cd "$(dirname "$0")/.." && pwd)/scripts/warp_session_restore.py"
ROOT="$(mktemp -d)"
. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"

export HOME="$ROOT/home"; mkdir -p "$HOME"
REG="$ROOT/registry"; SNAPS="$ROOT/snaps"; LAUNCH="$ROOT/launch"; TABS="$ROOT/tabs"
mkdir -p "$REG" "$ROOT/bin" "$ROOT/plain"
export WS_SESSIONS_DIR="$REG" WS_SNAPSHOT_DIR="$SNAPS" WS_LAUNCH_DIR="$LAUNCH" WS_TAB_DIR="$TABS"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset WS_SNAPSHOT WS_BOOT_ID WS_OPEN WS_OPEN_WAIT
ws(){ python3 "$WS" "$@" 2>&1; }

git init -q "$ROOT/repo" && git -C "$ROOT/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$ROOT/repo" worktree add -q "$ROOT/repo-wt" -b wt 2>/dev/null
mkdir -p "$ROOT/repo/sub"

cat > "$ROOT/bin/ps" <<EOF
#!/bin/sh
case " \$* " in *" comm= "*) [ -n "\${STUB_WARP:-}" ] && echo "/Applications/Warp.app/Contents/MacOS/stable warp-terminal"; exit 0 ;; esac
exec /bin/ps "\$@"
EOF
chmod +x "$ROOT/bin/ps"; export PATH="$ROOT/bin:$PATH"

printf '#!/usr/bin/env bash\nsleep 60\n' > "$ROOT/fakeclaude"; chmod +x "$ROOT/fakeclaude"
lstart(){ LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" | sed 's/ *$//'; }
reg(){ printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","kind":"interactive","entrypoint":"%s","name":"%s"}\n' "$1" "$2" "$3" "$(lstart "$1")" "$4" "$5" > "$REG/$1.json"; }
"$ROOT/fakeclaude" --remote-control alpha --permission-mode auto "a prompt" & PA=$!
"$ROOT/fakeclaude" --model opus & PB=$!
"$ROOT/fakeclaude" & PC=$!
"$ROOT/fakeclaude" --effort medium & PH=$!
"$ROOT/fakeclaude" & PD=$!
sleep 0.3
reg "$PA" aaaa-1111 "$ROOT/repo/sub" cli "Alpha Session"
reg "$PB" bbbb-2222 "$ROOT/repo-wt" cli beta
reg "$PC" cccc-3333 "$ROOT/plain" cli ""
reg "$PH" hhhh-4444 "$HOME" cli macbook
reg "$PD" dddd-5555 "$ROOT/plain" claude-desktop desk
printf '{"pid":999999,"sessionId":"dead-6666","cwd":"/x","procStart":"Mon Jan  1 00:00:00 2024","kind":"interactive","entrypoint":"cli","name":"dead"}\n' > "$REG/999999.json"
group_of(){ python3 -c 'import json,sys; print({s["sessionId"]: s["group"] for s in json.load(open(sys.argv[1]))["sessions"]}.get(sys.argv[2], "-"))' "$SNAPS/boot1.json" "$1"; }

echo "warp-session-restore tests"

python3 -m py_compile "$WS" && ok "1. script compiles" || ko "1. script does not compile"

out=$(WS_BOOT_ID=boot1 ws snapshot); s1="$(cat "$SNAPS/boot1.json" 2>/dev/null)"
assert_eq repo "$(group_of aaaa-1111)" "2. a session in a repository's subfolder is grouped by its repository"
assert_eq repo "$(group_of bbbb-2222)" "2. a worktree is grouped with its repository"
assert_eq plain "$(group_of cccc-3333)" "2. a folder outside git is its own group"
assert_eq home "$(group_of hhhh-4444)" "2. the home folder is the group home"
assert_absent "dddd-5555" "$s1" "2. a desktop-app session is left out"
assert_absent "dead-6666" "$s1" "2. a dead session is left out"
assert_absent "a prompt" "$s1" "2. the initial prompt is not replayed"
assert_contains "group repo" "$out" "2. snapshot prints the groups"

out=$(WS_SNAPSHOT=0 WS_BOOT_ID=off ws snapshot)
[ ! -e "$SNAPS/off.json" ] && ok "3. WS_SNAPSHOT=0 → no snapshot" || ko "3. WS_SNAPSHOT=0 still wrote one"

kill "$PA" "$PB" "$PC" "$PH" 2>/dev/null; wait "$PA" "$PB" "$PC" "$PH" 2>/dev/null
rm -f "$REG/$PA.json" "$REG/$PB.json" "$REG/$PC.json" "$REG/$PH.json"
sleep 1.1; printf '{"boot":"boot2","sessions":[]}\n' > "$SNAPS/boot2.json"
y=$(WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "boot1.json" "$y" "4. restore reads the newest snapshot of a PREVIOUS boot"
assert_contains "opens in: a new Warp window" "$y" "4. Warp not running → a launch configuration"
groups=$(printf '%s\n' "$y" | sed -n 's/^      - name: //p' | tr '\n' '|')
assert_eq '"home"|"plain"|"repo"|' "$groups" "4. one tab group per folder, in name order"
assert_contains 'color: blue' "$y" "4. each group has its color"
order=$(printf '%s\n' "$y" | sed -n 's/^      - title: //p' | tr '\n' '|')
assert_eq '"macbook"|"plain cccc-333"|"Alpha Session"|"beta"|' "$order" "4. tabs follow their group, an unnamed session titled by folder and id"
assert_contains '"claude --resume aaaa-1111 -n '"'"'Alpha Session'"'"' --remote-control alpha --permission-mode auto"' "$y" "4. a session resumes in place, named, with its flags"
assert_contains '"claude --resume hhhh-4444 -n macbook --effort medium"' "$y" "4. … its effort included"
assert_contains "cwd: \"$ROOT/repo/sub\"" "$y" "4. … in its own folder"
assert_absent "fork-session" "$y" "4. never forks: the same session id comes back"

reg $$ bbbb-2222 "$ROOT/repo-wt" cli beta
y=$(WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "beta: already running" "$y" "5. a session already running is not resumed twice"
assert_absent "--resume bbbb-2222" "$y" "5. … no tab for it"
rm -f "$REG/$$.json"

y=$(WS_BOOT_ID=boot2 ws restore --dry-run beta)
assert_contains "--resume bbbb-2222" "$y" "6. name filter keeps the named session"
assert_absent "--resume aaaa-1111" "$y" "6. … and only it"
out=$(WS_BOOT_ID=boot2 python3 "$WS" restore --dry-run nobody 2>&1); rc=$?
assert_eq 1 "$rc" "6. unknown name → exit 1"

rm -rf "$ROOT/plain"
y=$(WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "$ROOT/plain no longer exists" "$y" "7. a session whose folder is gone is named"
assert_absent "--resume cccc-3333" "$y" "7. … and not reopened"

cat > "$ROOT/bin/opener" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/open.cap"
[ -n "\${STUB_RESUMES:-}" ] || exit 0
nohup "$ROOT/fakeclaude" >/dev/null 2>&1 & p=\$!
printf '{"pid":%s,"sessionId":"aaaa-1111","cwd":"/x","procStart":"%s","kind":"interactive","entrypoint":"cli","name":"a"}\n' "\$p" "\$(LC_ALL=C TZ=UTC0 ps -o lstart= -p \$p | sed 's/ *\$//')" > "$REG/\$p.json"
EOF
chmod +x "$ROOT/bin/opener"
out=$(WS_OPEN="$ROOT/bin/opener" WS_OPEN_WAIT=1 WS_BOOT_ID=boot2 python3 "$WS" restore "Alpha Session" 2>&1); rc=$?
assert_eq "warp://launch/warp-session-restore.yaml" "$(cat "$ROOT/open.cap" 2>/dev/null)" "8. opened by file name, the form Warp resolves"
assert_contains "--resume aaaa-1111" "$(cat "$LAUNCH/warp-session-restore.yaml" 2>/dev/null)" "8. the launch configuration is written where Warp reads it"
assert_eq 1 "$rc" "8. a session that never came back → exit 1"
assert_contains "not back yet: aaaa-1111" "$out" "8. … naming it, with the manual way"
out=$(STUB_RESUMES=1 WS_OPEN="$ROOT/bin/opener" WS_OPEN_WAIT=5 WS_BOOT_ID=boot2 python3 "$WS" restore "Alpha Session" 2>&1); rc=$?
assert_eq 0 "$rc" "8. every resumed session running again → exit 0"
assert_contains "restored" "$out" "8. … and says so"

for f in "$REG"/*.json; do grep -q aaaa-1111 "$f" && { kill "$(basename "$f" .json)" 2>/dev/null; rm -f "$f"; }; done
rm -f "$ROOT/open.cap"
y=$(STUB_WARP=1 WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "opens in: the Warp window already open" "$y" "9. Warp running → restore opens in its window"
assert_absent "tab_groups" "$y" "9. … from Tab Configs, which hold no group"
assert_contains '"rm -f '"$TABS"'/warp-session-restore-1.toml", "claude --resume hhhh-4444 -n macbook --effort medium"' "$y" "9. the tab deletes its Tab Config, then resumes in place"
assert_contains 'color = "blue"' "$y" "9. … its tab colored like its group"
assert_contains "directory = \"$ROOT/repo/sub\"" "$y" "9. … in its own folder"
out=$(STUB_RESUMES=1 STUB_WARP=1 WS_OPEN="$ROOT/bin/opener" WS_OPEN_WAIT=5 WS_BOOT_ID=boot2 python3 "$WS" restore "Alpha Session" 2>&1); rc=$?
assert_eq "warp://tab_config/warp-session-restore-1" "$(cat "$ROOT/open.cap" 2>/dev/null)" "10. opened by name into the active window, nothing else"
assert_contains "--resume aaaa-1111" "$(cat "$TABS/warp-session-restore-1.toml" 2>/dev/null)" "10. the Tab Config is written where Warp reads it"
assert_eq 0 "$rc" "10. its session running again → exit 0"
for f in "$REG"/*.json; do grep -q aaaa-1111 "$f" && { kill "$(basename "$f" .json)" 2>/dev/null; rm -f "$f"; }; done
y=$(STUB_WARP=1 WS_BOOT_ID=boot2 ws restore --dry-run --window)
assert_contains '- name: "repo"' "$y" "11. --window opens a new window, groups included"

kill "$PD" 2>/dev/null
for f in "$REG"/*.json; do p="$(basename "$f" .json)"; [ "$p" = 999999 ] || kill "$p" 2>/dev/null; done
echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
