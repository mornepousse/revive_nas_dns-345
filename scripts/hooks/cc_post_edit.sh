#!/usr/bin/env bash
# Hook Claude Code PostToolUse — tests rapides après édition d'un fichier surveillé.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1
# python3 requis pour parser le JSON du hook ; sans lui le hook est inactif (signalé).
command -v python3 >/dev/null 2>&1 || { echo "tripwire: python3 absent, hook PostToolUse inactif" >&2; exit 0; }
FP="$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)"
case "$FP" in
  *"/scripts/"*|*"/test/"*|*"/tftp/"*|*".dts"|*"/README.md") ;;
  *) exit 0 ;;  # fichier non surveillé → rien
esac
# Debounce : pas de re-check si le dernier date de moins de TRIPWIRE_DEBOUNCE s (défaut 10).
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
DB="${TRIPWIRE_DEBOUNCE:-10}"
if [ "$DB" -gt 0 ]; then
  NOW="$(date +%s)"; LASTT="$(cat "$GITDIR/tripwire/last-postedit" 2>/dev/null || echo 0)"
  [ $((NOW - LASTT)) -lt "$DB" ] && exit 0
  mkdir -p "$GITDIR/tripwire" 2>/dev/null; printf '%s' "$NOW" > "$GITDIR/tripwire/last-postedit" 2>/dev/null
fi
OUT="$("$REPO/scripts/check.sh" --fast --changed "$FP" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "Régression phase rapide après édition de $FP :" >&2
  echo "$OUT" | tail -8 >&2
  exit 2   # remonte à Claude
fi
# Garde anti-affaiblissement : perte nette d'assertions vs HEAD dans un test ?
case "$FP" in
  *"/test/"*)
    REL="${FP#"$REPO"/}"
    NOLD="$(git show "HEAD:$REL" 2>/dev/null | grep -cE '^[[:space:]]*(pass|fail|warn) ')"
    NNEW="$(grep -cE '^[[:space:]]*(pass|fail|warn) ' "$FP" 2>/dev/null)"
    if git cat-file -e "HEAD:$REL" 2>/dev/null && [ "$NOLD" -gt "$NNEW" ] 2>/dev/null; then
      python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":sys.argv[1]}}, ensure_ascii=False))' \
        "tripwire: $((NOLD-NNEW)) assertion(s) en moins dans $REL vs HEAD — refactor légitime ou affaiblissement ? Rétablir ou justifier."
    fi
    ;;
esac
exit 0
