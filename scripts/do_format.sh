#!/bin/sh
mke2fs -j -L rootfs /dev/sda2 > /tmp/format.log 2>&1
echo DONE >> /tmp/format.log
