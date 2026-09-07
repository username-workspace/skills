#!/usr/bin/env bash
# rc-sessions.sh — list the Claude Code sessions registered on a machine with their peer name and
# their claude.ai ID (bridgeSessionId, shape session_01…), the one RemoteTrigger get_run_log expects.
#
# Source: ~/.claude/sessions/<pid>.json (one file per live claude process).
# Usage:
#   rc-sessions.sh                 # current machine
#   rc-sessions.sh --ssh build-box # remote machine (reads the files over ssh, BatchMode)
#   rc-sessions.sh --json          # raw JSON, one session per line
# Works in bash, Git Bash (Windows), macOS and Linux; no dependency (no jq).
# A session without bridgeSessionId is not connected to Remote Control. An entry can outlive a
# session killed abruptly: cross-check with ListAgents. Run it from a human shell or over SSH:
# the auto-mode classifier blocks Claude from reading this folder (it holds the socket .key tokens).
set -u
host=""; raw=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) host="${2:?missing host}"; shift 2 ;;
    --json) raw=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
reader='for f in "$HOME"/.claude/sessions/*.json; do [ -f "$f" ] && { cat "$f"; echo; }; done 2>/dev/null'
if [ -n "$host" ]; then
  data=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$reader")
else
  data=$(eval "$reader")
fi
if [ -z "$data" ]; then
  echo "no registered session${host:+ on $host} (~/.claude/sessions empty or unreadable)" >&2
  exit 1
fi
if [ "$raw" = 1 ]; then printf '%s\n' "$data"; exit 0; fi
field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
printf '%-22s %-34s %-12s %-16s %-8s %s\n' NAME CLAUDE_AI_ID KIND ENTRYPOINT VERSION CWD
printf '%s\n' "$data" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  name=$(field "$line" name); bid=$(field "$line" bridgeSessionId); kind=$(field "$line" kind)
  ep=$(field "$line" entrypoint); ver=$(field "$line" version); cwd=$(field "$line" cwd)
  printf '%-22s %-34s %-12s %-16s %-8s %s\n' "${name:-(unnamed)}" "${bid:-(not on Remote Control)}" \
    "${kind:-?}" "${ep:-?}" "${ver:-?}" "${cwd:-?}"
done
