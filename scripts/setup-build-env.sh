#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Prepare a native Arch Linux x86_64 build host for nanopi-r2c-arch, using an
# ext4 image on an external drive as the build volume (cache/, output/, mnt/).
#
# The repository itself may live on a filesystem without POSIX ownership
# (exFAT/NTFS); only the build volume needs ext4.
#
# Usage: sudo ./scripts/setup-build-env.sh
# Env:   DRIVE, BUILD_IMG, MOUNT_POINT, VOLUME_SIZE

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo root)}"
DRIVE="${DRIVE:-/run/media/${TARGET_USER}/DATA}"
BUILD_IMG="${BUILD_IMG:-${DRIVE}/nanopi-r2c-build/build.img}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nanopi-build}"
VOLUME_SIZE="${VOLUME_SIZE:-30G}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root: sudo $0"
[ -d "$DRIVE" ] || fail "drive not mounted: $DRIVE (set DRIVE=...)"

echo "==> Installing build dependencies"
mapfile -t deps < <("$REPO_DIR/build-image.sh" --print-deps)
pacman -S --needed --noconfirm "${deps[@]}" \
    arch-install-scripts aarch64-linux-gnu-gcc qemu-user-static \
    qemu-user-static-binfmt xz uboot-tools rsync

echo "==> Enabling aarch64 binfmt for the cross-chroot"
if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
fi
if [ -x /usr/lib/systemd/systemd-binfmt ]; then
    /usr/lib/systemd/systemd-binfmt || true
fi
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    systemctl restart systemd-binfmt.service || true
fi
[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
    || fail "qemu-aarch64 binfmt is not registered (mount binfmt_misc / install qemu-user-static-binfmt)"
aarch64-linux-gnu-gcc --version >/dev/null || fail "aarch64 cross compiler missing"

echo "==> Preparing build volume: $BUILD_IMG"
mkdir -p "$(dirname "$BUILD_IMG")"

if [ ! -f "$BUILD_IMG" ]; then
    free_kb=$(df -Pk "$DRIVE" | awk 'NR == 2 { print $4 }')
    need_kb=$((30 * 1024 * 1024))
    [ "${free_kb:-0}" -gt "$need_kb" ] || fail "not enough free space on $DRIVE"

    echo "    Creating ${VOLUME_SIZE} ext4 image (this writes the whole file on exFAT)"
    truncate -s "$VOLUME_SIZE" "$BUILD_IMG"
    mkfs.ext4 -F -m 0 -L nanopi-build "$BUILD_IMG"
fi

mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "    Mounting $BUILD_IMG at $MOUNT_POINT"
    mount -o loop,noatime "$BUILD_IMG" "$MOUNT_POINT"
fi

mkdir -p "$MOUNT_POINT/build/cache" "$MOUNT_POINT/build/output" \
    "$MOUNT_POINT/build/mnt" "$MOUNT_POINT/build/tmp"
chown -R "${TARGET_USER}:${TARGET_USER}" "$MOUNT_POINT" 2>/dev/null || true

echo
echo "Build volume ready:"
echo "  repository : $REPO_DIR"
echo "  volume     : $MOUNT_POINT (from $BUILD_IMG)"
echo "  free       : $(df -h "$MOUNT_POINT" | awk 'NR == 2 { print $4 }')"
echo
echo "Build one image (root):"
echo "  sudo $REPO_DIR/scripts/local-build.sh"
echo "Build the minimal-kernel variant:"
echo "  sudo KERNEL_VARIANT=minimal $REPO_DIR/scripts/local-build.sh"
