#!/usr/bin/env bash
# Active les hooks git versionnés du repo (pre-push -> scripts/check.sh).
# À lancer une fois par clone : ./scripts/install-hooks.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
git config core.hooksPath scripts/hooks
echo "✓ core.hooksPath = $(git config --get core.hooksPath)"
echo "  pre-push lancera scripts/check.sh (full). WIP: git push --no-verify"
