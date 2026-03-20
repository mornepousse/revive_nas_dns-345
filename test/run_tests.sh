#!/bin/bash
# DNS-345 Debian system test suite — run on target NAS
# Usage: bash run_tests.sh [gateway_ip]

set -u
GW="${1:-192.168.1.1}"
PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "========================================"
echo " DNS-345 Debian system test suite"
echo " $(date)"
echo "========================================"
echo

# -----------------------------------------------
echo "--- 1. Kernel ---"
KVER=$(uname -r)
ARCH=$(uname -m)
pass "Kernel: $KVER ($ARCH)"
echo

# -----------------------------------------------
echo "--- 2. Network ---"
IFACE=""
for i in eth0 enp0s0; do
    if ip link show "$i" &>/dev/null; then
        IFACE="$i"
        break
    fi
done
if [ -z "$IFACE" ]; then
    IFACE=$(ip -o link show | grep -v lo | head -1 | awk -F: '{print $2}' | tr -d ' ')
fi

if [ -n "$IFACE" ]; then
    STATE=$(ip link show "$IFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
    IPV4=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP 'inet \K[0-9./]+')
    if [ "$STATE" = "UP" ] && [ -n "$IPV4" ]; then
        pass "Interface $IFACE: UP, $IPV4"
    else
        fail "Interface $IFACE: state=$STATE ip=$IPV4"
    fi
else
    fail "No network interface found"
fi

if ping -c2 -W2 "$GW" &>/dev/null; then
    pass "Gateway $GW reachable"
else
    fail "Cannot reach gateway $GW"
fi
echo

# -----------------------------------------------
echo "--- 3. Disks ---"
DISK_COUNT=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | grep disk | wc -l)
if [ "$DISK_COUNT" -gt 0 ]; then
    pass "$DISK_COUNT disk(s) detected"
    lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -v "^loop" | while read l; do
        echo "       $l"
    done
else
    fail "No disks detected"
fi
echo

# -----------------------------------------------
echo "--- 4. RAID ---"
if [ -e /proc/mdstat ]; then
    MD_COUNT=$(grep "^md" /proc/mdstat | wc -l)
    if [ "$MD_COUNT" -gt 0 ]; then
        while read line; do
            DEV=$(echo "$line" | awk '{print $1}')
            STATE=$(grep -A1 "^$DEV" /proc/mdstat | tail -1 | grep -oP '\[.*\]' | tail -1)
            echo "       $DEV: $STATE"
            if echo "$STATE" | grep -q "_"; then
                warn "$DEV: degraded array $STATE"
            else
                pass "$DEV: healthy $STATE"
            fi
        done < <(grep "^md" /proc/mdstat)
    else
        warn "No RAID arrays"
    fi
else
    warn "/proc/mdstat not available"
fi
echo

# -----------------------------------------------
echo "--- 5. Filesystems ---"
ROOT_FS=$(df -T / 2>/dev/null | tail -1 | awk '{print $1, $2, $3}')
if [ -n "$ROOT_FS" ]; then
    pass "Root: $ROOT_FS"
fi

for MP in /srv/data /mnt/raid; do
    if mountpoint -q "$MP" 2>/dev/null; then
        FS=$(df -T "$MP" 2>/dev/null | tail -1 | awk '{print $1, $2, $3}')
        pass "Data: $MP ($FS)"
    fi
done
echo

# -----------------------------------------------
echo "--- 6. Services ---"
for SVC in sshd smbd; do
    if systemctl is-active "$SVC" &>/dev/null; then
        pass "$SVC: active"
    else
        if systemctl list-unit-files | grep -q "$SVC"; then
            fail "$SVC: not active"
        fi
    fi
done

# Check SSH port
if ss -tlnp | grep -q ":22 "; then
    pass "SSH listening on port 22"
else
    warn "SSH not listening on port 22"
fi

# Check Samba port
if ss -tlnp | grep -q ":445 "; then
    pass "Samba listening on port 445"
else
    warn "Samba not listening on port 445"
fi
echo

# -----------------------------------------------
echo "--- 7. Temperature ---"
TEMP=""
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    TEMP_C=$((TEMP / 1000))
    pass "SoC temperature: ${TEMP_C}°C"
elif command -v sensors &>/dev/null; then
    TEMP=$(sensors 2>/dev/null | grep -oP '[0-9.]+°C' | head -1)
    if [ -n "$TEMP" ]; then
        pass "Temperature: $TEMP"
    fi
fi
# LM75 on I2C
for h in /sys/class/hwmon/hwmon*/; do
    [ -d "$h" ] || continue
    NAME=$(cat "${h}name" 2>/dev/null)
    TEMP_F=$(ls "${h}"temp*_input 2>/dev/null | head -1)
    if [ -n "$TEMP_F" ]; then
        T=$(cat "$TEMP_F" 2>/dev/null)
        T_C=$((T / 1000))
        echo "       $NAME: ${T_C}°C"
    fi
done
echo

# -----------------------------------------------
echo "--- 8. Memory ---"
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_MB=$((MEM_TOTAL / 1024))
AVAIL_MB=$((MEM_AVAIL / 1024))
pass "RAM: ${AVAIL_MB}MB available / ${MEM_MB}MB total"

SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_MB=$((SWAP / 1024))
if [ "$SWAP_MB" -gt 0 ]; then
    pass "Swap: ${SWAP_MB}MB"
else
    warn "No swap configured"
fi
echo

# -----------------------------------------------
echo "--- 9. SMART ---"
if command -v smartctl &>/dev/null; then
    SMART_OK=0
    SMART_FAIL=0
    for dev in /dev/sd[a-z]; do
        [ -b "$dev" ] || continue
        HEALTH=$(smartctl -H "$dev" 2>/dev/null | grep "SMART overall" | awk '{print $NF}')
        if [ "$HEALTH" = "PASSED" ]; then
            SMART_OK=$((SMART_OK+1))
        elif [ -n "$HEALTH" ]; then
            SMART_FAIL=$((SMART_FAIL+1))
            fail "SMART: $dev = $HEALTH"
        fi
    done
    if [ "$SMART_OK" -gt 0 ]; then
        pass "SMART: $SMART_OK disk(s) healthy"
    fi
else
    warn "smartctl not installed"
fi
echo

# -----------------------------------------------
echo "--- 10. dmesg errors ---"
SYS_ERRS=$(dmesg 2>/dev/null | grep -iE "error|fail|oops|panic|bug" | grep -viE "corrected|non-fatal|PCIe|SerDes" | tail -5)
if [ -z "$SYS_ERRS" ]; then
    pass "No critical errors in dmesg"
else
    warn "Possible errors in dmesg:"
    echo "$SYS_ERRS" | while read l; do
        echo "       $l"
    done
fi
echo

# -----------------------------------------------
echo "========================================"
echo " Results: $PASS PASS, $FAIL FAIL, $WARN WARN"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
