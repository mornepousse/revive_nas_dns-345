#!/usr/bin/env bash
# tripwire-template: v0.11.0
# Tripwire anti-régression nas_dns-345 — source unique de vérité du "quoi vérifier".
# Généré par /tripwire:init. Adapter ICI ; les hooks ne font qu'appeler ce script.
# Modes:
#   check.sh                  -> full: phase rapide + toutes les variantes
#   check.sh --fast           -> phase rapide uniquement (~secondes)
#   check.sh --variant <name> -> phase rapide + une seule variante
# Options:
#   --changed <fichier>       -> (passé par les hooks) route la phase rapide sur le
#                                module touché si MODULE_FAST est renseigné
#   --force                   -> ignore le skip-si-déjà-vert (aussi: TRIPWIRE_FORCE=1)
# Env:
#   TRIPWIRE_FAST_BUDGET      -> budget de la phase rapide en secondes (défaut 30) ;
#                                dépassé -> avertissement non fatal
# Sortie non-zéro si au moins un rouge (toutes les variantes sont tentées en mode full).
# Conçu pour hooks git/plateforme + CI.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR" || exit 1

# Variantes de build. Laisser vide pour un projet mono-cible.
ALL_VARIANTS=()

# Modules (monorepo, optionnel) : quand un hook passe --changed <fichier>, la
# phase rapide est routée sur le premier module dont le glob matche. Sans match
# ou table vide : phase rapide globale. Format "<glob>:<commande>". Exemple :
#   MODULE_FAST=( "*/services/api/*:cd services/api && npm test -s" )
MODULE_FAST=()

# Ratchet de tests (optionnel) : commande une-ligne qui imprime le nombre de
# tests. Vide -> ratchet inerte. Référence committée : .tripwire-testcount
# (la baisser = diff visible en review). Rouge au pre-push si le compte chute
# (TRIPWIRE_RATCHET_STRICT=1, posé par le hook pre-push).
TEST_COUNT_CMD="grep -hoE '^[[:space:]]*(pass|fail|warn) ' test/run_tests.sh | wc -l"

# Avis TDD (optionnel) : formes grep -E des chemins source et test. Vides -> inerte.
SRC_GREP="^scripts/|^tftp/|^boot/"
TEST_GREP="^test/"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
fail() { echo "${RED}✗ $*${NC}" >&2; }
ok()   { echo "${GREEN}✓ $*${NC}"; }
info() { echo "${YEL}» $*${NC}"; }

MODE="full"; SINGLE_VARIANT=""; CHANGED=""; FORCE="${TRIPWIRE_FORCE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --fast)    MODE="fast" ;;
    --variant) MODE="single"; SINGLE_VARIANT="${2:-}"
               [ -z "$SINGLE_VARIANT" ] && { fail "--variant requires a name"; exit 2; }
               shift ;;
    --changed) CHANGED="${2:-}"; shift ;;
    --force)   FORCE=1 ;;
    *)         fail "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# ---- Résolution du scope de la phase rapide (module éventuel) ----
FAST_RUN_CMD="bash test/host_checks.sh"; FAST_LABEL="Phase rapide"; SCOPE_KEY=""
if [ -n "$CHANGED" ]; then
  for _e in ${MODULE_FAST[@]+"${MODULE_FAST[@]}"}; do
    # Divergence locale (voir .tripwire-divergences) : SC2254 est un faux positif
    # ici, le motif de MODULE_FAST DOIT être interprété comme un glob.
    # shellcheck disable=SC2254
    case "$CHANGED" in
      ${_e%%:*}) FAST_RUN_CMD="${_e#*:}"; FAST_LABEL="Module ${_e%%:*}"
                 SCOPE_KEY="-mod-$(printf '%s' "${_e%%:*}" | git hash-object --stdin 2>/dev/null | cut -c1-8)"
                 break ;;
    esac
  done
fi

# ---- Verrou : un seul check à la fois (hooks concurrents) ----
GITDIR="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
mkdir -p "$GITDIR/tripwire" 2>/dev/null || true
if command -v flock >/dev/null 2>&1 && [ -d "$GITDIR/tripwire" ]; then
  exec 9>"$GITDIR/tripwire/lock"
  if ! flock -n 9 2>/dev/null; then
    info "un check est déjà en cours — skip (son verdict fera foi)"
    exit 0
  fi
fi

# ---- Capture d'échec : la sortie du dernier rouge reste lisible sans re-run ----
OUTBUF="$GITDIR/tripwire/.out.$$"
trap 'rm -f "$OUTBUF"' EXIT
capture_fail() { # $1=label $2=commande affichée ; la sortie est déjà dans $OUTBUF
  {
    printf '# cmd: %s\n# mode: %s\n' "$2" "$1"
    tail -200 "$OUTBUF" 2>/dev/null
  } > "$GITDIR/tripwire/last-fail.log" 2>/dev/null || true
}

# ---- Skip-si-déjà-vert : même état que le dernier vert -> rien à refaire ----
fingerprint() {
  {
    git rev-parse HEAD 2>/dev/null || echo no-head
    git diff HEAD 2>/dev/null || git diff 2>/dev/null || true
    git ls-files -o --exclude-standard 2>/dev/null | LC_ALL=C sort \
      | git hash-object --stdin-paths 2>/dev/null || true
  } | git hash-object --stdin 2>/dev/null || date +%s.%N
}
KEY="$MODE${SINGLE_VARIANT:+-$SINGLE_VARIANT}$SCOPE_KEY"
[ "${TRIPWIRE_RATCHET_STRICT:-0}" = "1" ] && KEY="$KEY-strict"   # un run strict ne skippe que contre un vert strict
STAMP="$GITDIR/tripwire/green-$KEY"
FP="$(fingerprint)"
if [ "$FORCE" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$FP" ]; then
  ok "déjà vert (état inchangé depuis le dernier passage) — skip (--force pour relancer)"
  exit 0
fi

T_START=$SECONDS

# ---- Divergences déclarées : un écart assumé ne disparaît pas en silence ----
# .tripwire-divergences (committé), TSV : fichier<TAB>motif<TAB>pourquoi
# Absent/vide -> inerte. Motif comparé en chaîne littérale, jamais en regex.
# NOTE: cette fonction est dupliquée entre skills/init/templates/check.sh.tmpl
# et scripts/check.sh (dogfood). Duplication assumée : un check.sh scaffoldé est
# copié dans d'autres repos, il doit être autonome et ne rien sourcer du plugin.
# Toute correction ici se reporte à l'identique dans l'autre fichier.
check_divergences() {
  [ -f .tripwire-divergences ] || return 0
  if [ ! -r .tripwire-divergences ]; then
    fail "divergences : .tripwire-divergences illisible (droits ?) — une fiche illisible n'est pas une fiche vide"
    return 1
  fi
  local rc=0 n=0 line f rest m w
  # Découpage explicite : la tabulation est un caractère IFS-whitespace, un
  # `IFS=$'	' read` fusionnerait les tabs consécutives et décalerait les champs.
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$''}"                                     # fiche en CRLF
    case "$line" in ''|'#'*) continue ;; esac
    f="${line%%$'	'*}"
    rest="${line#*$'	'}"; [ "$rest" = "$line" ] && rest=""  # aucune tabulation
    m="${rest%%$'	'*}"
    w="${rest#*$'	'}"; [ "$w" = "$rest" ] && w=""
    if [ -z "$f" ] || [ -z "$m" ]; then
      fail "divergence ligne $n : ligne malformée (attendu: fichier<TAB>motif<TAB>pourquoi)"
      rc=1; continue
    fi
    if [ ! -f "$f" ]; then
      fail "divergence perdue : $f n'existe plus (motif « $m »)"
      [ -n "$w" ] && echo "  motif déclaré : $w" >&2
      echo "  → rétablir la divergence, ou retirer sa ligne de .tripwire-divergences" >&2
      echo "    si l'abandon est voulu (le retrait part dans le diff, il sera vu en review)." >&2
      rc=1; continue
    fi
    if ! grep -qF -- "$m" "$f"; then
      fail "divergence perdue : $f ne contient plus « $m »"
      [ -n "$w" ] && echo "  motif déclaré : $w" >&2
      echo "  → rétablir la divergence, ou retirer sa ligne de .tripwire-divergences" >&2
      echo "    si l'abandon est voulu (le retrait part dans le diff, il sera vu en review)." >&2
      rc=1
    fi
  done < .tripwire-divergences
  return "$rc"
}

# ---- Phase rapide (boucle courte, budget TRIPWIRE_FAST_BUDGET s) ----
run_fast() {
  info "${FAST_LABEL}…"
  local t0=$SECONDS rc=0
  if ( eval "$FAST_RUN_CMD" ) >"$OUTBUF" 2>&1; then
    ok "$FAST_LABEL OK"
  else
    capture_fail "$FAST_LABEL" "$FAST_RUN_CMD"
    fail "$FAST_LABEL: échec — détail: $GITDIR/tripwire/last-fail.log (ou relance: $FAST_RUN_CMD)"
    rc=1
  fi
  local dt=$((SECONDS - t0)) budget="${TRIPWIRE_FAST_BUDGET:-30}"
  if [ "$dt" -gt "$budget" ]; then
    info "⚠ phase rapide: ${dt}s > budget ${budget}s — déplacer des tests vers le check complet ou scoper par module (MODULE_FAST)"
  fi
  return "$rc"
}

# ---- Phase complète ----
# Multi-variantes: appelée une fois par variante ($v = nom).
# Mono-cible: appelée une fois avec $v vide.
build_variant() {
  local v="$1"
  info "Build ${v:-complet}…"
  if ( bash test/host_checks.sh --strict ) >"$OUTBUF" 2>&1; then
    ok "Build ${v:-complet} OK"
    return 0
  else
    capture_fail "Build ${v:-complet}" "bash test/host_checks.sh --strict"
    fail "Build ${v:-complet}: échec — détail: $GITDIR/tripwire/last-fail.log (ou relance: bash test/host_checks.sh --strict)"
    return 1
  fi
}

rc=0
check_divergences || rc=1
run_fast || rc=1

if [ "$MODE" = "single" ]; then
  build_variant "$SINGLE_VARIANT" || rc=1
elif [ "$MODE" = "full" ]; then
  if [ "${#ALL_VARIANTS[@]}" -eq 0 ]; then
    build_variant "" || rc=1
  else
    for v in "${ALL_VARIANTS[@]}"; do
      build_variant "$v" || rc=1
    done
  fi
fi

# ---- Ratchet de tests : le nombre de tests ne baisse jamais en silence ----
if [ -n "$TEST_COUNT_CMD" ]; then
  TC="$( (eval "$TEST_COUNT_CMD") 2>/dev/null | tr -d '[:space:]' )"
  case "$TC" in ''|*[!0-9]*) TC="" ;; esac
  REF="$(cat .tripwire-testcount 2>/dev/null | tr -d '[:space:]')"
  case "$REF" in ''|*[!0-9]*) REF="" ;; esac
  if [ -n "$TC" ]; then
    if [ -z "$REF" ]; then
      printf '%s\n' "$TC" > .tripwire-testcount 2>/dev/null \
        && info "ratchet: référence initialisée à $TC tests (.tripwire-testcount — à committer)"
    elif [ "$TC" -gt "$REF" ]; then
      printf '%s\n' "$TC" > .tripwire-testcount 2>/dev/null \
        && info "ratchet: $REF -> $TC tests (.tripwire-testcount mis à jour — à committer)"
    elif [ "$TC" -lt "$REF" ]; then
      if [ "${TRIPWIRE_RATCHET_STRICT:-0}" = "1" ]; then
        fail "ratchet: $TC tests, référence $REF — des tests ont disparu (baisse assumée ? mettre à jour .tripwire-testcount dans un commit)"
        rc=1
      else
        info "⚠ ratchet: $TC tests vs $REF attendus — des tests ont disparu ?"
      fi
    fi
  fi
fi

echo "========================================"
if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$FP" > "$STAMP" 2>/dev/null || true
  ok "check.sh: tout vert"
else
  fail "check.sh: ROUGE"
fi
# Historique des durées (jamais bloquant) — les skips sortent avant ce point.
{
  HIST="$GITDIR/tripwire/history.tsv"
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$KEY" "$((SECONDS - T_START))" "$rc" >> "$HIST"
  if [ "$(wc -l < "$HIST")" -gt 500 ]; then
    { tail -500 "$HIST" > "$HIST.$$" && mv "$HIST.$$" "$HIST"; } || rm -f "$HIST.$$"
  fi
} 2>/dev/null || true

# Avis TDD : du source modifié sans test modifié ? (informatif, jamais bloquant)
if [ -n "$SRC_GREP" ] && [ -n "$TEST_GREP" ]; then
  CH="$(git diff --name-only HEAD 2>/dev/null)"
  if [ -n "$CH" ]; then
    NSRC="$(printf '%s\n' "$CH" | grep -cE "$SRC_GREP" || true)"
    NTST="$(printf '%s\n' "$CH" | grep -cE "$TEST_GREP" || true)"
    if [ "$NSRC" -gt 0 ] 2>/dev/null && [ "$NTST" -eq 0 ] 2>/dev/null; then
      info "⚠ TDD: $NSRC fichier(s) source modifié(s) sans test modifié — test d'abord ?"
    fi
  fi
fi

echo "========================================"
exit "$rc"
