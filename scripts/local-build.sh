#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build on a native Arch host with every large write going to the external
# build volume (ext4 image) instead of the repository filesystem.
#
# Usage: sudo ./scripts/local-build.sh [build-image.sh options]
# Env:   DRIVE, BUILD_IMG, MOUNT_POINT, KERNEL_VARIANT, ...

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo root)}"
DRIVE="${DRIVE:-/run/media/${TARGET_USER}/DATA}"
BUILD_IMG="${BUILD_IMG:-${DRIVE}/nanopi-r2c-build/build.img}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nanopi-build}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${DRIVE}/nanopi-r2c-artifacts}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

# Informational calls do not need the volume.
case "${1:-}" in
    --print-deps|-h|--help)
        exec "$REPO_DIR/build-image.sh" "$@"
        ;;
esac

[ "$(id -u)" -eq 0 ] || fail "run as root: sudo $0"
[ -f "$BUILD_IMG" ] || fail "build volume missing: $BUILD_IMG (run scripts/setup-build-env.sh first)"
[ -d "$DRIVE" ] || fail "drive not mounted: $DRIVE"

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "==> Mounting build volume $BUILD_IMG"
    mkdir -p "$MOUNT_POINT"
    mount -o loop,noatime "$BUILD_IMG" "$MOUNT_POINT"
fi

BUILD_ROOT="$MOUNT_POINT/build"
mkdir -p "$BUILD_ROOT/cache" "$BUILD_ROOT/output" "$BUILD_ROOT/mnt" "$BUILD_ROOT/tmp"

# Everything the build writes in bulk lands on the external drive.
export BUILD_ROOT
export CACHE_DIR="$BUILD_ROOT/cache"
export OUTPUT_DIR="$BUILD_ROOT/output"
# Reuse cached TF-A/U-Boot builds unless their build tag says otherwise.
export SHOULD_SKIP_TFA_REBUILD="${SHOULD_SKIP_TFA_REBUILD:-1}"
export SHOULD_SKIP_UBOOT_REBUILD="${SHOULD_SKIP_UBOOT_REBUILD:-1}"
# Do not export TMPDIR: it would leak into arch-chroot, where the host path
# does not exist. chroot.sh sets TMPDIR=/tmp for chroot commands.

echo "==> Build root: $BUILD_ROOT ($(df -h "$BUILD_ROOT" | awk 'NR == 2 { print $4 }') free)"

cd "$REPO_DIR"
bash ./build-image.sh "$@"

echo "==> Copying artifacts to $ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"
shopt -s nullglob
for f in "$OUTPUT_DIR"/*.img "$OUTPUT_DIR"/*.img.xz "$OUTPUT_DIR"/SHA256SUMS; do
    cp -f "$f" "$ARTIFACTS_DIR/"
done
chown -R "${TARGET_USER}:${TARGET_USER}" "$ARTIFACTS_DIR" 2>/dev/null || true
ls -lh "$ARTIFACTS_DIR"
