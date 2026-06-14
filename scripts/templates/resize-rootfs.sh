#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

echo "Resizing root partition to full SD card size..."
growpart /dev/mmcblk0 1
resize2fs /dev/mmcblk0p1
systemctl disable resize-rootfs.service

echo "Root filesystem resized successfully."
