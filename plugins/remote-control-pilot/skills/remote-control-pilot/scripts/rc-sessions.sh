#!/usr/bin/env bash
# rc-sessions.sh — liste les sessions Claude Code enregistrées sur une machine avec leur nom de pair
# et leur ID claude.ai (bridgeSessionId, format session_01…), celui qu'attend RemoteTrigger get_run_log.
#
# Source : ~/.claude/sessions/<pid>.json (un fichier par processus claude vivant).
# Usage :
#   rc-sessions.sh                 # machine courante
#   rc-sessions.sh --ssh macstudio # machine distante (lit les fichiers via ssh, BatchMode)
#   rc-sessions.sh --json          # JSON brut, une session par ligne
# Fonctionne en bash, Git Bash (Windows) et sur macOS/Linux ; aucune dépendance (pas de jq).
# Une session sans bridgeSessionId n'est pas connectée en Remote Control. Une entrée peut
# survivre à une session tuée brutalement : recouper avec ListAgents.
set -u
host=""; raw=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) host="${2:?hote manquant}"; shift 2 ;;
    --json) raw=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done
reader='for f in "$HOME"/.claude/sessions/*.json; do [ -f "$f" ] && { cat "$f"; echo; }; done 2>/dev/null'
if [ -n "$host" ]; then
  data=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$reader")
else
  data=$(eval "$reader")
fi
if [ -z "$data" ]; then
  echo "aucune session enregistree${host:+ sur $host} (~/.claude/sessions vide ou inaccessible)" >&2
  exit 1
fi
if [ "$raw" = 1 ]; then printf '%s\n' "$data"; exit 0; fi
field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
printf '%-22s %-34s %-12s %-16s %-8s %s\n' NOM ID_CLAUDE_AI KIND ENTRYPOINT VERSION CWD
printf '%s\n' "$data" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  name=$(field "$line" name); bid=$(field "$line" bridgeSessionId); kind=$(field "$line" kind)
  ep=$(field "$line" entrypoint); ver=$(field "$line" version); cwd=$(field "$line" cwd)
  printf '%-22s %-34s %-12s %-16s %-8s %s\n' "${name:-(sans nom)}" "${bid:-(pas en Remote Control)}" \
    "${kind:-?}" "${ep:-?}" "${ver:-?}" "${cwd:-?}"
done
