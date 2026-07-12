#!/usr/bin/env bash
# claude-remote-spawn — driver.sh (terminal-agnostic, cross-platform: macOS + Linux)
# spawn = a PERSISTENT, VISIBLE Claude Code session: `claude --remote-control <name>` run in a
#   PTY via script(1), so it shows up in `claude agents` + Remote Control (phone/desktop) and
#   stays alive until `stop`. Same pattern a persistent launchd/systemd KeepAlive service uses.
# Permissions: default "--permission-mode auto"; CRS_HEADLESS_DANGEROUS=1 -> --dangerously-skip-permissions;
#   CRS_HEADLESS_PERM_FLAGS overrides with an exact value (incl. "").
set -euo pipefail

CLAUDE_BIN="${CRS_CLAUDE_BIN:-$HOME/.local/bin/claude}"
STATE_DIR="${CRS_HEADLESS_STATE:-$HOME/.claude/headless}"
if   [ -n "${CRS_HEADLESS_PERM_FLAGS+set}" ]; then PERM="$CRS_HEADLESS_PERM_FLAGS"
elif [ -n "${CRS_HEADLESS_DANGEROUS:-}" ];    then PERM="--dangerously-skip-permissions"
else PERM="--permission-mode auto"; fi
mkdir -p "$STATE_DIR"

die(){ echo "x $*" >&2; exit 1; }
need_claude(){ [ -n "$CLAUDE" ] || die "claude not found (set CRS_CLAUDE_BIN)"; }
need_script(){ command -v script >/dev/null 2>&1 || die "script(1) not found"; }
spawn_get(){ sed -n "s/^$2=//p" "$STATE_DIR/$1.spawn" 2>/dev/null | head -1; }
is_running(){ [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
# liveness = the real PTY/claude process, NOT the wrapper subshell: the subshell is kept alive by
# session_stdin's immortal `tail -f /dev/null`, so it would always look "live". Trailing space anchors
# the name (launch always passes args after it) so 'alpha' ≠ 'alphabet'.
session_alive(){ pgrep -f "remote-control $1 " >/dev/null 2>&1; }

if   [ -x "$CLAUDE_BIN" ];               then CLAUDE="$CLAUDE_BIN"
elif command -v claude >/dev/null 2>&1;  then CLAUDE="claude"
else CLAUDE=""; fi

# Feeds claude's stdin: keeps it open (tail), and auto-answers the "resume from summary?" startup
# prompt so an unattended session never hangs. Only acts if the prompt actually appears (a normal
# spawn is unaffected). "2" = resume the full session as-is, preserving context.
session_stdin(){
  local log="$1" i=0
  until grep -aq "Resume from summary" "$log" 2>/dev/null || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
  grep -aq "Resume from summary" "$log" 2>/dev/null && printf '2\r'
  tail -f /dev/null
}

# Launch a persistent Remote-Control session in a PTY; extra args ($3+) go to claude (e.g. --resume). Shared by spawn/resume.
launch_session(){
  local name="$1" cwd="$2"; shift 2
  local log="$STATE_DIR/$name.log"
  cd "$cwd" || die "cannot cd to $cwd"
  # set -m puts the backgrounded subshell in its own process group (pgid == leader pid == $!), so
  # `stop` can kill the WHOLE tree — the immortal `tail -f /dev/null` included — with one signal.
  set -m
  case "$(uname -s)" in
    Darwin) ( export TERM=xterm-256color; session_stdin "$log" | script -q "$log" "$CLAUDE" --remote-control "$name" "$@" $PERM ) >/dev/null 2>&1 & ;;
    Linux)  local cmd; printf -v cmd '%q ' "$CLAUDE" --remote-control "$name" "$@" $PERM
            ( export TERM=xterm-256color; session_stdin "$log" | script -qec "$cmd" "$log" ) >/dev/null 2>&1 & ;;
    *)      set +m; die "unsupported OS $(uname -s)" ;;
  esac
  local leader=$!
  set +m
  printf 'name=%s\ncwd=%s\nstarted=%s\nsubshell=%s\npgid=%s\n' "$name" "$cwd" "$(date -u +%FT%TZ)" "$leader" "$leader" >"$STATE_DIR/$name.spawn"
}

slugify(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//' | cut -c1-48 | sed 's/-*$//'; }
nato_name(){
  for w in alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike \
           november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu; do
    [ -e "$STATE_DIR/$w.spawn" ] || { echo "$w"; return; }
  done
  echo "claude-$(date +%H%M%S)"
}

# osascript wants the launcher path as an AppleScript string literal — escape \ and " (default paths are
# clean, but CRS_HEADLESS_STATE could carry either).
osa_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Open `launcher` in a NEW tab of the terminal that launched the skill. Returns 2 for a terminal we can't
# script, 3 when osascript is absent — the caller then tells the user to run the launcher themselves.
open_terminal_tab(){
  local launcher="$1" esc; esc="$(osa_escape "$launcher")"
  command -v osascript >/dev/null 2>&1 || return 3
  case "${TERM_PROGRAM:-}" in
    iTerm.app)
      osascript >/dev/null 2>&1 <<OSA
tell application "iTerm"
  if (count of windows) = 0 then
    create window with default profile command "$esc"
  else
    tell current window to create tab with default profile command "$esc"
  end if
  activate
end tell
OSA
      ;;
    Apple_Terminal)
      osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "$esc"
end tell
OSA
      ;;
    *) return 2 ;;
  esac
}

usage(){ cat >&2 <<EOF
usage: driver.sh [open|spawn|resume|list|stop|check] [args]   (subcommand omitted → 'open')
  open  [name] [--model M] [--prompt 'text']  DEFAULT — launch a session in a NEW LOCAL terminal tab (iTerm/Terminal.app); ephemeral — close the tab to stop
  spawn [name] [--model M] [--prompt 'text']  launch a DETACHED, persistent session (Remote Control + phone), survives until 'stop'
  resume <id> [name] [--in-place] [--model M]  respawn an existing session by id (forks a fresh id; --in-place=same id)
  list                     list spawned sessions (live/dead)
  stop <name>              stop a session
  check                    health (claude, script, perms, models, remote-control, terminal, sessions)
spawn/resume run 'claude --remote-control <name> [--resume <id>]' in a PTY (script) so the session
stays visible & drivable from your phone/desktop. --model takes any value your 'claude' accepts (an
alias like opus/sonnet/fable, or a full id like claude-fable-5); it is passed straight to
'claude --model' and validated there — nothing is hardcoded. To resume from a description, get the id
with find-session, then 'resume <id>'. 'open' instead runs the session in a real LOCAL terminal tab
(macOS: iTerm.app/Apple_Terminal via osascript) with no detach engine — so it's visible & interactive
where you launched it, but closing the tab ends it (no phone-driving after that).
cwd MUST be a TRUSTED folder (default \$PWD; override CRS_SPAWN_CWD).
env: CRS_CLAUDE_BIN, CRS_HEADLESS_STATE, CRS_SPAWN_CWD,
     CRS_HEADLESS_DANGEROUS, CRS_HEADLESS_PERM_FLAGS
EOF
exit 2; }

# 'open' is the default subcommand: a bare invocation, or a first token that
# isn't a known subcommand/help flag (i.e. a session name or a flag), runs
# 'open' with the original args preserved.
case "${1:-}" in
  spawn|open|resume|list|stop|check|close-tab) cmd="$1"; shift ;;
  -h|--help)                                   cmd="$1"; shift ;;
  *)                                           cmd="open" ;;
esac
case "$cmd" in
  spawn)
    need_claude; need_script
    name=""; model=""; prompt=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model)    [ -n "${2:-}" ] || die "--model needs a value (an alias like opus/sonnet/fable, or a full model id)"; model="$2"; shift 2 ;;
        --model=*)  model="${1#--model=}"; shift ;;
        --prompt)   [ -n "${2:-}" ] || die "--prompt needs a value (the initial instruction submitted to the session)"; prompt="$2"; shift 2 ;;
        --prompt=*) prompt="${1#--prompt=}"; shift ;;
        -*)         die "unknown flag: $1" ;;
        *)          [ -z "$name" ] && name="$1"; shift ;;
      esac
    done
    # names become file paths and pkill patterns — only ever use the slugified form
    name="${name:+$(slugify "$name")}"
    [ -n "$name" ] || name="$(nato_name)"
    [ -e "$STATE_DIR/$name.spawn" ] && die "session '$name' already exists (stop it first)"
    cwd="${CRS_SPAWN_CWD:-$PWD}"
    model_args=(); [ -n "$model" ] && model_args=(--model "$model")
    prompt_args=(); [ -n "$prompt" ] && prompt_args=("$prompt")
    launch_session "$name" "$cwd" -n "$name" ${model_args[@]+"${model_args[@]}"} ${prompt_args[@]+"${prompt_args[@]}"}
    [ -n "$model" ] && echo "model=$model" >>"$STATE_DIR/$name.spawn"
    echo "$name"
    echo "spawned '$name'${model:+ (model: $model)} in $cwd — visible in Claude Code Remote Control (phone/desktop) + 'claude agents'. (cwd must be TRUSTED.)" >&2
    ;;
  open)
    need_claude
    name=""; model=""; prompt=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model)    [ -n "${2:-}" ] || die "--model needs a value (an alias like opus/sonnet/fable, or a full model id)"; model="$2"; shift 2 ;;
        --model=*)  model="${1#--model=}"; shift ;;
        --prompt)   [ -n "${2:-}" ] || die "--prompt needs a value (the initial instruction submitted to the session)"; prompt="$2"; shift 2 ;;
        --prompt=*) prompt="${1#--prompt=}"; shift ;;
        -*)         die "unknown flag: $1" ;;
        *)          [ -z "$name" ] && name="$1"; shift ;;
      esac
    done
    # names become file paths and AppleScript args — only ever use the slugified form
    name="${name:+$(slugify "$name")}"
    [ -n "$name" ] || name="$(nato_name)"
    [ -e "$STATE_DIR/$name.spawn" ] && die "session '$name' already exists (stop it first)"
    cwd="${CRS_SPAWN_CWD:-$PWD}"
    launcher="$STATE_DIR/$name.cmd"
    self="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
    # the launcher is what the terminal tab runs; %q makes the claude argv injection-proof. PERM is a
    # pre-split flag string (maybe empty) — written raw on purpose so the tab's shell re-splits it.
    # NOT exec: the launcher must regain control when claude ends (stop/exit/crash) to close its own
    # tab via 'close-tab', so no dead session lingers — that's the cleanup 'stop' alone can't do.
    {
      printf '#!/usr/bin/env bash\n'
      printf 'cd %q || exit 1\n' "$cwd"
      printf '%q --remote-control %q -n %q' "$CLAUDE" "$name" "$name"
      [ -n "$model" ]  && printf ' --model %q' "$model"
      [ -n "$prompt" ] && printf ' %q' "$prompt"
      printf ' %s\n' "$PERM"
      printf 'rc=$?\n'
      printf '%q close-tab >/dev/null 2>&1 || true\n' "$self"
      printf 'exit "$rc"\n'
    } >"$launcher"
    chmod +x "$launcher"
    rc=0; open_terminal_tab "$launcher" || rc=$?
    case "$rc" in
      0) ;;
      2) rm -f "$STATE_DIR/$name.spawn"; die "open: terminal '${TERM_PROGRAM:-unknown}' isn't auto-openable — run it yourself in any terminal: $launcher" ;;
      3) rm -f "$STATE_DIR/$name.spawn"; die "open: osascript not found (macOS-only auto-open) — run it yourself in any terminal: $launcher" ;;
      *) rm -f "$STATE_DIR/$name.spawn"; die "open: could not open a terminal tab (osascript exit $rc) — run it yourself: $launcher" ;;
    esac
    printf 'name=%s\ncwd=%s\nstarted=%s\nmode=window\n' "$name" "$cwd" "$(date -u +%FT%TZ)" >"$STATE_DIR/$name.spawn"
    [ -n "$model" ] && echo "model=$model" >>"$STATE_DIR/$name.spawn"
    echo "$name"
    echo "opened '$name'${model:+ (model: $model)} in a new terminal tab (cwd: $cwd) — live & Remote-Control-drivable while the tab stays open; 'stop $name' or closing the tab ends it (the tab then closes itself). (cwd must be TRUSTED.)" >&2
    ;;
  resume)
    need_claude; need_script
    id=""; name=""; fork="--fork-session"; model=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --in-place|--no-fork) fork=""; shift ;;
        --fork)               fork="--fork-session"; shift ;;
        --model)   [ -n "${2:-}" ] || die "--model needs a value (an alias like opus/sonnet/fable, or a full model id)"; model="$2"; shift 2 ;;
        --model=*) model="${1#--model=}"; shift ;;
        -*)                   die "unknown flag: $1" ;;
        *)                    if [ -z "$id" ]; then id="$1"; elif [ -z "$name" ]; then name="$1"; fi; shift ;;
      esac
    done
    [ -n "$id" ] || die "resume needs a <session-id> (use find-session to resolve one from a description)"
    projects="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    tx="$(find "$projects" -maxdepth 2 -name "$id.jsonl" 2>/dev/null | head -1)"
    [ -n "$tx" ] || die "no transcript for session '$id' under $projects (check the id)"
    # recover Claude Code's own session title (last ai-title) so the resume is recognizable, not random
    # `|| true`: a grep miss must fall through to the fallbacks, not errexit under pipefail
    title="$(grep -o '"aiTitle": *"[^"]*"' "$tx" | tail -1 | sed 's/.*"aiTitle": *"//; s/"$//' || true)"
    display="${name:-${title:-resumed session}}"
    # names become file paths and pkill patterns — only ever use the slugified form
    name="$(slugify "${name:-$title}")"
    [ -n "$name" ] || name="$(nato_name)"
    [ -e "$STATE_DIR/$name.spawn" ] && die "session '$name' already exists (stop it first)"
    rcwd="$(grep -m1 -o '"cwd":"[^"]*"' "$tx" | sed 's/^"cwd":"//; s/"$//' || true)"
    cwd="${CRS_SPAWN_CWD:-${rcwd:-$PWD}}"
    [ -d "$cwd" ] || die "session cwd '$cwd' not found (override with CRS_SPAWN_CWD)"
    model_args=(); [ -n "$model" ] && model_args=(--model "$model")
    launch_session "$name" "$cwd" --resume "$id" -n "$display" $fork ${model_args[@]+"${model_args[@]}"}
    { echo "resumed=$id"; echo "title=$display"; [ -n "$model" ] && echo "model=$model"; } >>"$STATE_DIR/$name.spawn"
    mode=$([ -n "$fork" ] && echo "new forked id" || echo "in-place, same id")
    echo "$name"
    echo "resumed $id as '$display' (handle: $name) in $cwd — Remote Control + 'claude agents' ($mode)." >&2
    ;;
  list)
    shopt -s nullglob; spawns=("$STATE_DIR"/*.spawn)
    if [ ${#spawns[@]} -eq 0 ]; then echo "(no sessions)"; exit 0; fi
    for s in "${spawns[@]}"; do
      n="$(basename "$s" .spawn)"
      state="dead"; if session_alive "$n"; then state="live"; fi
      ri="$(spawn_get "$n" resumed)"; ri="${ri:+  resumed=$ri}"
      mi="$(spawn_get "$n" model)"; mi="${mi:+  model=$mi}"
      wi="$(spawn_get "$n" mode)"; wi="${wi:+  $wi}"
      printf '%-22s %-6s started=%s  cwd=%s%s%s%s\n' "$n" "$state" "$(spawn_get "$n" started)" "$(spawn_get "$n" cwd)" "$ri" "$mi" "$wi"
    done
    ;;
  stop)
    name="$(slugify "${1:-}")"; [ -n "$name" ] || die "stop needs a <name>"
    [ -f "$STATE_DIR/$name.spawn" ] || die "no session $name"
    pgid="$(spawn_get "$name" pgid)"
    if [ -n "$pgid" ]; then
      kill -- -"$pgid" 2>/dev/null || true          # whole process group: subshell, script/claude, the tail
    else                                              # pre-pgid .spawn: best-effort fallback
      sp="$(spawn_get "$name" subshell)"
      if is_running "$sp"; then pkill -P "$sp" 2>/dev/null || true; kill "$sp" 2>/dev/null || true; fi
    fi
    # trailing space anchors the name (launch always passes args after it) so 'alpha' ≠ 'alphabet'
    pkill -f "remote-control $name " 2>/dev/null || true
    rm -f "$STATE_DIR/$name.spawn" "$STATE_DIR/$name.log" "$STATE_DIR/$name.cmd"
    echo "stopped $name"
    ;;
  check)
    echo "claude : $([ -n "$CLAUDE" ] && "$CLAUDE" --version 2>/dev/null || echo 'NOT FOUND')"
    echo "script : $(command -v script >/dev/null 2>&1 && echo ok || echo 'NOT FOUND')"
    echo "perms  : $PERM"
    mh="$({ "$CLAUDE" --help 2>/dev/null | grep -aA3 -- '--model <model>' | tr '\n' ' ' | tr -s ' ' | sed 's/.*--model <model> *//'; } 2>/dev/null || true)"
    echo "model  : 'spawn --model <alias|id>' — passed to 'claude --model', validated there. ${mh:-run 'claude --help' for current aliases}"
    echo "term   : TERM_PROGRAM=${TERM_PROGRAM:-<unset>} — 'open' auto-opens a tab in iTerm.app/Apple_Terminal via osascript ($(command -v osascript >/dev/null 2>&1 && echo present || echo MISSING))"
    if grep -q '"remoteControlAtStartup": *true' "$HOME/.claude/settings.json" 2>/dev/null; then
      echo "remote : remoteControlAtStartup=true (every session is Remote-Control-visible)"
    else
      echo "remote : remoteControlAtStartup off — spawn still forces --remote-control <name>"
    fi
    shopt -s nullglob; spawns=("$STATE_DIR"/*.spawn)
    echo "spawns : ${#spawns[@]} session(s)"
    ;;
  close-tab)
    # called by an 'open' launcher when its session ends — closes the launcher's OWN tab (read from the
    # tab's env), so a stopped/exited window session leaves no dead tab. Best-effort, always exits 0.
    command -v osascript >/dev/null 2>&1 || exit 0
    case "${TERM_PROGRAM:-}" in
      iTerm.app)
        guid="${ITERM_SESSION_ID:-}"; guid="${guid##*:}"; [ -n "$guid" ] || exit 0
        osascript >/dev/null 2>&1 <<OSA || true
tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if id of s is "$guid" then close s
      end repeat
    end repeat
  end repeat
end tell
OSA
        ;;
      Apple_Terminal)
        mytty="$(tty 2>/dev/null)"; [ -n "$mytty" ] && [ "$mytty" != "not a tty" ] || exit 0
        osascript >/dev/null 2>&1 <<OSA || true
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$mytty" then close w saving no
    end repeat
  end repeat
end tell
OSA
        ;;
    esac
    exit 0
    ;;
  ""|-h|--help) usage ;;
  *) die "unknown subcommand: $cmd (see --help)";;
esac
