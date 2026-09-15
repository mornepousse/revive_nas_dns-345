#!/bin/sh
# DNS-345 fan controller — temperature-based PWM via gpio-fan
# Hardware: gpio-fan with 3 speeds (off / 3000 RPM / 6000 RPM)
#           lm75 board sensor + kirkwood_thermal SoC sensor
#
# Strategy: lm75 (ambient near disks) drives cooling decisions.
# kirkwood_thermal (SoC die) acts as safety override only — that
# sensor sits at 55-60°C even at idle and would otherwise pin the
# fan to HIGH forever.

INTERVAL="${INTERVAL:-15}"        # poll period (seconds)

# Ambient (lm75) — what disks and case actually need
T_LOW="${T_LOW:-38}"              # >= this → low speed
T_HIGH="${T_HIGH:-46}"            # >= this → full speed
HYST="${HYST:-3}"                 # cooldown delta to step down

# SoC (kirkwood_thermal) — safety override, very loose
SOC_LOW="${SOC_LOW:-65}"          # >= this → at least low
SOC_HIGH="${SOC_HIGH:-75}"        # >= this → high

PWM_OFF=0
PWM_LOW=127
PWM_HIGH=255

# fan_target <pwm courant> <temp carte> <temp soc> -> pwm cible
#
# Fonction pure, testée par test/unit_fan_control.sh.
#
# L'hystérésis s'exprime en zones mortes attachées à l'état COURANT : on ne
# quitte un palier qu'une fois descendu de HYST sous le seuil qui l'a déclenché.
# Sans ça, monter à T_HIGH puis redescendre d'un degré suffit à repasser au
# palier du dessous, et la moindre oscillation d'un degré fait battre le
# ventilateur — c'est ce qui produisait des centaines de transitions par jour.
fan_target() {
    _cur="$1"; _tb="$2"; _ts="$3"
    # PWM courant inconnu (premier tour) : on raisonne comme depuis l'arrêt,
    # sinon la zone morte basse démarre le ventilateur sur une carte froide.
    case "$_cur" in '') _cur=$PWM_OFF ;; esac

    if   [ "$_tb" -ge "$T_HIGH" ]; then
        _target=$PWM_HIGH
    elif [ "$_cur" = "$PWM_HIGH" ] && [ "$_tb" -ge "$(( T_HIGH - HYST ))" ]; then
        _target=$PWM_HIGH                     # zone morte haute : on reste à fond
    elif [ "$_tb" -ge "$T_LOW" ]; then
        _target=$PWM_LOW
    elif [ "$_cur" != "$PWM_OFF" ] && [ "$_tb" -ge "$(( T_LOW - HYST ))" ]; then
        _target=$PWM_LOW                      # zone morte basse : on reste en petite vitesse
    else
        _target=$PWM_OFF
    fi

    # Garde-fou SoC : jamais en dessous de LOW si le die chauffe, plein régime
    # s'il est brûlant. Jamais le pilote normal — ce capteur est à 55-60 °C au repos.
    if [ "$_ts" -ge "$SOC_HIGH" ]; then
        _target=$PWM_HIGH
    elif [ "$_ts" -ge "$SOC_LOW" ] && [ "$_target" -lt "$PWM_LOW" ]; then
        _target=$PWM_LOW
    fi

    echo "$_target"
}

# Sourcé par les tests unitaires : on s'arrête ici, avant toute découverte
# matérielle, pour n'exposer que fan_target().
if [ "${FAN_CONTROL_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

find_hwmon() {
    for h in /sys/class/hwmon/hwmon*; do
        [ -r "$h/name" ] || continue
        [ "$(cat "$h/name")" = "$1" ] && { echo "$h"; return 0; }
    done
    return 1
}

FAN=$(find_hwmon gpio_fan)   || { echo "gpio_fan not found" >&2; exit 1; }
LM75=$(find_hwmon lm75)      || LM75=""
SOC=$(find_hwmon kirkwood_thermal) || SOC=""

[ -z "$LM75" ] && { echo "lm75 not found — refusing to start (would never step down)" >&2; exit 1; }

read_temp() {
    [ -r "$1/temp1_input" ] && awk '{print int($1/1000)}' "$1/temp1_input" || echo 0
}

log() {
    echo "[$(date '+%F %T')] $*"
}

set_pwm() {
    [ "$1" = "$CUR_PWM" ] && return
    if echo "$1" > "$FAN/pwm1" 2>/dev/null; then
        log "pwm $CUR_PWM → $1 (lm75=${tb}°C soc=${ts}°C)"
        CUR_PWM=$1
    fi
}

CUR_PWM=
log "fan-control start: lm75 ${T_LOW}/${T_HIGH}°C hyst=${HYST}, soc ${SOC_LOW}/${SOC_HIGH}°C, poll=${INTERVAL}s"

while :; do
    tb=$(read_temp "$LM75")
    ts=$(read_temp "${SOC:-$LM75}")

    target=$(fan_target "$CUR_PWM" "$tb" "$ts")

    set_pwm "$target"
    sleep "$INTERVAL"
done
