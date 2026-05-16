#!/bin/sh
# DNS-345 fan controller — temperature-based PWM via gpio-fan
# Hardware: gpio-fan with 3 speeds (off / 3000 RPM / 6000 RPM)
#           lm75 board sensor + kirkwood_thermal SoC sensor
#
# Strategy: read max(lm75, soc), step the fan with hysteresis.
# No deps beyond busybox.

INTERVAL="${INTERVAL:-15}"        # poll period (seconds)
T_HIGH="${T_HIGH:-48}"            # >= this → full speed
T_LOW="${T_LOW:-40}"              # >= this → low speed
HYST="${HYST:-3}"                 # cooldown delta to step down

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

[ -z "$LM75$SOC" ] && { echo "no temp sensor" >&2; exit 1; }

read_temp() {
    [ -r "$1/temp1_input" ] && awk '{print int($1/1000)}' "$1/temp1_input" || echo 0
}

set_pwm() {
    [ "$1" = "$CUR_PWM" ] && return
    echo "$1" > "$FAN/pwm1" 2>/dev/null && CUR_PWM=$1
}

CUR_PWM=
echo "fan-control: FAN=$FAN LM75=$LM75 SOC=$SOC thresholds=${T_LOW}/${T_HIGH}°C hyst=${HYST}°C"

while :; do
    tb=$(read_temp "$LM75")
    ts=$(read_temp "$SOC")
    t=$(( tb > ts ? tb : ts ))

    # current state to apply hysteresis on the way down (no oscillation
    # at thresholds). Default (unknown) treats as OFF so we step up cleanly.
    case "$CUR_PWM" in
        "$PWM_HIGH") step_to_low=$(( T_HIGH - HYST ));  step_to_off=$(( T_LOW - HYST )) ;;
        "$PWM_LOW")  step_to_low=$T_HIGH;               step_to_off=$(( T_LOW - HYST )) ;;
        *)           step_to_low=$T_LOW;                step_to_off=$T_LOW ;;
    esac

    if   [ "$t" -ge "$T_HIGH" ];      then set_pwm $PWM_HIGH
    elif [ "$t" -ge "$step_to_low" ]; then set_pwm $PWM_LOW
    elif [ "$t" -lt "$step_to_off" ]; then set_pwm $PWM_OFF
    fi

    sleep "$INTERVAL"
done
