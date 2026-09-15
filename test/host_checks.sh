#!/usr/bin/env bash
# Portes de vérification exécutables SUR LA MACHINE HÔTE (pas sur le NAS).
#
# À ne pas confondre avec test/run_tests.sh, qui est une recette d'acceptation
# matérielle : celle-là lit /proc/mdstat, ping la passerelle et interroge smartctl,
# elle n'a de sens que sur le DNS-345 lui-même et est garantie rouge ailleurs.
#
# Ce script-ci ne vérifie que ce qui est vérifiable hors cible : syntaxe, lint,
# compilation du device tree, et cohérence entre le README et le contenu du repo.
# Il est appelé par scripts/check.sh, qui reste la source unique de vérité.
#
# Usage:
#   host_checks.sh            -> phase rapide (portes 1 à 6)
#   host_checks.sh --strict   -> portes supplémentaires du mode complet (porte 7)

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
# Helpers volontairement nommés err/note et NON pass/fail/warn : ces trois noms-là
# sont le motif compté par le ratchet (.tripwire-testcount) et par la garde
# anti-affaiblissement du hook PostToolUse. Les réutiliser ici fausserait les deux.
err()  { echo "${RED}✗ $*${NC}" >&2; }
note() { echo "${YEL}» $*${NC}"; }
good() { echo "${GREEN}✓ $*${NC}"; }

STRICT=0
case "${1:-}" in
  --strict) STRICT=1 ;;
  '') ;;
  *) err "argument inconnu: $1"; exit 2 ;;
esac

rc=0

# Un outil manquant est un échec, pas un skip : vert doit vouloir dire vert.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  err "outil requis absent: $1 (paquet: $2)"
  return 1
}

# Ensembles de fichiers, pris depuis git : les binaires du repo sont gitignorés,
# un glob aveugle ramasserait les dumps NAND et les images kernel.
# 'scripts/hooks/pre-push' est nommé explicitement : il n'a pas d'extension .sh
# et passerait donc entre les mailles du glob.
mapfile -t SH_FILES < <(git ls-files 'scripts/*.sh' 'scripts/*.init' 'test/*.sh' 'scripts/hooks/pre-push')
mapfile -t PY_FILES < <(git ls-files 'scripts/*.py' 'tftp/*.py')

if [ "${#SH_FILES[@]}" -eq 0 ] || [ "${#PY_FILES[@]}" -eq 0 ]; then
  err "aucun fichier shell ou Python trouvé — lancer depuis un clone git complet ?"
  exit 1
fi

# ---------------------------------------------------------------- mode strict
# Uniquement les portes supplémentaires : scripts/check.sh a déjà lancé la
# phase rapide avant d'arriver ici, inutile de la refaire.
if [ "$STRICT" -eq 1 ]; then
  need shellcheck shellcheck || exit 1
  note "7. shellcheck -S warning (${#SH_FILES[@]} fichiers)"
  if shellcheck -S warning "${SH_FILES[@]}"; then
    good "shellcheck (warning) OK"
  else
    err "shellcheck a des avertissements"
    rc=1
  fi
  exit "$rc"
fi

# ----------------------------------------------------------------- porte 1/6
note "1. bash -n (${#SH_FILES[@]} fichiers shell)"
n=0
for f in "${SH_FILES[@]}"; do
  if ! bash -n "$f" 2>&1; then
    err "syntaxe shell invalide: $f"
    rc=1; n=$((n + 1))
  fi
done
[ "$n" -eq 0 ] && good "syntaxe shell OK"

# ----------------------------------------------------------------- porte 2/6
note "2. shellcheck -S error"
if need shellcheck shellcheck; then
  if shellcheck -S error "${SH_FILES[@]}"; then
    good "shellcheck (error) OK"
  else
    err "shellcheck a des erreurs"
    rc=1
  fi
else
  rc=1
fi

# ----------------------------------------------------------------- porte 3/6
# ast.parse et non py_compile : py_compile écrit des __pycache__ dans le repo.
note "3. syntaxe Python (${#PY_FILES[@]} fichiers)"
n=0
for f in "${PY_FILES[@]}"; do
  if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f"; then
    err "syntaxe Python invalide: $f"
    rc=1; n=$((n + 1))
  fi
done
[ "$n" -eq 0 ] && good "syntaxe Python OK"

# ----------------------------------------------------------------- porte 4/6
# Code retour seul, jamais -Werror : le DTS porte des avertissements préexistants
# (unique_unit_address, simple_bus_reg…) hérités de la fusion ts419 + dns325.
DTS="boot/kirkwood-dns345.dts"
note "4. compilation du device tree ($DTS)"
if need dtc device-tree-compiler; then
  if [ ! -f "$DTS" ]; then
    err "$DTS introuvable"
    rc=1
  elif dtc -I dts -O dtb -o /dev/null "$DTS" >/dev/null 2>&1; then
    good "dtc OK"
  else
    err "le DTS ne compile pas :"
    dtc -I dts -O dtb -o /dev/null "$DTS" >&2
    rc=1
  fi
else
  rc=1
fi

# ----------------------------------------------------------------- porte 5/6
# Le README est le produit de ce repo : un chemin qu'il demande de copier, ou
# une image qu'il affiche, doit exister — sinon la procédure documentée est
# infaisable (cas vécu avec scripts/dashboard.init, absent alors que la Phase 15
# disait de le scp).
#
# Exclusions : chemins qui ressemblent à des fichiers du repo mais n'en sont pas.
DOC_IGNORE=(
  # Phase 4 : boot/dts/... désigne l'arborescence du rootfs Doozan une fois
  # extraite dans /tmp, pas le répertoire boot/ de ce dépôt.
  "boot/dts"
)
note "5. cohérence des chemins cités par le README"
missing=0
while read -r p; do
  [ -n "$p" ] || continue
  skip=0
  for ig in "${DOC_IGNORE[@]}"; do
    [ "$p" = "$ig" ] && { skip=1; break; }
  done
  [ "$skip" -eq 1 ] && continue
  if [ ! -e "$p" ]; then
    err "README cite $p — ce chemin n'existe pas dans le repo"
    missing=$((missing + 1))
  fi
done < <(grep -ohE '\b(scripts|tftp|boot|test|uboot|images)/[A-Za-z0-9_.-]+' README.md | sort -u)
if [ "$missing" -eq 0 ]; then
  good "chemins du README OK"
else
  err "$missing chemin(s) cité(s) par le README sont absents du repo"
  rc=1
fi

# ----------------------------------------------------------------- porte 6/7
# Tests unitaires de la logique pure, exécutables sans matériel.
note "6. tests unitaires"
UNIT_FAILED=0
for t in test/unit_*.sh; do
  [ -e "$t" ] || continue
  if out="$(sh "$t" 2>&1)"; then
    printf '%s\n' "$out" | tail -1
  else
    printf '%s\n' "$out" >&2
    err "échec: $t"
    UNIT_FAILED=$((UNIT_FAILED + 1))
    rc=1
  fi
done
[ "$UNIT_FAILED" -eq 0 ] && good "tests unitaires OK"

exit "$rc"
