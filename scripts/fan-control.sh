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

    # lm75-driven target with hysteresis on step-down
    case "$CUR_PWM" in
        "$PWM_HIGH") step_low=$(( T_HIGH - HYST )); step_off=$(( T_LOW - HYST )) ;;
        "$PWM_LOW")  step_low=$T_HIGH;              step_off=$(( T_LOW - HYST )) ;;
        *)           step_low=$T_LOW;               step_off=$T_LOW ;;
    esac

    if   [ "$tb" -ge "$T_HIGH" ];   then target=$PWM_HIGH
    elif [ "$tb" -ge "$step_low" ]; then target=$PWM_LOW
    elif [ "$tb" -lt "$step_off" ]; then target=$PWM_OFF
    else                                target=$CUR_PWM
    fi

    # SoC safety override: never below LOW if SoC hot, force HIGH if very hot
    if [ "$ts" -ge "$SOC_HIGH" ]; then
        target=$PWM_HIGH
    elif [ "$ts" -ge "$SOC_LOW" ] && [ "${target:-0}" -lt "$PWM_LOW" ]; then
        target=$PWM_LOW
    fi

    [ -n "$target" ] && set_pwm "$target"
    sleep "$INTERVAL"
done
