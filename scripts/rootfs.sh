# SPDX-License-Identifier: GPL-2.0-or-later
# Arch Linux ARM rootfs download, configuration, and first-boot resize.

get_arch_rootfs_md5() {
    if [ -n "${ARCH_ROOTFS_MD5:-}" ]; then
        echo "$ARCH_ROOTFS_MD5"
        return 0
    fi
    wget -qO- "$ARCH_MD5_URL" | awk '{print $1}'
}

verify_arch_rootfs_md5() {
    local tarball="$1" expected actual

    expected="${2:-$(get_arch_rootfs_md5)}"
    if [ -z "$expected" ]; then
        echo "Error: could not resolve Arch rootfs MD5 ($ARCH_MD5_URL)" >&2
        exit 1
    fi

    actual=$(md5sum "$tarball" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "Error: tarball MD5 mismatch (expected $expected, got $actual)" >&2
        exit 1
    fi

    echo "    MD5 valid ($expected)"
}

has_matching_rootfs_tarball_md5() {
    local tarball="$1" expected actual

    [ -f "$tarball" ] || return 1

    expected="${2:-}"
    [ -n "$expected" ] || return 1

    actual=$(md5sum "$tarball" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

download_and_verify_rootfs() {
    echo "[7/10] Downloading Arch Linux ARM rootfs..."
    local tarball="$ROOTFS_CACHE/${ARCH_IMAGE}.tar.gz" expected
    local sig="$ROOTFS_CACHE/${ARCH_IMAGE}.tar.gz.sig"
    local keyring="$SCRIPT_DIR/vendor/alarmsigning.gpg"

    [ -f "$keyring" ] || {
        echo "Error: missing $keyring" >&2
        exit 1
    }

    expected=$(get_arch_rootfs_md5)
    if [ -z "$expected" ]; then
        echo "Error: could not resolve Arch rootfs MD5 ($ARCH_MD5_URL)" >&2
        exit 1
    fi

    if [ -f "$tarball" ] && [ -f "$sig" ] && has_matching_rootfs_tarball_md5 "$tarball" "$expected"; then
        echo "    → Using cached rootfs tarball ($(basename "$tarball"), MD5 $expected)"
    else
        echo "    → Fetching tarball and signature..."
        wget -N --show-progress -O "$tarball" "$ARCH_ROOTFS_URL"
        wget -N --show-progress -O "$sig" "$ARCH_ROOTFS_SIG_URL"
    fi

    echo "    → Verifying signature ($ARCH_SIGNING_KEY_FPR)..."
    if gpgv --keyring "$keyring" "$sig" "$tarball" >/dev/null 2>&1; then
        echo "    Signature valid"
    else
        echo "    Signature verification FAILED" >&2
        exit 1
    fi

    echo "    → Verifying MD5 against $ARCH_MD5_URL..."
    verify_arch_rootfs_md5 "$tarball" "$expected"
}

verify_stock_kernel_r2c() {
    # The NanoPi R2C's on-board WAN PHY is a Motorcomm YT8521S; it needs the
    # motorcomm PHY driver (CONFIG_MOTORCOMM_PHY, module or built-in). Without
    # it the WAN port will never link up — refuse to build such an image.
    local kver
    kver=$(get_chroot_latest_kver)
    [ -n "$kver" ] || {
        echo "Error: no kernel modules found in rootfs" >&2
        exit 1
    }

    if ls "mnt/usr/lib/modules/$kver"/kernel/drivers/net/phy/motorcomm.ko* >/dev/null 2>&1; then
        echo "    → Stock kernel has Motorcomm PHY driver (module: motorcomm.ko) — WAN OK"
        return 0
    fi

    if grep -qs 'drivers/net/phy/motorcomm' "mnt/usr/lib/modules/$kver/modules.builtin"; then
        echo "    → Stock kernel has Motorcomm PHY driver (built-in) — WAN OK"
        return 0
    fi

    echo "Error: stock linux-aarch64 kernel lacks the Motorcomm PHY driver (CONFIG_MOTORCOMM_PHY)." >&2
    echo "The NanoPi R2C WAN port (YT8521S PHY) will not work without it." >&2
    echo "Inspect the package:  tar -xOf linux-aarch64-*.pkg.tar.zst usr/lib/modules/*/modules.builtin | grep -i motorcomm" >&2
    echo "On a running board:   ls /sys/bus/mdio_bus/drivers/   (expect a YT8521 entry)" >&2
    exit 1
}

slim_rootfs() {
    if [ "$SHOULD_SKIP_SLIM" = "1" ]; then
        echo "    → Skipping firmware slim (SHOULD_SKIP_SLIM=1)"
        return 0
    fi

    echo "    → Slimming firmware packages..."
    local -a fw_pkgs=(linux-firmware-whence linux-firmware-realtek)
    local has_slimmed_firmware=0 should_regenerate_initramfs=0

    set_chroot_resolver

    if ! run_chroot_pacman -Sy; then
        echo "       Warning: pacman -Sy failed; leaving full linux-firmware"
        return 0
    fi

    if ! run_chroot_pacman -Sw "${fw_pkgs[@]}"; then
        echo "       Warning: prefetch failed; leaving full linux-firmware"
        return 0
    fi

    disable_chroot_pacman_hooks
    if ! run_chroot_pacman_no_hooks -Rns linux-firmware; then
        enable_chroot_pacman_hooks
        echo "       Warning: could not remove linux-firmware meta"
        return 0
    fi

    should_regenerate_initramfs=1

    if run_chroot_pacman_no_hooks -S "${fw_pkgs[@]}"; then
        has_slimmed_firmware=1
    else
        echo "       Warning: slim install failed; restoring linux-firmware"
        run_chroot_pacman_no_hooks -S linux-firmware || true
    fi
    enable_chroot_pacman_hooks

    if [ "$should_regenerate_initramfs" -eq 1 ]; then
        run_chroot_mkinitcpio
    fi

    run_chroot_pacman -Scc --noconfirm 2>/dev/null || run_chroot_pacman -Scc --noconfirm

    cat > mnt/etc/pacman.conf.d/99-nanopi-r2c-slim.conf <<'EOF'
# Keep heavy GPU/WiFi firmware packages off this router image.
[options]
IgnorePkg = linux-firmware linux-firmware-nvidia linux-firmware-amdgpu linux-firmware-radeon linux-firmware-intel linux-firmware-mediatek linux-firmware-broadcom linux-firmware-atheros linux-firmware-cirrus
EOF

    if [ "$has_slimmed_firmware" -eq 1 ]; then
        echo "       firmware slim OK (realtek + whence)"
    fi
}

verify_boot_files() {
    echo "    → Verifying boot files..."

    local missing=()
    local f

    for f in boot/Image boot/initramfs-linux.img boot/uInitrd boot/boot.scr \
             "boot/dtbs/$BOOT_DTB"; do
        [ -f "mnt/$f" ] || missing+=("$f")
    done

    if [ -d mnt/boot/extlinux ]; then
        echo "Error: mnt/boot/extlinux must not exist" >&2
        exit 1
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing boot files: ${missing[*]}" >&2
        exit 1
    fi

    echo "       boot files OK"
}

install_led_service() {
    echo "    → Installing GPIO LED service..."
    install -D -m 0755 "$TEMPLATES_DIR/nanopi-r2c-leds.sh" \
        mnt/usr/local/sbin/nanopi-r2c-leds.sh
    install -D -m 0644 "$TEMPLATES_DIR/nanopi-r2c-leds.service" \
        mnt/etc/systemd/system/nanopi-r2c-leds.service

    mkdir -p mnt/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/nanopi-r2c-leds.service \
        mnt/etc/systemd/system/multi-user.target.wants/nanopi-r2c-leds.service
}

configure_timezone_and_locale() {
    echo "    → Configuring timezone (Asia/Shanghai) and UTF-8 locale..."

    # --- 默认时区：上海 ---
    ln -sf /usr/share/zoneinfo/Asia/Shanghai mnt/etc/localtime
    echo "Asia/Shanghai" > mnt/etc/timezone

    # --- 默认 locale：启用 en_US.UTF-8 与 zh_CN.UTF-8，系统默认 en_US.UTF-8 ---
    if [ -f mnt/etc/locale.gen ]; then
        sed -i 's/^#\s*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' mnt/etc/locale.gen
        sed -i 's/^#\s*zh_CN\.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' mnt/etc/locale.gen
    fi
    echo 'LANG=en_US.UTF-8' > mnt/etc/locale.conf
}

configure_zram() {
    echo "    → Installing and configuring zram (zram-generator)..."

    # 1. 安装 zram-generator
    set_chroot_resolver
    if ! run_chroot_pacman -S --noconfirm zram-generator; then
        echo "       Error: zram-generator install failed" >&2
        return 1
    fi

    # 2. 写入 zram 配置：lz4 算法，大小为内存一半（1GB 设备即 512MiB）
    cat > mnt/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
EOF

    # 3. 调整 swappiness，让内核更积极地使用 zram 交换
    install -d -m 0755 mnt/etc/sysctl.d
    cat > mnt/etc/sysctl.d/99-zram-swappiness.conf <<'EOF'
vm.swappiness = 100
EOF

    echo "       zram configured (lz4, ram/2, swap-priority=100, swappiness=100)"
}

extract_and_configure() {
    local tarball="$ROOTFS_CACHE/${ARCH_IMAGE}.tar.gz"
    local boot_cmd="$TEMPLATES_DIR/boot.cmd"

    if [ ! -f "$boot_cmd" ]; then
        echo "Error: missing template: $boot_cmd" >&2
        exit 1
    fi

    echo "[8/10] Extracting and configuring rootfs..."

    if mountpoint -q mnt 2>/dev/null; then
        unmount_chroot_root
    fi
    rm -rf mnt
    mkdir -p mnt

    echo "    → Extracting rootfs..."
    bsdtar -xpf "$tarball" -C mnt

    mount_chroot_root
    ensure_cross_chroot_binfmt

    configure_timezone_and_locale

    echo "$ROOTFS_HOSTNAME" > mnt/etc/hostname

    if [ -f mnt/etc/hosts ]; then
        sed -i '/^127\.0\.0\.1[[:space:]]/d' mnt/etc/hosts
        printf '127.0.0.1\t%s.localdomain\t%s\n' "$ROOTFS_HOSTNAME" "$ROOTFS_HOSTNAME" >> mnt/etc/hosts
    fi

    setup_chroot_build_opts
    run_arch_chroot pacman-key --init
    run_arch_chroot pacman-key --populate archlinuxarm

    # 生成已启用的 UTF-8 locale
    if [ -f mnt/etc/locale.gen ]; then
        run_arch_chroot locale-gen
    fi

    configure_kernel_variant
    prepare_mkinitcpio_chroot

    if [ "$KERNEL_VARIANT" = "minimal" ]; then
        run_chroot_mkinitcpio
    fi
    install_fan_control
    prepare_mkinitcpio_chroot

    # 安装并配置 zram，确保在 slim 清理之前完成
    configure_zram

    slim_rootfs

    echo "    → Wrapping initramfs as uInitrd..."
    "$UBOOT_BUILD_DIR/tools/mkimage" -A arm64 -O linux -T ramdisk -C none \
        -n "Arch Linux ARM initramfs" -d mnt/boot/initramfs-linux.img mnt/boot/uInitrd

    echo "    → Installing boot.scr..."
    install -D -m 0644 "$boot_cmd" mnt/boot/boot.cmd
    "$UBOOT_BUILD_DIR/tools/mkimage" -C none -A arm -T script \
        -d mnt/boot/boot.cmd mnt/boot/boot.scr

    rm -rf mnt/boot/extlinux

    install_led_service
    verify_boot_files
}

add_resize_service() {
    local img="$OUTPUT_DIR/$IMAGE_NAME"

    if [ "$SHOULD_ENABLE_RESIZE" = "1" ]; then
        echo "[9/10] Adding first-boot resize service..."
        install -D -m 0755 "$TEMPLATES_DIR/resize-rootfs.sh" mnt/usr/local/sbin/resize-rootfs.sh
        install -D -m 0644 "$TEMPLATES_DIR/resize-rootfs.service" \
            mnt/etc/systemd/system/resize-rootfs.service

        mkdir -p mnt/etc/systemd/system/multi-user.target.wants
        ln -sf /etc/systemd/system/resize-rootfs.service \
           mnt/etc/systemd/system/multi-user.target.wants/resize-rootfs.service

        echo "    → Installing cloud-utils in image (growpart for first boot)..."
        set_chroot_resolver
        run_chroot_pacman -Sy

        if ! run_chroot_pacman -S cloud-utils; then
            echo "Error: cloud-utils install failed (required for first-boot growpart)" >&2
            unmount_chroot_root
            exit 1
        fi
    else
        echo "[9/10] Skipping resize service"
    fi

    # Build-time copy only; do not ship the CI/host resolver config on the SD image.
    finalize_image_resolver

    unmount_chroot_root
    write_dir_to_image_partition "$img" mnt
    rm -rf mnt
}
