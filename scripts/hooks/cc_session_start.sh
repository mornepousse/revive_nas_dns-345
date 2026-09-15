#!/usr/bin/env bash
# Hook Claude Code SessionStart — auto-installe les hooks git (une fois par clone)
# et rappelle la variante courante. Ne bloque jamais la session (exit 0).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 0
CTX=""
if [ "$(git config --get core.hooksPath 2>/dev/null)" != "scripts/hooks" ]; then
  if git config core.hooksPath scripts/hooks 2>/dev/null; then
    CTX="tripwire: hooks git installés (core.hooksPath=scripts/hooks)."
  else
    CTX="tripwire: installation des hooks git impossible — lancer ./scripts/install-hooks.sh."
  fi
fi
[ -z "$CTX" ] && exit 0
# Forme documentée : additionalContext en JSON ; repli texte brut sans python3.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}, ensure_ascii=False))' "$CTX"
else
  printf '%s\n' "$CTX"
fi
exit 0
