#!/bin/sh
# Security hardening for DNS-345 Debian installation
# Run as root on the NAS after initial setup

set -e

echo "=== DNS-345 Security Hardening ==="

# 1. Disable unnecessary services (rpcbind, rpc.statd)
echo "[1/6] Disabling rpcbind and NFS services..."
update-rc.d rpcbind disable 2>/dev/null || true
update-rc.d nfs-common disable 2>/dev/null || true
/etc/init.d/rpcbind stop 2>/dev/null || true
kill $(pidof rpc.statd) 2>/dev/null || true

# 2. Harden SSH: key-only auth, no root password login
echo "[2/6] Hardening SSH..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
/etc/init.d/ssh reload

# 3. Samba: dedicated user instead of root
echo "[3/6] Creating dedicated Samba user..."
id nasdata 2>/dev/null || useradd -r -s /usr/sbin/nologin -d /srv/data nasdata
chown -R nasdata:nasdata /srv/data
sed -i 's/force user = root/force user = nasdata/' /etc/samba/smb.conf
/etc/init.d/smbd restart

# 4. Deduplicate authorized_keys
echo "[4/6] Cleaning SSH authorized_keys..."
if [ -f /root/.ssh/authorized_keys ]; then
    sort -u /root/.ssh/authorized_keys > /tmp/ak_clean
    mv /tmp/ak_clean /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# 5. Firewall: allow only SSH, Samba, NTP, ping
echo "[5/6] Configuring firewall..."
if ! command -v iptables >/dev/null 2>&1; then
    apt-get install -y iptables
fi
iptables -F
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 445 -j ACCEPT
iptables -A INPUT -p tcp --dport 139 -j ACCEPT
iptables -A INPUT -p udp --dport 123 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -j DROP

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
cat > /etc/network/if-pre-up.d/iptables << 'EOF'
#!/bin/sh
/sbin/iptables-restore < /etc/iptables/rules.v4
EOF
chmod +x /etc/network/if-pre-up.d/iptables

# 6. Disable IPv6 (not needed on a LAN NAS)
echo "[6/6] Disabling IPv6..."
echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-no-ipv6.conf
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true

echo ""
echo "=== Hardening complete ==="
echo "  - rpcbind/NFS: disabled"
echo "  - SSH: key-only, no root password login"
echo "  - Samba: runs as 'nasdata' user (not root)"
echo "  - Firewall: SSH/SMB/NTP/ping only, rest dropped"
echo "  - IPv6: disabled"
echo ""
echo "Verify with: ss -tlnp && iptables -L -n"
