#!/usr/bin/env python3
"""
patch_uboot.py — Patch DNS-345 U-Boot for automatic Debian boot

The DNS-345 U-Boot has an "enaAutoRecovery" feature that:
  1. Resets all environment variables on every boot
  2. Forces bootdelay=0 (no time to interrupt)
  3. Runs a HARDCODED recovery bootcmd from the binary itself

This means saveenv is completely useless — the boot command always
comes from the binary at offset 0x4FAAD, not from the NAND environment.

This script patches the hardcoded recovery bootcmd to boot a Debian
kernel from NAND (mtd1) instead of the D-Link recovery image (mtd3).

Requires: A raw mtd0 dump from the DNS-345 (exactly 1MB)

Usage:
    # Patch for automatic Debian boot:
    python3 patch_uboot.py mtd0_dump.bin uboot_debian.bin

    # Custom root device:
    python3 patch_uboot.py mtd0_dump.bin uboot_custom.bin \\
        --bootcmd "nand read.e 0x800000 0x100000 0x600000;setenv bootargs root=/dev/sdb1 rootdelay=10;bootm 0x800000"

    # Create flasher U-Boot (for brick recovery via kwboot):
    python3 patch_uboot.py mtd0_dump.bin uboot_flasher.bin \\
        --flasher 192.168.1.114
"""

import struct
import argparse
import sys

# === DNS-345 U-Boot 1.1.4 Marvell 3.5.9 binary layout ===
#
# kwbimage v0 header (32 bytes):
#   0x00: magic, srcaddr=0x200, blocksize=0x73C60, ...
#   0x1F: header checksum (8-bit sum of bytes 0x00-0x1E)
#
# Data region: 0x200 to 0x200+0x73C60 = 0x73E60
#   0x4FAAD: hardcoded recovery bootcmd (101 bytes with null)
#   0x4FD46: "enaAutoRecovery" string (NOT the trigger — patching this does nothing)
#   0x54D16: mini firmware fallback bootcmd
#   0x73094: compiled-in default environment (overridden by NAND env)
#   0x73E5C: data checksum (32-bit LE word sum of 0x200..0x73E5B)
#
RECOVERY_BOOTCMD_OFFSET = 0x4FAAD
RECOVERY_BOOTCMD_MAXLEN = 100        # max usable bytes (field is 101 with null)
DATA_CHECKSUM_OFFSET    = 0x73E5C
DATA_START              = 0x200      # kwbimage srcaddr
DATA_SIZE               = 0x73C60   # kwbimage blocksize
EXPECTED_SIZE           = 1048576    # 1MB (full mtd0)

# Original recovery bootcmd — reads D-Link firmware from mtd3 + ramdisk from mtd2
ORIGINAL_BOOTCMD = (
    "nand read.e 0xa00000 0xb00000 0x600000;"
    "nand read.e 0xf00000 0x600000 0x100000;"
    "bootm 0xa00000 0xf00000"
)

# Replacement — reads Debian kernel from mtd1 (6MB), boots with SATA root
DEFAULT_BOOTCMD = (
    "nand read.e 0x800000 0x100000 0x600000;"
    "setenv bootargs root=/dev/sda1 rootdelay=10;"
    "bootm 0x800000"
)


def calculate_data_checksum(data: bytearray) -> int:
    """Calculate the kwbimage v0 data checksum (32-bit LE word sum)."""
    checksum = 0
    for i in range(DATA_START, DATA_START + DATA_SIZE - 4, 4):
        word = struct.unpack_from('<I', data, i)[0]
        checksum = (checksum + word) & 0xFFFFFFFF
    return checksum


def patch(data: bytearray, bootcmd: str) -> int:
    """Patch the recovery bootcmd and recalculate data checksum."""
    cmd_bytes = bootcmd.encode('ascii') + b'\x00'
    if len(cmd_bytes) > RECOVERY_BOOTCMD_MAXLEN + 1:
        print(f"ERROR: Command too long: {len(bootcmd)} bytes (max {RECOVERY_BOOTCMD_MAXLEN})")
        sys.exit(1)

    # Pad with nulls to fill the entire original field
    padded = cmd_bytes.ljust(RECOVERY_BOOTCMD_MAXLEN + 1, b'\x00')
    data[RECOVERY_BOOTCMD_OFFSET:RECOVERY_BOOTCMD_OFFSET + len(padded)] = padded

    # Recalculate and write the data checksum
    new_cksum = calculate_data_checksum(data)
    struct.pack_into('<I', data, DATA_CHECKSUM_OFFSET, new_cksum)
    return new_cksum


def main():
    parser = argparse.ArgumentParser(
        description="Patch DNS-345 U-Boot for automatic Debian boot",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", help="Input U-Boot binary (1MB mtd0 dump from nanddump)")
    parser.add_argument("output", help="Output patched U-Boot binary")
    parser.add_argument(
        "--bootcmd", default=DEFAULT_BOOTCMD,
        help="Custom boot command (max 100 chars). Default boots Debian from mtd1 with root=/dev/sda1"
    )
    parser.add_argument(
        "--flasher", metavar="TFTP_SERVER_IP",
        help="Create a flasher U-Boot: downloads file 'u' from TFTP server and writes it to NAND mtd0. "
             "Used with kwboot for brick recovery."
    )
    args = parser.parse_args()

    # Read input binary
    with open(args.input, 'rb') as f:
        data = bytearray(f.read())

    if len(data) != EXPECTED_SIZE:
        print(f"ERROR: Expected {EXPECTED_SIZE} bytes (1MB mtd0 dump), got {len(data)}")
        sys.exit(1)

    # Read current recovery bootcmd
    null_pos = data.index(b'\x00', RECOVERY_BOOTCMD_OFFSET)
    current_cmd = data[RECOVERY_BOOTCMD_OFFSET:null_pos].decode('ascii', errors='replace')
    old_cksum = struct.unpack_from('<I', data, DATA_CHECKSUM_OFFSET)[0]

    # Determine the new boot command
    if args.flasher:
        bootcmd = (
            f"dhcp 2000000 {args.flasher}:u;"
            f"nand erase 0 100000;"
            f"nand write 2000000 0 100000;"
            f"reset"
        )
        if len(bootcmd) > RECOVERY_BOOTCMD_MAXLEN:
            print(f"ERROR: Flasher command too long ({len(bootcmd)} chars). Use a shorter IP or hostname.")
            sys.exit(1)
        mode = "FLASHER"
    else:
        bootcmd = args.bootcmd
        mode = "DEBIAN BOOT"

    # Display patch info
    print(f"=== DNS-345 U-Boot Patcher — {mode} ===")
    print(f"")
    print(f"Input:    {args.input}")
    print(f"Output:   {args.output}")
    print(f"")
    print(f"Current:  {current_cmd}")
    print(f"Patched:  {bootcmd}")
    print(f"Length:   {len(bootcmd)}/{RECOVERY_BOOTCMD_MAXLEN} bytes")
    print(f"")

    # Apply patch
    new_cksum = patch(data, bootcmd)

    print(f"Checksum: 0x{old_cksum:08x} -> 0x{new_cksum:08x}")

    # Write output
    with open(args.output, 'wb') as f:
        f.write(data)

    print(f"")
    print(f"Written:  {args.output} ({len(data)} bytes)")

    if args.flasher:
        print(f"")
        print(f"=== FLASHER USAGE ===")
        print(f"1. Place the FINAL U-Boot binary (e.g. uboot_debian.bin) as: /tmp/tftp/u")
        print(f"2. Start TFTP server:  sudo python3 tftp/tftp_server.py")
        print(f"3. Boot via kwboot:    kwboot -b {args.output} -t /dev/ttyUSB0")
        print(f"4. FULL power cycle:   unplug power cable, replug, press power button")
        print(f"5. Wait: flasher downloads 'u', erases NAND, writes new U-Boot, resets")
        print(f"")
        print(f"NOTE: 'dhcp' requires a DHCP server on the network.")
        print(f"If dhcp fails, the flasher will fail and U-Boot will drop to a prompt.")
        print(f"From there, manually configure network and flash:")
        print(f"  setenv ipaddr 192.168.1.109")
        print(f"  setenv serverip {args.flasher}")
        print(f"  tftpboot 0x2000000 u")
        print(f"  nand erase 0x0 0x100000")
        print(f"  nand write 0x2000000 0x0 0x100000")
        print(f"  reset")
    else:
        print(f"")
        print(f"=== NEXT STEPS ===")
        print(f"Flash to NAND from U-Boot prompt:")
        print(f"  setenv ipaddr 192.168.1.109      # NAS IP")
        print(f"  setenv serverip 192.168.1.114     # TFTP server IP")
        print(f"  tftpboot 0x2000000 uboot_debian.bin")
        print(f"  nand erase 0x0 0x100000")
        print(f"  nand write 0x2000000 0x0 0x100000")
        print(f"  reset")
        print(f"")
        print(f"Or use kwboot for brick recovery (see README.md)")


if __name__ == '__main__':
    main()
