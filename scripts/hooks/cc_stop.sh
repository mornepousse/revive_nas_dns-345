#!/usr/bin/env bash
# Hook Claude Code Stop — garde-fou léger : check.sh --fast (~1 s) avant de conclure.
# Le build/e2e complet n'est PAS lancé ici (pas à chaque fin de tour) : il reste
# garanti au pre-push git. Rouge fast -> bloque la conclusion et remonte le détail.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1
# python3 requis pour la garde anti-boucle ; sans lui le hook est inactif (signalé).
command -v python3 >/dev/null 2>&1 || { echo "tripwire: python3 absent, hook Stop inactif" >&2; exit 0; }
# Anti-boucle : si on est déjà dans une continuation de Stop hook, ne pas re-bloquer.
IN="$(cat 2>/dev/null || true)"
printf '%s' "$IN" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("stop_hook_active") else 1)' 2>/dev/null && exit 0
OUT="$("$REPO/scripts/check.sh" --fast 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "check.sh --fast est ROUGE avant de conclure (le build/e2e complet tourne au pre-push) :" >&2
  echo "$OUT" | tail -10 >&2
  exit 2
fi
exit 0
