#!/bin/sh
# Configure Debian rootfs for DNS-345

# fstab
cat > /mnt/debian/etc/fstab << 'EOF'
/dev/sda2    /        ext3   defaults,noatime   0  1
/dev/sda1    none     swap   sw                 0  0
tmpfs        /tmp     tmpfs  defaults           0  0
EOF

# Network
cat > /mnt/debian/etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Hostname
echo dns345 > /mnt/debian/etc/hostname
echo "127.0.0.1 localhost dns345" > /mnt/debian/etc/hosts

# Root password: set to 124643837
sed -i 's|^root:[^:]*:|root:$6$wAeVvleiSqOBE/Di$SpuxzQRnnVRTFCZfxqjBnNaHJvaVP4/7ZVgnq0TFDL3pWT.H9HVwbr/ITiOCcIzHCzxaZzvHY0pmJ72JxOQav.:|' /mnt/debian/etc/shadow

# Enable serial console
mkdir -p /mnt/debian/etc/systemd/system/serial-getty@ttyS0.service.d
cat > /mnt/debian/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --keep-baud 115200,38400,9600 ttyS0 $TERM
EOF

# Enable SSH root login
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/debian/etc/ssh/sshd_config
# If no PermitRootLogin line exists, add it
grep -q "PermitRootLogin" /mnt/debian/etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /mnt/debian/etc/ssh/sshd_config

# DNS
echo "nameserver 8.8.8.8" > /mnt/debian/etc/resolv.conf

echo "DONE" > /tmp/config.log
