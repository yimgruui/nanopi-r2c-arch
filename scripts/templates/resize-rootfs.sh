#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

# Grow the root partition and filesystem to fill the SD card on first boot.
# Uses parted (already in the image) instead of cloud-utils/growpart, which
# pulled python and qemu-img into the image for a single shell script.

src="$(findmnt -no SOURCE /)"
[ -n "$src" ] || { echo "Cannot determine root device" >&2; exit 1; }

pkname="$(lsblk -no PKNAME "$src" | head -n1)"
[ -n "$pkname" ] || { echo "Root device $src is not a plain partition" >&2; exit 1; }

part="$(cat "/sys/class/block/${src##*/}/partition")"
dev="/dev/$pkname"

echo "Growing partition ${part} on ${dev} and resizing $src..."
printf 'Yes\n' | parted ---pretend-input-tty "$dev" resizepart "$part" 100% || true
partx -u "$dev" || true
resize2fs "$src"

systemctl disable resize-rootfs.service
echo "Root filesystem resized successfully."
