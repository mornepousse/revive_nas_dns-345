# D-Link DNS-345 — Debian Bookworm Installation Guide

Run **Debian 12 (Bookworm)** on a D-Link DNS-345 4-bay NAS with a modern kernel, SMB2/3 (Samba), and modern SSH.

## Why?

The DNS-345 ships with:
- Kernel **2.6.31** (2009) — no security updates
- Samba **3.5.15** — SMB1 only (blocked by Windows 10+, macOS)
- OpenSSH **5.0p1** — deprecated algorithms, can't connect from modern clients
- glibc **2.8** — can't run any modern software

This guide replaces the entire OS with Debian Bookworm (kernel 6.5.7) while keeping the original U-Boot bootloader.

## Hardware

| Component | Details |
|-----------|---------|
| **NAS** | D-Link DNS-345, 4-bay |
| **SoC** | Marvell Kirkwood 88F6282 (Feroceon 88FR131, ARMv5TE) |
| **RAM** | 512MB DDR2 |
| **SATA** | Marvell 88SX7042 PCI-Express (4 ports) |
| **NAND** | 128MB (U-Boot + kernel + ramdisk) |
| **UART** | JP1 header, 115200 8N1, 3.3V TTL |

## Prerequisites

- **Serial console access** (USB-TTL adapter, e.g. CH340) — required for U-Boot interaction
- A computer on the same LAN (used as TFTP server)
- A USB flash drive (for rootfs, if using RAID on all 4 disks)
- The [Doozan Debian Kirkwood rootfs](https://forum.doozan.com/read.php?2,12096)

## Architecture Overview

```
┌─────────────────────────────────────────┐
│              NAND Flash (128MB)          │
│  ┌─────────┬──────────────┬───────────┐ │
│  │  U-Boot  │  uImage      │  (unused) │ │
│  │  (1MB)   │  kernel+DTB  │           │ │
│  │  mtd0    │  mtd1+mtd2   │  mtd3-5   │ │
│  └─────────┴──────────────┴───────────┘ │
└─────────────────────────────────────────┘
         │ boots
         ▼
┌─────────────────────────────────────────┐
│  USB Flash Drive (/dev/sde1)            │
│  Debian Bookworm rootfs (ext3)          │
│  kernel 6.5.7-kirkwood                  │
└─────────────────────────────────────────┘
         │ mounts
         ▼
┌─────────────────────────────────────────┐
│  4x SATA Disks — RAID 5 (mdadm)        │
│  /dev/md0 → /srv/data                  │
│  ~2.7TB usable (4x 1TB)                │
└─────────────────────────────────────────┘
```

## Key Discoveries

These issues are **not documented anywhere** and were found the hard way:

### 1. Wrong DTB — PCI-E SATA not detected
The DNS-345 uses a **PCI-Express SATA controller** (88SX7042), NOT the integrated Kirkwood SATA.
The obvious choice `kirkwood-dns325.dtb` has PCI-E **disabled** → no disks detected.

**Fix:** Use `kirkwood-ts419-6282.dtb` which has PCI-E enabled (same 88F6282 SoC).

### 2. Kernel too big for NAND partition
The uImage (~6.2MB) exceeds mtd1 (5MB). The default `bootcmd` reads only 3MB.

**Fix:** Write kernel across mtd1+mtd2 (10MB total), boot manually with `nand read.e 0x800000 0x100000 0x700000`.

### 3. U-Boot auto-recovery resets environment
`enaAutoRecovery=yes` in U-Boot resets all environment variables after any failed boot. `saveenv` doesn't persist.

**Workaround:** Boot manually from U-Boot prompt each time. See [Automatic Boot](#automatic-boot-unsolved) for potential solutions.

### 4. Disk ordering changes with new kernel
Old kernel (2.6.31): sda = disk CC49. New kernel with TS-419 DTB: sdc = disk CC49. Root device must match.

**Fix:** Use UUIDs in fstab and bootargs.

### 5. No serial download in U-Boot
This U-Boot has NO `loady`/`loadb`/`loadx` commands. The only way to transfer files is TFTP.

---

## Step-by-Step Guide

### Phase 1: Initial Access

The DNS-345 firmware is vulnerable to [CVE-2024-3273](https://nvd.nist.gov/vuln/detail/CVE-2024-3273) (command injection via web interface), which can be used to obtain a root shell.

Connect a USB-TTL serial adapter to JP1 header on the PCB:
```bash
picocom -b 115200 /dev/ttyUSB0
```

### Phase 2: Prepare Boot Images (on host PC)

Download and extract the Doozan rootfs:
```bash
wget "https://www.dropbox.com/scl/fi/t2zv6g1sydq019urfnsd6/Debian-5.6.7-kirkwood-tld-1-rootfs-bodhi.tar.bz2"
mkdir -p rootfs && cd rootfs
tar xjf ../Debian-*.tar.bz2
```

Build the uImage with the correct DTB:
```bash
# MUST use ts419-6282 DTB for PCI-E SATA support
cat boot/zImage-6.5.7-kirkwood-tld-1 boot/dts/kirkwood-ts419-6282.dtb > zImage-dtb

mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 \
  -n 'Linux-6.5.7-kirkwood' -d zImage-dtb uImage-ts419
```

### Phase 3: TFTP Server

U-Boot only supports TFTP. A minimal Python TFTP server is included in [`tftp/tftp_server.py`](tftp/tftp_server.py):

```bash
mkdir -p /tmp/tftp
cp uImage-ts419 /tmp/tftp/
sudo python3 tftp/tftp_server.py
```

> **Note:** Port 69 (UDP) requires root. On NixOS, also add `networking.firewall.allowedUDPPorts = [ 69 ];`.

### Phase 4: Flash Kernel via U-Boot

Access U-Boot by pressing a key during the 3-second boot delay:

```
# Set network
setenv ipaddr 192.168.1.109
setenv serverip 192.168.1.114

# Download kernel via TFTP
tftpboot 0x800000 uImage-ts419

# Backup NAND first! (from old Linux, before flashing)
# nanddump -f /backup/mtd0_uboot.bin /dev/mtd0
# nanddump -f /backup/mtd1_kernel.bin /dev/mtd1
# nanddump -f /backup/mtd2_ramdisk.bin /dev/mtd2

# Flash kernel to NAND (spans mtd1 + mtd2)
nand erase 0x100000 0x700000
nand write 0x800000 0x100000 0x5f2800
```

> **Important:** Round the write size up to the next 2048-byte (NAND page) boundary.

### Phase 5: Prepare Rootfs on USB Drive

```bash
# Format USB drive
mkfs.ext3 -L rootfs /dev/sde1

# Mount and extract Debian
mkdir -p /mnt/usb
mount /dev/sde1 /mnt/usb
cd /mnt/usb
tar xjf /path/to/Debian-*.tar.bz2

# Configure fstab (use UUID for stability)
cat > etc/fstab << 'EOF'
/dev/sde1  /     ext3  defaults,noatime  0  1
tmpfs      /tmp  tmpfs defaults          0  0
EOF

echo "dns345" > etc/hostname
```

### Phase 6: Boot Debian

From U-Boot prompt:
```
setenv bootargs 'root=/dev/sde1 rootdelay=10 console=ttyS0,115200'
nand read.e 0x800000 0x100000 0x700000
bootm 0x800000
```

First boot tasks:
```bash
# Generate SSH host keys
ssh-keygen -A
/etc/init.d/ssh start

# Set the date (no RTC)
date -s "2026-03-13 12:00:00"

# Install packages
apt update
apt install -y samba mdadm ntpdate fdisk
```

### Phase 7: RAID 5 Setup

With rootfs on USB, all 4 SATA disks can be used for RAID 5 (~2.7TB usable):

```bash
# Partition all 4 disks (single partition each)
for disk in sda sdb sdc sdd; do
  echo -e "o\nn\np\n1\n\n\nw" | fdisk /dev/$disk
done

# Create RAID 5 array
mdadm --create /dev/md0 --level=5 --raid-devices=4 \
  /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1

# Format and mount
mkfs.ext4 /dev/md0
mkdir -p /srv/data
mount /dev/md0 /srv/data

# Save RAID config
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

# Add to fstab
echo '/dev/md0  /srv/data  ext4  defaults,noatime  0  2' >> /etc/fstab
```

### Phase 8: Samba Configuration

```bash
apt install -y samba

cat > /etc/samba/smb.conf << 'EOF'
[global]
   workgroup = WORKGROUP
   server string = DNS-345
   server role = standalone server
   log file = /var/log/samba/log.%m
   max log size = 50
   min protocol = SMB2
   map to guest = bad user

[data]
   path = /srv/data
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0664
   directory mask = 0775
EOF

systemctl restart smbd
```

---

## NAND Layout

| Partition | Offset | Size | Contents |
|-----------|--------|------|----------|
| mtd0 | 0x000000 | 1MB | U-Boot (**do not touch**) |
| mtd1 | 0x100000 | 5MB | uImage kernel (start) |
| mtd2 | 0x600000 | 5MB | uImage kernel (end, ~1.2MB used) |
| mtd3 | 0xB00000 | 102MB | D-Link image (unused) |
| mtd4 | 0x7100000 | 10MB | D-Link mini firmware (recovery) |
| mtd5 | 0x7B00000 | 5MB | D-Link config (unused) |

## Automatic Boot (unsolved)

The U-Boot `enaAutoRecovery=yes` feature resets the environment after any failed boot. The default `bootcmd` reads only 3MB from NAND, but our kernel is 6.2MB → CRC error → recovery loop.

Potential solutions:
1. **Patch U-Boot binary in mtd0** — change the default bootcmd string in the binary itself (risky, could brick)
2. **fw_setenv from Linux** — write to the U-Boot environment partition (may get overwritten by auto-recovery)
3. **Smaller kernel** — compress or strip the kernel to fit in 3MB (may not be feasible)

Currently: manual boot from U-Boot prompt is required at each power cycle.

## Known Issues

- **PIN20 conflict:** The TS-419 DTB has a potential pin conflict between SATA and Ethernet. eth1 may not work (eth0 is fine).
- **No RTC:** Clock resets to 1969 on every boot. Install `ntpdate` or `systemd-timesyncd` for automatic sync.
- **Disk ordering:** Device names (sda/sdb/sdc/sdd) may change between reboots. Use UUIDs where possible.

## Files in This Repo

```
├── README.md                   # This guide
├── tftp/
│   └── tftp_server.py          # Minimal TFTP server (Python)
├── boot/
│   ├── kirkwood-ts419-6282.dtb # Working DTB (PCI-E enabled)
│   └── kirkwood-dns325.dtb     # Original DTB (PCI-E disabled, doesn't work)
├── scripts/
│   ├── build_env.py            # U-Boot environment builder
│   ├── do_config.sh            # Rootfs configuration script
│   ├── do_extract.sh           # Rootfs extraction script
│   └── do_format.sh            # Disk formatting script
└── uboot/                      # NAND dumps (not in git, for backup only)
```

> **Note:** Binary images (uImage, zImage, NAND dumps) are excluded from git — they're too large. Download the [Doozan rootfs](https://forum.doozan.com/read.php?2,12096) and build them yourself (see Phase 2).

## Credits

- [Doozan Forum](https://forum.doozan.com/) — Debian Kirkwood rootfs and community
- [bodhi](https://forum.doozan.com/read.php?2,12096) — Kirkwood kernel builds and rootfs
- [CVE-2024-3273](https://nvd.nist.gov/vuln/detail/CVE-2024-3273) — Initial access vector

## License

This documentation is provided as-is for educational purposes. Use at your own risk.
