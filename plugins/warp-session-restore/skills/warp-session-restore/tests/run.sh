#!/usr/bin/env bash
# warp-session-restore test suite — a throwaway Warp state database, Claude Code session registry and fake
# claude processes carrying a Warp pane uuid; never the real Warp, ~/.claude or ~/.warp.
set -u
WS="$(cd "$(dirname "$0")/.." && pwd)/scripts/warp_session_restore.py"
ROOT="$(mktemp -d)"
. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"

export HOME="$ROOT/home"; mkdir -p "$HOME"
DB="$ROOT/warp.sqlite"; REG="$ROOT/registry"; SNAPS="$ROOT/snaps"; LAUNCH="$ROOT/launch"
mkdir -p "$REG" "$ROOT/proj/a" "$ROOT/proj/b" "$ROOT/bin"
export WS_WARP_DB="$DB" WS_SESSIONS_DIR="$REG" WS_SNAPSHOT_DIR="$SNAPS" WS_LAUNCH_DIR="$LAUNCH" WS_TAB_DIR="$ROOT/tabs"
unset WS_SNAPSHOT WS_BOOT_ID WS_OPEN WS_OPEN_WAIT
ws(){ python3 "$WS" "$@" 2>&1; }

UA=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; UB=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
UC=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
python3 - "$DB" "$ROOT" <<'PY'
import sqlite3, sys
db, root = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
c.executescript("""
CREATE TABLE windows (id INTEGER PRIMARY KEY, active_tab_index INTEGER NOT NULL);
CREATE TABLE tab_groups (id INTEGER PRIMARY KEY, window_id INTEGER, name TEXT, color TEXT, collapsed BOOLEAN NOT NULL, pinned BOOLEAN NOT NULL DEFAULT FALSE);
CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER, custom_title TEXT, color TEXT, tab_group_id INTEGER, pinned BOOLEAN NOT NULL DEFAULT FALSE);
CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER, parent_pane_node_id INTEGER, flex FLOAT, is_leaf BOOLEAN NOT NULL);
CREATE TABLE pane_branches (id INTEGER PRIMARY KEY, pane_node_id INTEGER UNIQUE, horizontal BOOLEAN NOT NULL);
CREATE TABLE pane_leaves (pane_node_id INTEGER UNIQUE, kind TEXT NOT NULL, is_focused BOOLEAN NOT NULL DEFAULT FALSE);
CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, uuid BLOB NOT NULL, cwd TEXT);
""")
c.execute("INSERT INTO windows VALUES (1, 2)")
c.execute("INSERT INTO tab_groups VALUES (1, 1, 'work', '---\nColor: red\n', 1, 0)")
c.execute("INSERT INTO tab_groups VALUES (2, 1, 'perso', '---\nColor: green\n', 0, 1)")
c.execute("INSERT INTO tabs VALUES (1, 1, 'Split Tab', '---\nColor: magenta\n', 1, 0)")
c.execute("INSERT INTO tabs VALUES (2, 1, NULL, NULL, 2, 0)")
c.execute("INSERT INTO tabs VALUES (3, 1, NULL, NULL, 1, 0)")
c.execute("INSERT INTO tabs VALUES (4, 1, 'settings only', NULL, NULL, 0)")
def leaf(nid, tab, parent, uuid, cwd, focused=0, kind='terminal'):
    c.execute("INSERT INTO pane_nodes VALUES (?, ?, ?, ?, 1)", (nid, tab, parent, None if parent is None else 0.5))
    c.execute("INSERT INTO pane_leaves VALUES (?, ?, ?)", (nid, kind, focused))
    if kind == 'terminal':
        c.execute("INSERT INTO terminal_panes VALUES (?, ?, ?)", (nid, bytes.fromhex(uuid), cwd))
def branch(nid, tab, parent, horizontal):
    c.execute("INSERT INTO pane_nodes VALUES (?, ?, ?, ?, 0)", (nid, tab, parent, None if parent is None else 0.5))
    c.execute("INSERT INTO pane_branches (pane_node_id, horizontal) VALUES (?, ?)", (nid, horizontal))
branch(1, 1, None, 1)
leaf(2, 1, 1, 'A' * 32, root + '/proj/a', 1)
branch(3, 1, 1, 0)
leaf(4, 1, 3, 'C' * 32, root + '/proj/b')
leaf(5, 1, 3, '0' * 32, '', 0, 'settings')
leaf(6, 2, None, 'B' * 32, root + '/proj/b', 1)
leaf(7, 3, None, 'D' * 32, root, 1)
leaf(8, 4, None, '0' * 32, '', 0, 'settings')
c.commit()
PY

printf '#!/usr/bin/env bash\nsleep 120\n' > "$ROOT/fakeclaude"; chmod +x "$ROOT/fakeclaude"
lstart(){ LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" | sed 's/ *$//'; }
reg(){ printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","kind":"interactive","entrypoint":"%s","name":"%s"}\n' "$1" "$2" "$3" "$(lstart "$1")" "$4" "$5" > "$REG/$1.json"; }
WARP_TERMINAL_SESSION_UUID="$UA" "$ROOT/fakeclaude" --remote-control alpha --permission-mode auto "a prompt" & PA=$!
WARP_TERMINAL_SESSION_UUID="$UB" "$ROOT/fakeclaude" --model opus & PB=$!
"$ROOT/fakeclaude" & PO=$!
WARP_TERMINAL_SESSION_UUID="$UC" "$ROOT/fakeclaude" & PD=$!
sleep 0.3
# macOS hides the environment of Apple-signed binaries (/bin/bash on the stock floor) from ps -E; the
# real claude is not one, so a ps stub answers -E for the fake sessions and defers the rest to ps.
mkdir -p "$ROOT/env"; printf '%s' "$UA" > "$ROOT/env/$PA"; printf '%s' "$UB" > "$ROOT/env/$PB"; printf '%s' "$UC" > "$ROOT/env/$PD"
cat > "$ROOT/bin/ps" <<EOF
#!/bin/sh
case " \$* " in *" comm= "*) [ -n "\${STUB_WARP:-}" ] && echo "/Applications/Warp.app/Contents/MacOS/stable warp-terminal"; exit 0 ;; esac
case " \$* " in *" -E "*) for p; do :; done; u="\$(cat "$ROOT/env/\$p" 2>/dev/null)"; echo "fakeclaude \${u:+WARP_TERMINAL_SESSION_UUID=\$u}"; exit 0 ;; esac
exec /bin/ps "\$@"
EOF
chmod +x "$ROOT/bin/ps"; export PATH="$ROOT/bin:$PATH"
reg "$PA" aaaa-1111 "$ROOT/proj/a" cli "Alpha Session"
reg "$PB" bbbb-2222 "$ROOT/proj/b" cli beta
reg "$PO" oooo-3333 "$ROOT/proj/a" cli outsider
reg "$PD" dddd-4444 "$ROOT/proj/b" claude-desktop desk
printf '{"pid":999999,"sessionId":"dead-5555","cwd":"/x","procStart":"Mon Jan  1 00:00:00 2024","kind":"interactive","entrypoint":"cli","name":"dead"}\n' > "$REG/999999.json"

echo "warp-session-restore tests"

python3 -m py_compile "$WS" && ok "1. script compiles" || ko "1. script does not compile"

out=$(WS_BOOT_ID=boot1 ws snapshot); s1="$(cat "$SNAPS/boot1.json" 2>/dev/null)"
assert_contains '"sessionId": "aaaa-1111"' "$s1" "2. a Claude session is matched to its Warp pane"
assert_contains "oooo-3333" "$(python3 -c 'import json,sys; print([s["sessionId"] for s in json.load(open(sys.argv[1]))["outside"]])' "$SNAPS/boot1.json")" "2. a session outside Warp is listed apart"
assert_absent "dddd-4444" "$s1" "2. a desktop-app session is left out"
assert_absent "dead-5555" "$s1" "2. a dead session is left out"
assert_absent "a prompt" "$s1" "2. the initial prompt is not replayed"
assert_absent "settings only" "$s1" "2. a tab without a terminal pane is left out"
assert_contains "perso" "$out" "2. snapshot prints the layout"

out=$(WS_SNAPSHOT=0 WS_BOOT_ID=off ws snapshot)
[ ! -e "$SNAPS/off.json" ] && ok "3. WS_SNAPSHOT=0 → no snapshot" || ko "3. WS_SNAPSHOT=0 still wrote one"

kill "$PA" "$PB" 2>/dev/null; wait "$PA" "$PB" 2>/dev/null; rm -f "$REG/$PA.json" "$REG/$PB.json"
sleep 1.1; printf '{"boot":"boot2","windows":[],"outside":[]}\n' > "$SNAPS/boot2.json"
y=$(WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "boot1.json" "$y" "4. restore reads the newest snapshot of a PREVIOUS boot"
assert_contains '- name: "work"' "$y" "4. tab groups keep their name"
assert_contains 'color: red' "$y" "4. … their color"
assert_contains 'collapsed: true' "$y" "4. … collapsed state"
assert_contains 'pinned: true' "$y" "4. … pinned state"
assert_contains 'color: magenta' "$y" "4. tab color kept"
assert_contains 'split_direction: horizontal' "$y" "4. outer split kept"
assert_absent 'split_direction: vertical' "$y" "4. a split left with one terminal pane collapses into that pane"
assert_contains '"claude --resume aaaa-1111 -n '"'"'Alpha Session'"'"' --remote-control alpha --permission-mode auto"' "$y" "4. Claude pane resumes in place, named, with its flags"
assert_contains '"claude --resume bbbb-2222 -n beta --model opus"' "$y" "4. second session resumes with its own flags"
assert_absent "fork-session" "$y" "4. never forks: the same session id comes back"
assert_contains 'is_focused: true' "$y" "4. focused pane kept"
order=$(printf '%s\n' "$y" | sed -n 's/^      - title: //p' | tr '\n' '|')
assert_eq '"Split Tab"|""|"beta"|' "$order" "4. tabs of one group stay adjacent (Warp ungroups split runs)"
assert_contains 'active_tab_index: 1' "$y" "4. active tab follows the reordering"

reg $$ bbbb-2222 "$ROOT/proj/b" cli beta
y=$(WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "beta: already running" "$y" "5. a session already running is not resumed twice"
assert_absent "--resume bbbb-2222" "$y" "5. … its pane opens a shell"
rm -f "$REG/$$.json"

y=$(WS_BOOT_ID=boot2 ws restore --dry-run beta)
assert_contains "--resume bbbb-2222" "$y" "6. name filter keeps the named session's tab"
assert_absent "--resume aaaa-1111" "$y" "6. … and only it"
out=$(WS_BOOT_ID=boot2 python3 "$WS" restore --dry-run nobody 2>&1); rc=$?
assert_eq 1 "$rc" "6. unknown name → exit 1"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["windows"][0]["tabs"][1]["layout"]["claude"]["cwd"]="/gone"; json.dump(d,open(sys.argv[1],"w"))' "$SNAPS/boot1.json"
y=$(WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "/gone no longer exists" "$y" "7. a session whose folder is gone is named"
assert_absent "--resume bbbb-2222" "$y" "7. … and its pane opens a shell"

cat > "$ROOT/bin/opener" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/open.cap"
[ -n "\${STUB_RESUMES:-}" ] || exit 0
nohup "$ROOT/fakeclaude" >/dev/null 2>&1 & p=\$!
printf '{"pid":%s,"sessionId":"aaaa-1111","cwd":"/x","procStart":"%s","kind":"interactive","entrypoint":"cli","name":"a"}\n' "\$p" "\$(LC_ALL=C TZ=UTC0 ps -o lstart= -p \$p | sed 's/ *\$//')" > "$REG/\$p.json"
EOF
chmod +x "$ROOT/bin/opener"
out=$(WS_OPEN="$ROOT/bin/opener" WS_OPEN_WAIT=1 WS_BOOT_ID=boot2 python3 "$WS" restore "Alpha Session" 2>&1); rc=$?
assert_contains "warp://launch/warp-session-restore.yaml" "$(cat "$ROOT/open.cap" 2>/dev/null)" "8. opened by file name, the form Warp resolves"
assert_contains "--resume aaaa-1111" "$(cat "$LAUNCH/warp-session-restore.yaml" 2>/dev/null)" "8. the launch configuration is written where Warp reads it"
assert_eq 1 "$rc" "8. a session that never came back → exit 1"
assert_contains "not back yet: aaaa-1111" "$out" "8. … naming it, with the manual way"
out=$(STUB_RESUMES=1 WS_OPEN="$ROOT/bin/opener" WS_OPEN_WAIT=5 WS_BOOT_ID=boot2 python3 "$WS" restore "Alpha Session" 2>&1); rc=$?
assert_eq 0 "$rc" "8. every resumed session running again → exit 0"
assert_contains "restored" "$out" "8. … and says so"

rm -f "$ROOT/open.cap"
for f in "$REG"/*.json; do grep -q aaaa-1111 "$f" && { kill "$(basename "$f" .json)" 2>/dev/null; rm -f "$f"; }; done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["windows"][0]["tabs"][1]["layout"]["claude"]["cwd"]=sys.argv[2]; json.dump(d,open(sys.argv[1],"w"))' "$SNAPS/boot1.json" "$ROOT/proj/b"
y=$(STUB_WARP=1 WS_BOOT_ID=boot2 ws restore --dry-run)
assert_contains "opens in: the Warp window already open" "$y" "9. Warp running → restore opens in its window"
assert_contains '[[panes]]' "$y" "9. … as Tab Configs"
assert_absent 'tab_groups' "$y" "9. … which hold no tab group"
assert_contains "restore --window" "$y" "9. … and says how to get the groups back"
assert_contains 'split = "horizontal"' "$y" "9. a split keeps its direction"
assert_contains '"rm -f '"$ROOT"'/tabs/warp-session-restore-1.toml", "claude --resume aaaa-1111 -n '"'"'Alpha Session'"'"' --remote-control alpha --permission-mode auto"' "$y" "9. the tab deletes its Tab Config, then resumes in place"
assert_contains 'is_focused = true' "$y" "9. focused pane kept"
assert_contains 'color = "magenta"' "$y" "9. tab color kept"
reg $$ bbbb-2222 "$ROOT/proj/b" cli beta
y=$(STUB_WARP=1 WS_BOOT_ID=boot2 ws restore --dry-run)
assert_absent "warp-session-restore-2" "$y" "9. a tab with nothing to resume does not open in the running Warp"
rm -f "$REG/$$.json"
out=$(STUB_RESUMES=1 STUB_WARP=1 WS_OPEN="$ROOT/bin/opener" WS_OPEN_WAIT=5 WS_BOOT_ID=boot2 python3 "$WS" restore "Alpha Session" 2>&1); rc=$?
assert_eq "warp://tab_config/warp-session-restore-1" "$(cat "$ROOT/open.cap" 2>/dev/null)" "10. opened by name into the active window, nothing else"
assert_contains "--resume aaaa-1111" "$(cat "$ROOT/tabs/warp-session-restore-1.toml" 2>/dev/null)" "10. the Tab Config is written where Warp reads it"
assert_eq 0 "$rc" "10. its session running again → exit 0"
y=$(STUB_WARP=1 WS_BOOT_ID=boot2 ws restore --dry-run --window)
assert_contains '- name: "work"' "$y" "11. --window opens a new window, groups included"

kill "$PO" "$PD" 2>/dev/null
for f in "$REG"/*.json; do p="$(basename "$f" .json)"; [ "$p" = 999999 ] || kill "$p" 2>/dev/null; done
echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
