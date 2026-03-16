#!/bin/sh
# Format rootfs partition on first SATA disk
mke2fs -j -L rootfs /dev/sda1 > /tmp/format.log 2>&1
echo DONE >> /tmp/format.log
