#!/bin/sh
# Tests unitaires de la machine à états de scripts/fan-control.sh.
#
# Tourne sur l'hôte : aucun accès matériel. Le script est sourcé avec
# FAN_CONTROL_LIB=1, qui l'arrête avant toute découverte hwmon et n'expose que
# fan_target() — fonction pure (état courant, température carte, température
# SoC) -> PWM cible.
#
# Contexte : la version initiale était non monotone (à 42 °C elle laissait le
# ventilateur à fond, à 44 °C elle le baissait), ce qui faisait battre le
# ventilateur toutes les ~30 s autour de 46 °C — 9920 transitions relevées dans
# /var/log/fan-control.log. Les deux propriétés en fin de fichier verrouillent
# ça : monotonie et absence de bascule.

set -u
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL + 1)); }

FAN_CONTROL_LIB=1 . ./scripts/fan-control.sh || {
    echo "impossible de sourcer scripts/fan-control.sh" >&2
    exit 1
}

command -v fan_target >/dev/null 2>&1 || {
    echo "fan_target() introuvable — la logique doit être extraite dans une fonction pure" >&2
    exit 1
}

# Seuils de référence des tests (les défauts du script).
T_LOW=38; T_HIGH=46; HYST=3; SOC_LOW=65; SOC_HIGH=75
OFF=0; LOW=127; HIGH=255
SOC_COOL=55   # sous SOC_LOW : aucune surcharge SoC

name() { case "$1" in 0) echo OFF ;; 127) echo LOW ;; 255) echo HIGH ;; *) echo "$1" ;; esac; }

expect() { # $1=cur $2=tb $3=soc $4=attendu $5=libellé
    got=$(fan_target "$1" "$2" "$3")
    if [ "$got" = "$4" ]; then
        pass
    else
        fail "$5: depuis $(name "$1") à ${2}°C (soc ${3}°C) -> $(name "$got"), attendu $(name "$4")"
    fi
}

echo "--- 1. Depuis OFF : démarrage à T_LOW, plein régime à T_HIGH ---"
expect $OFF 30 $SOC_COOL $OFF  "froid"
expect $OFF 37 $SOC_COOL $OFF  "juste sous T_LOW"
expect $OFF 38 $SOC_COOL $LOW  "à T_LOW"
expect $OFF 45 $SOC_COOL $LOW  "juste sous T_HIGH"
expect $OFF 46 $SOC_COOL $HIGH "à T_HIGH"
expect $OFF 50 $SOC_COOL $HIGH "au-dessus de T_HIGH"
# Au démarrage le PWM courant est inconnu : doit se comporter comme OFF, sinon
# la zone morte basse s'applique dès le premier tour et le ventilateur part à
# LOW alors que la carte est froide.
expect "" 37 $SOC_COOL $OFF "état initial inconnu traité comme OFF"
expect "" 38 $SOC_COOL $LOW "état initial inconnu, démarrage à T_LOW"

echo "--- 2. Depuis LOW : ne s'arrête qu'en dessous de T_LOW - HYST ---"
expect $LOW 34 $SOC_COOL $OFF  "sous T_LOW-HYST"
expect $LOW 35 $SOC_COOL $LOW  "à T_LOW-HYST, on reste LOW"
expect $LOW 37 $SOC_COOL $LOW  "zone morte basse"
expect $LOW 45 $SOC_COOL $LOW  "juste sous T_HIGH"
expect $LOW 46 $SOC_COOL $HIGH "à T_HIGH"

echo "--- 3. Depuis HIGH : zone morte T_HIGH-HYST..T_HIGH (le cœur du bug) ---"
expect $HIGH 46 $SOC_COOL $HIGH "à T_HIGH"
expect $HIGH 45 $SOC_COOL $HIGH "45 : on RESTE HIGH, sinon ça bat avec 46"
expect $HIGH 44 $SOC_COOL $HIGH "44 : encore dans la zone morte"
expect $HIGH 43 $SOC_COOL $HIGH "à T_HIGH-HYST : dernier palier HIGH"
expect $HIGH 42 $SOC_COOL $LOW  "sous T_HIGH-HYST : on descend enfin"
expect $HIGH 38 $SOC_COOL $LOW  "à T_LOW"
expect $HIGH 35 $SOC_COOL $LOW  "à T_LOW-HYST"
expect $HIGH 34 $SOC_COOL $OFF  "sous T_LOW-HYST"

echo "--- 4. Surcharge SoC (garde-fou, jamais le pilote normal) ---"
expect $OFF 20 75 $HIGH "SoC à SOC_HIGH force HIGH même carte froide"
expect $OFF 20 80 $HIGH "SoC au-delà de SOC_HIGH"
expect $OFF 20 65 $LOW  "SoC à SOC_LOW force au moins LOW"
expect $OFF 20 64 $OFF  "SoC juste sous SOC_LOW : aucune surcharge"
expect $LOW 20 70 $LOW  "SoC tiède ne remonte pas au-dessus de LOW"

echo "--- 5. Propriété : monotonie (plus chaud ne doit jamais ventiler moins) ---"
for cur in $OFF $LOW $HIGH; do
    prev=""
    t=25
    while [ "$t" -le 55 ]; do
        got=$(fan_target "$cur" "$t" "$SOC_COOL")
        if [ -n "$prev" ] && [ "$got" -lt "$prev" ]; then
            fail "monotonie rompue depuis $(name "$cur") : ${t}°C -> $(name "$got") alors que $((t - 1))°C -> $(name "$prev")"
        else
            pass
        fi
        prev="$got"
        t=$((t + 1))
    done
done

echo "--- 6. Propriété : aucune bascule possible ---"
# Si à une température donnée HIGH veut descendre pendant que LOW veut monter,
# les deux états se renvoient la balle indéfiniment : c'est exactement le
# battement observé en production.
t=25
while [ "$t" -le 55 ]; do
    from_high=$(fan_target $HIGH "$t" "$SOC_COOL")
    from_low=$(fan_target $LOW "$t" "$SOC_COOL")
    if [ "$from_high" = "$LOW" ] && [ "$from_low" = "$HIGH" ]; then
        fail "bascule à ${t}°C : HIGH descend vers LOW et LOW remonte vers HIGH"
    else
        pass
    fi
    t=$((t + 1))
done

echo
echo "fan-control: $PASS assertions OK, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
