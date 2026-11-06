# SPDX-License-Identifier: GPL-2.0-or-later
# Chroot helpers for rootfs configuration.

# x86_64 build hosts need binfmt for aarch64 ELFs in arch-chroot. Pacman hooks skip
# systemd-binfmt when the root is not booted (typical Docker/GHA job containers).
ensure_cross_chroot_binfmt() {
    case "$(uname -m)" in
        aarch64) return 0 ;;
    esac

    if [ ! -x /usr/bin/qemu-aarch64-static ]; then
        echo "Error: install qemu-user-static and qemu-user-static-binfmt on the build host" >&2
        return 1
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || {
            echo "Error: cannot mount binfmt_misc (container needs --privileged)" >&2
            return 1
        }
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        if [ -x /usr/lib/systemd/systemd-binfmt ]; then
            /usr/lib/systemd/systemd-binfmt
        fi
    fi

    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "Error: qemu-aarch64 binfmt not registered after systemd-binfmt" >&2
        ls -la /proc/sys/fs/binfmt_misc/ >&2 || true
        return 1
    fi
}

# arch-chroot and pacman require the rootfs directory to be a mountpoint.
mount_chroot_root() {
    mkdir -p mnt/var/cache/pacman/pkg

    if mountpoint -q mnt 2>/dev/null; then
        return 0
    fi

    mount --bind mnt mnt
}

unmount_chroot_root() {
    if ! mountpoint -q mnt 2>/dev/null; then
        return 0
    fi
    umount -R mnt 2>/dev/null || umount -l -R mnt 2>/dev/null || true
}

set_chroot_resolver() {
    rm -f mnt/etc/resolv.conf

    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf mnt/etc/resolv.conf
    elif [ -L /etc/resolv.conf ] && [ -f "$(readlink -f /etc/resolv.conf)" ]; then
        cp "$(readlink -f /etc/resolv.conf)" mnt/etc/resolv.conf
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > mnt/etc/resolv.conf
    fi
}

finalize_image_resolver() {
    rm -f mnt/etc/resolv.conf

    if [ -e mnt/usr/lib/systemd/resolv.conf ]; then
       ln -sf ../run/systemd/resolve/stub-resolv.conf mnt/etc/resolv.conf
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > mnt/etc/resolv.conf
    fi
}

# pacman only reads /etc/pacman.conf and the files it Includes; it does not
# load /etc/pacman.conf.d/*.conf. Add (and later remove) a real Include line
# inside the [options] section instead.
pacman_conf_add_include() {
    local conf="mnt/etc/pacman.conf" inc="$1"
    local line="Include = $inc"

    [ -f "$conf" ] || return 0
    grep -qxF "$line" "$conf" && return 0

    if grep -q '^\[options\]' "$conf"; then
        awk -v line="$line" '
            BEGIN { done = 0 }
            /^\[options\]/ { print; if (!done) { print line; done = 1 }; next }
            { print }
        ' "$conf" > "$conf.nanopi" && mv "$conf.nanopi" "$conf"
    else
        printf '\n[options]\n%s\n' "$line" >> "$conf"
    fi
}

pacman_conf_remove_include() {
    local conf="mnt/etc/pacman.conf" inc="$1" tmp="mnt/etc/pacman.conf.nanopi"

    [ -f "$conf" ] || return 0
    grep -vxF "Include = $inc" "$conf" > "$tmp" || true
    if [ -s "$tmp" ]; then
        mv "$tmp" "$conf"
    else
        rm -f "$tmp"
    fi
}

setup_chroot_build_opts() {
    echo "    → Chroot build opts: MAKEFLAGS=-j${BUILD_JOBS}, ParallelDownloads=${BUILD_JOBS}"

    mkdir -p mnt/etc/pacman.d mnt/etc/environment.d

    # Build-host only: faster downloads in the chroot. Removed again by
    # finalize_image_pacman() so the shipped image keeps the sandbox enabled.
    cat > mnt/etc/pacman.d/99-nanopi-r2c-build.conf <<EOF
ParallelDownloads = ${BUILD_JOBS}
EOF
    pacman_conf_add_include "/etc/pacman.d/99-nanopi-r2c-build.conf"

    cat > mnt/etc/environment.d/99-build-jobs.conf <<EOF
MAKEFLAGS=-j${BUILD_JOBS}
XZ_THREADS=${BUILD_JOBS}
ZSTD_NBTHREADS=${BUILD_JOBS}
EOF
}

finalize_image_pacman() {
    pacman_conf_remove_include "/etc/pacman.d/99-nanopi-r2c-build.conf"
    rm -f mnt/etc/pacman.d/99-nanopi-r2c-build.conf
}

run_arch_chroot() {
    arch-chroot mnt env \
        MAKEFLAGS="-j${BUILD_JOBS}" \
        XZ_THREADS="${BUILD_JOBS}" \
        ZSTD_NBTHREADS="${BUILD_JOBS}" \
        TMPDIR=/tmp \
        "$@"
}

run_chroot_pacman() {
    run_arch_chroot pacman --disable-sandbox --noconfirm "$@"
}

run_chroot_pacman_no_hooks() {
    if run_arch_chroot pacman --help 2>&1 | grep -q 'disable-hooks'; then
        run_chroot_pacman --disable-hooks "$@"
    else
        run_chroot_pacman "$@"
    fi
}

disable_chroot_pacman_hooks() {
    run_arch_chroot sh -c '
        for d in /usr/share/libalpm/hooks /etc/pacman.d/hooks; do
            [ -d "$d" ] && [ ! -d "${d}.disabled" ] && mv "$d" "${d}.disabled"
        done
    ' 2>/dev/null || true
}

enable_chroot_pacman_hooks() {
    run_arch_chroot sh -c '
        for d in /usr/share/libalpm/hooks /etc/pacman.d/hooks; do
            [ -d "${d}.disabled" ] && mv "${d}.disabled" "$d"
        done
    ' 2>/dev/null || true
}

prepare_mkinitcpio_chroot() {
    local preset

    for preset in mnt/etc/mkinitcpio.d/*.preset; do
        [ -f "$preset" ] || continue

        if ! grep -q 'nanopi-r2c: no fallback' "$preset" 2>/dev/null; then
            sed -i "s/^PRESETS=.*/PRESETS=('default')  # nanopi-r2c: no fallback (autodetect breaks in cross-chroot)/" \
                "$preset"
        fi
    done
}

get_chroot_latest_kver() {
    ls mnt/usr/lib/modules 2>/dev/null | sort -V | tail -1
}

can_run_chroot_aarch64() {
    run_arch_chroot sh -c '/usr/bin/true' >/dev/null 2>&1
}

run_chroot_mkinitcpio() {
    local kver
    local -a config=()

    kver=$(get_chroot_latest_kver)
    if [ -z "$kver" ]; then
        echo "Error: no kernel modules in chroot" >&2
        return 1
    fi

    if ! can_run_chroot_aarch64; then
        echo "    Warning: aarch64 not runnable in chroot (install qemu-user-static qemu-user-static-binfmt)"
        echo "             keeping initramfs from rootfs tarball"
        return 0
    fi

    echo "    → Regenerating initramfs for ${kver}..."
    run_arch_chroot depmod -a "$kver"

    case "$kver" in
        *-nanopi-r2c-minimal)
            if [ -f mnt/etc/mkinitcpio.linux-nanopi-r2c-minimal.conf ]; then
                config=(-c /etc/mkinitcpio.linux-nanopi-r2c-minimal.conf)
            fi
            ;;
    esac

    if ! run_arch_chroot mkinitcpio -k "$kver" "${config[@]}" -g /boot/initramfs-linux.img; then
        echo "Error: mkinitcpio failed for ${kver}" >&2
        return 1
    fi
}

# The stock ALARM kernel keeps the SD/MMC host, mmc_block and ext4 as modules.
# They are normally pulled in by mkinitcpio's autodetect hook, but autodetect
# inspects the build host's /sys inside a cross-chroot, so a generated initramfs
# can silently miss them and the board then panics with "unable to mount root".
# Check explicitly, add what is missing to MODULES and regenerate once.
initramfs_missing_modules() {
    local kver="$1" listing="$2"
    shift 2

    local mod missing=()
    for mod in "$@"; do
        if grep -qs "/${mod}\.ko" "mnt/usr/lib/modules/${kver}/modules.builtin"; then
            continue
        fi
        if printf '%s\n' "$listing" | grep -q "/${mod}\.ko"; then
            continue
        fi
        missing+=("$mod")
    done

    printf '%s\n' "${missing[@]}"
}

append_initramfs_modules() {
    local conf="mnt/etc/mkinitcpio.conf"
    local line new mod

    [ -f "$conf" ] || return 1

    line=$(grep -m1 '^MODULES=' "$conf" || true)
    [ -n "$line" ] || return 1

    new="$line"
    for mod in "$@"; do
        case "$new" in
            *"$mod"*) ;;
            *) new="${new%)*} $mod)" ;;
        esac
    done

    [ "$new" = "$line" ] && return 0

    printf '       Adding to MODULES: %s\n' "$*"
    sed -i "s|^MODULES=.*|$new|" "$conf"
}

verify_initramfs_boot_support() {
    if [ "${SHOULD_SKIP_INITRAMFS_CHECK:-0}" = "1" ]; then
        echo "    → Skipping initramfs verification (SHOULD_SKIP_INITRAMFS_CHECK=1)"
        return 0
    fi

    # The minimal kernel builds its SD/ext4 boot path in, so there is nothing
    # to look for in the initramfs.
    if [ "$KERNEL_VARIANT" != "stock" ]; then
        return 0
    fi

    local kver img="mnt/boot/initramfs-linux.img" listing missing
    local -a modules=(dw_mmc-rockchip mmc_block ext4)

    kver=$(get_chroot_latest_kver)
    if [ -z "$kver" ]; then
        echo "Error: no kernel modules found while verifying initramfs" >&2
        return 1
    fi

    if [ ! -s "$img" ]; then
        echo "Error: missing initramfs: $img" >&2
        return 1
    fi

    if ! can_run_chroot_aarch64; then
        echo "    Warning: aarch64 not runnable in chroot; cannot inspect initramfs" >&2
        return 0
    fi

    listing=$(run_arch_chroot lsinitcpio /boot/initramfs-linux.img 2>/dev/null || true)
    if [ -z "$listing" ]; then
        echo "    Warning: lsinitcpio produced no output; skipping initramfs check" >&2
        return 0
    fi

    missing=$(initramfs_missing_modules "$kver" "$listing" "${modules[@]}")
    if [ -z "$missing" ]; then
        echo "    → Initramfs contains the SD/ext4 boot path"
        return 0
    fi

    echo "    → Initramfs is missing: $(echo "$missing" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    append_initramfs_modules $missing || true
    run_chroot_mkinitcpio

    listing=$(run_arch_chroot lsinitcpio /boot/initramfs-linux.img 2>/dev/null || true)
    missing=$(initramfs_missing_modules "$kver" "$listing" "${modules[@]}")
    if [ -n "$missing" ]; then
        echo "Error: initramfs still lacks $(echo "$missing" | tr '\n' ' ')" >&2
        echo "The image would not boot (root on mmcblk0p1 would never appear)." >&2
        echo "Add the modules to MODULES in /etc/mkinitcpio.conf or set" >&2
        echo "SHOULD_SKIP_INITRAMFS_CHECK=1 to override." >&2
        return 1
    fi

    echo "    → Initramfs boot path OK after module fixup"
}
