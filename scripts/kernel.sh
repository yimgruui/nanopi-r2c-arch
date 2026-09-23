# SPDX-License-Identifier: GPL-2.0-or-later
# Optional linux-nanopi-r2c-minimal image variant.

# NOTE: the minimal kernel MUST be built with CONFIG_MOTORCOMM_PHY enabled —
# the R2C's on-board WAN PHY is a Motorcomm YT8521S (the R2S uses a Realtek
# RTL8211E). The stock linux-aarch64 kernel normally provides this driver.
R2C_KERNEL_REPO_URL="${R2C_KERNEL_REPO_URL:-https://therealcoder1337.github.io/nanopi-r2c-kernel-arch/aarch64}"
R2C_KERNEL_KEY_URL="${R2C_KERNEL_KEY_URL:-${R2C_KERNEL_REPO_URL}/nanopi-r2c-kernel-arch.pub}"
R2C_KERNEL_KEY_FPR="${R2C_KERNEL_KEY_FPR:-}"
R2C_KERNEL_PKGVER="${R2C_KERNEL_PKGVER:-}"

trust_r2c_kernel_key() {
    local key="/tmp/nanopi-r2c-kernel-arch.pub"
    local expected="${R2C_KERNEL_KEY_FPR//[[:space:]]/}"
    local actual

    if [ -z "$expected" ]; then
        echo "Error: R2C_KERNEL_KEY_FPR is not set." >&2
        echo "Import your r2c kernel repo key first, e.g.:" >&2
        echo "  gpg --recv-keys <KEYID> && gpg --fingerprint <KEYID>" >&2
        echo "then re-run with R2C_KERNEL_KEY_FPR=<40-hex-digit fingerprint>." >&2
        return 1
    fi

    wget -q -O "$key" "$R2C_KERNEL_KEY_URL"
    actual=$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
    if [ "$actual" != "$expected" ]; then
        echo "Error: R2C kernel key fingerprint mismatch (expected $expected, got ${actual:-none})" >&2
        return 1
    fi

    install -D -m 0644 "$key" mnt/usr/share/nanopi-r2c-kernel-arch/key.pub
    run_arch_chroot pacman-key --add /usr/share/nanopi-r2c-kernel-arch/key.pub
    run_arch_chroot pacman-key --lsign-key "$expected"
}

add_r2c_kernel_repo() {
    if grep -q '^\[nanopi-r2c-kernel-arch\]' mnt/etc/pacman.conf; then
        return 0
    fi

    cat >> mnt/etc/pacman.conf <<EOF

[nanopi-r2c-kernel-arch]
SigLevel = Required
Server = ${R2C_KERNEL_REPO_URL}
EOF
}

is_stock_kernel_installed() {
    [ -n "$(find mnt/var/lib/pacman/local -mindepth 1 -maxdepth 1 -type d \
        -name 'linux-aarch64-[0-9]*' -print -quit)" ]
}

remove_stock_kernel_artifacts() {
    rm -f mnt/var/cache/pacman/pkg/linux-aarch64-*
    find mnt/usr/lib/modules -mindepth 1 -maxdepth 1 -type d \
        -name '*-aarch64-ARCH' -exec rm -rf {} +
}

remove_stock_kernel() {
    if ! is_stock_kernel_installed; then
        remove_stock_kernel_artifacts
        return 0
    fi

    echo "    → Removing stock linux-aarch64..."
    disable_chroot_pacman_hooks

    if ! run_chroot_pacman_no_hooks -Rdd linux-aarch64; then
        enable_chroot_pacman_hooks
        return 1
    fi

    enable_chroot_pacman_hooks
    remove_stock_kernel_artifacts
}

verify_minimal_kernel() {
    local kver unexpected

    if is_stock_kernel_installed; then
        echo "Error: linux-aarch64 is still installed after minimal kernel install" >&2
        return 1
    fi

    run_arch_chroot pacman -Q linux-nanopi-r2c-minimal >/dev/null
    kver=$(get_chroot_latest_kver)

    case "$kver" in
        *-nanopi-r2c-minimal) ;;
        *)
            echo "Error: expected minimal kernel modules, got: ${kver:-none}" >&2
            return 1
            ;;
    esac

    unexpected=$(find mnt/usr/lib/modules -mindepth 1 -maxdepth 1 -type d \
        ! -name '*-nanopi-r2c-minimal' -printf '%f\n' 2>/dev/null)

    if [ -n "$unexpected" ]; then
        echo "Error: unexpected kernel module directory after minimal install: $unexpected" >&2
        return 1
    fi
}

write_minimal_kernel_source_info() {
    local package version tag source_archive repo

    package="$(run_arch_chroot pacman -Q linux-nanopi-r2c-minimal)"
    version="${package#linux-nanopi-r2c-minimal }"
    tag="linux-nanopi-r2c-minimal-${version}"
    source_archive="${tag}-source.tar.zst"
    repo="https://github.com/therealcoder1337/nanopi-r2c-kernel-arch"

    cat > "$OUTPUT_DIR/SOURCE_INFO_R2C_KERNEL.txt" <<EOF
NanoPi R2C minimal kernel source — nanopi-r2c-arch images
=========================================================

The minimal-kernel SD card image contains ${package}.

The package is distributed by the nanopi-r2c-kernel-arch pacman repository:

  ${R2C_KERNEL_REPO_URL}

Corresponding source is published with the matching kernel package release:

  ${repo}/releases/tag/${tag}
  ${repo}/releases/download/${tag}/${source_archive}

That release also includes the merged kernel config and source information.
EOF
}

install_minimal_kernel() {
    local -a pkg=(linux-nanopi-r2c-minimal)
    [ -z "$R2C_KERNEL_PKGVER" ] || pkg=(linux-nanopi-r2c-minimal="$R2C_KERNEL_PKGVER")

    echo "    → Installing linux-nanopi-r2c-minimal from nanopi-r2c-kernel-arch..."
    set_chroot_resolver
    trust_r2c_kernel_key
    add_r2c_kernel_repo

    run_chroot_pacman -Sy
    remove_stock_kernel
    run_chroot_pacman_no_hooks -S "${pkg[@]}"

    verify_minimal_kernel
    write_minimal_kernel_source_info
}

configure_kernel_variant() {
    case "$KERNEL_VARIANT" in
        stock)
            echo "    → Kernel variant: stock linux-aarch64"
            ;;
        minimal)
            install_minimal_kernel
            ;;
    esac
}
