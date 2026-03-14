#!/usr/bin/env python3
"""
Build a U-Boot NAND environment block for DNS-345.
Format: 4-byte CRC32 + env data (null-separated key=value pairs, double-null terminated)
Padded to 128KB (one NAND erase block).
"""
import struct
import binascii

# Environment variables
env_vars = [
    "bootargs=console=ttyS0,115200 root=/dev/sda2 rootdelay=10",
    "bootcmd=ide reset; ext2load ide 0:2 0xa00000 /boot/uImage; ext2load ide 0:2 0xf00000 /boot/uInitrd; bootm 0xa00000 0xf00000",
    "bootdelay=3",
    "baudrate=115200",
    "ethact=egiga0",
    "stdin=serial",
    "stdout=serial",
    "stderr=serial",
]

# Build env data: null-separated strings, double-null terminated
env_data = b'\x00'.join(s.encode('ascii') for s in env_vars) + b'\x00\x00'

# Pad to 128KB - 4 bytes (for CRC)
ENV_SIZE = 0x20000  # 128KB
data_padded = env_data + b'\xff' * (ENV_SIZE - 4 - len(env_data))

# Calculate CRC32
crc = binascii.crc32(data_padded) & 0xFFFFFFFF

# Build final block: CRC + data
env_block = struct.pack('<I', crc) + data_padded

# Write to file
with open('/tmp/debian-kirkwood/uboot_env.bin', 'wb') as f:
    f.write(env_block)

print(f"Environment block created: {len(env_block)} bytes")
print(f"CRC32: 0x{crc:08x}")
print(f"Env data size: {len(env_data)} bytes")
print(f"\nVariables:")
for v in env_vars:
    print(f"  {v}")
