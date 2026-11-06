# SPDX-License-Identifier: GPL-2.0-or-later
# Appliance tuning: USTC mirrors, archlinuxcn, full upgrade, udevil,
# ksmbd, pruning and image slimming.

APPLIANCE_USER="${APPLIANCE_USER:-alarm}"
APPLIANCE_UID="${APPLIANCE_UID:-1000}"
APPLIANCE_GID="${APPLIANCE_GID:-1000}"

configure_image_repos() {
    echo "    → Configuring pacman repos (USTC + archlinuxcn)..."

    set_chroot_resolver

    cat > mnt/etc/pacman.d/mirrorlist <<'EOF'
# Arch Linux ARM — USTC mirror
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
EOF

    # ALARM ships an almost-empty [aur] binary repo; drop it.
    if grep -q '^\[aur\]' mnt/etc/pacman.conf; then
        awk '
            /^\[aur\]/ { skip = 1; next }
            /^\[/ { skip = 0 }
            !skip { print }
        ' mnt/etc/pacman.conf > mnt/etc/pacman.conf.nanopi
        mv mnt/etc/pacman.conf.nanopi mnt/etc/pacman.conf
    fi

    if ! grep -q '^\[archlinuxcn\]' mnt/etc/pacman.conf; then
        cat >> mnt/etc/pacman.conf <<'EOF'

[archlinuxcn]
SigLevel = Never
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
EOF
    fi
}

install_archlinuxcn_keyring() {
    echo "    → Installing archlinuxcn keyring..."
    run_chroot_pacman -Sy
    run_chroot_pacman -S --needed archlinuxcn-keyring
    run_arch_chroot pacman-key --populate archlinuxcn

    # The keyring is installed; require signatures from now on.
    awk '
        /^\[archlinuxcn\]/ { print; print "SigLevel = Required DatabaseOptional"; next }
        /^SigLevel = Never$/ { next }
        { print }
    ' mnt/etc/pacman.conf > mnt/etc/pacman.conf.nanopi
    mv mnt/etc/pacman.conf.nanopi mnt/etc/pacman.conf
}

system_upgrade() {
    echo "    → Upgrading all packages to the latest versions..."
    run_chroot_pacman -Syu
    run_arch_chroot pacman-key --populate archlinuxarm >/dev/null 2>&1 || true
}

install_appliance_packages() {
    echo "    → Installing appliance packages (parted, exfatprogs, sudo)..."
    run_chroot_pacman -S --needed parted exfatprogs sudo

    # Nanopi appliance user: passwordless sudo via wheel.
    run_arch_chroot usermod -aG wheel "$APPLIANCE_USER"
    if [ -f mnt/etc/sudoers ]; then
        sed -i -E 's/^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL/%wheel ALL=(ALL:ALL) ALL/' mnt/etc/sudoers
    fi
    install -d -o "$APPLIANCE_UID" -g "$APPLIANCE_GID" -m 0775 mnt/srv/ksmbd
}

build_aur_package() {
    local name="$1"
    local pkgdir="mnt/tmp/aur/$name"

    [ -d "$SCRIPT_DIR/packaging/$name" ] || {
        echo "Error: missing vendor packaging for $name" >&2
        exit 1
    }

    rm -rf "$pkgdir"
    install -d -m 0755 mnt/tmp/aur
    cp -a "$SCRIPT_DIR/packaging/$name" "$pkgdir"
    chown -R "${APPLIANCE_UID}:${APPLIANCE_GID}" mnt/tmp/aur

    echo "    → Building $name (aarch64 makepkg)..."
    run_arch_chroot su -s /bin/bash "$APPLIANCE_USER" -c \
        "export HOME=/home/$APPLIANCE_USER; cd /tmp/aur/$name && makepkg -f --nodeps --noconfirm"
}

install_aur_packages() {
    local cache="$CACHE_DIR/aur-packages"
    local -a to_build=()
    local name

    echo "    → Installing udevil and ksmbd-tools (vendored AUR packages)..."
    mkdir -p "$cache"
    rm -rf mnt/tmp/aur-pkgs
    install -d -m 0755 mnt/tmp/aur-pkgs

    for name in udevil ksmbd-tools; do
        if compgen -G "$cache/${name}-*.pkg.tar.zst" >/dev/null; then
            echo "    → Using cached $name package"
            cp "$cache/${name}-"*.pkg.tar.zst mnt/tmp/aur-pkgs/
        else
            to_build+=("$name")
        fi
    done

    if [ "${#to_build[@]}" -gt 0 ]; then
        run_chroot_pacman -S --needed base-devel git meson ninja intltool gettext

        for name in "${to_build[@]}"; do
            build_aur_package "$name"
            cp mnt/tmp/aur/"$name"/*.pkg.tar.zst "$cache"/
            cp mnt/tmp/aur/"$name"/*.pkg.tar.zst mnt/tmp/aur-pkgs/
        done

        # Drop the build toolchain again; runtime deps (glib2, libnl) stay.
        run_chroot_pacman -Rns --noconfirm base-devel >/dev/null 2>&1 || true
        run_chroot_pacman -Rns --noconfirm git meson ninja intltool >/dev/null 2>&1 || true
        rm -rf mnt/tmp/aur
    fi

    run_arch_chroot pacman -U --noconfirm /tmp/aur-pkgs/*.pkg.tar.zst
    rm -rf mnt/tmp/aur-pkgs
}

configure_udevil() {
    local conf="mnt/etc/udevil/udevil.conf"

    echo "    → Configuring udevil (user $APPLIANCE_USER, exFAT fix)..."
    if [ ! -f "$conf" ]; then
        echo "Error: udevil did not install $conf" >&2
        exit 1
    fi

    sed -i -E "s/^allowed_users[[:space:]]*=.*/allowed_users = ${APPLIANCE_USER}/" "$conf"

    # The stock exFAT options contain vfat-only 'namecase=0', which the kernel
    # exFAT driver rejects. Also give the appliance user clean permissions.
    sed -i -E "s|^default_options_exfat.*|default_options_exfat = nosuid, noexec, nodev, noatime, uid=\$UID, gid=\$GID, umask=0022|" "$conf"
    sed -i -E "s|^allowed_options_exfat.*|allowed_options_exfat = nosuid, noexec, nodev, noatime, uid=\$UID, gid=\$GID, umask=*, ro, rw, sync, flush, iocharset=*, remount, nonempty|" "$conf"

    install -D -m 0644 "$TEMPLATES_DIR/devmon.service" mnt/etc/systemd/system/devmon.service
    run_arch_chroot systemctl enable devmon.service
}

configure_ksmbd() {
    echo "    → Configuring ksmbd (SMB shares for /media and /srv/ksmbd)..."

    install -d -m 0755 mnt/etc/ksmbd mnt/etc/modules-load.d
    cat > mnt/etc/ksmbd/ksmbd.conf <<EOF
[global]
    server string = NanoPi R2C
    workgroup = WORKGROUP
    security = user
    map to guest = Bad User

[media]
    path = /media
    guest ok = yes
    read only = no
    force user = ${APPLIANCE_USER}
    force group = ${APPLIANCE_USER}
    create mask = 0664
    directory mask = 0775

[share]
    path = /srv/ksmbd
    guest ok = yes
    read only = no
    force user = ${APPLIANCE_USER}
    force group = ${APPLIANCE_USER}
    create mask = 0664
    directory mask = 0775
EOF

    echo "ksmbd" > mnt/etc/modules-load.d/ksmbd.conf

    if [ ! -f mnt/usr/lib/systemd/system/ksmbd.service ]; then
        cat > mnt/etc/systemd/system/ksmbd.service <<'EOF'
[Unit]
Description=ksmbd SMB server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ksmbd.mountd -n
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    fi

    run_arch_chroot systemctl enable ksmbd.service
}

configure_default_editor() {
    echo "    → Setting vim as the default editor..."

    install -d -m 0755 mnt/etc/profile.d
    cat > mnt/etc/profile.d/editor.sh <<'EOF'
export EDITOR=vim
export VISUAL=vim
EOF

    touch mnt/etc/environment
    local kv
    for kv in "EDITOR=vim" "VISUAL=vim"; do
        grep -qx "$kv" mnt/etc/environment || printf '%s\n' "$kv" >> mnt/etc/environment
    done

    # visudo / sudoedit use the sudo 'editor' Defaults rather than $EDITOR.
    if [ -f mnt/etc/sudoers ]; then
        grep -q '^Defaults editor=' mnt/etc/sudoers \
            || echo 'Defaults editor=/usr/bin/vim' >> mnt/etc/sudoers
        run_arch_chroot visudo -c >/dev/null
    fi
}

prune_packages() {
    local -a remove=(nano netctl dhcpcd net-tools iptables)
    local -a installed=()
    local p

    for p in "${remove[@]}"; do
        if run_arch_chroot pacman -Q "$p" >/dev/null 2>&1; then
            installed+=("$p")
        fi
    done

    if [ "${#installed[@]}" -gt 0 ]; then
        echo "    → Removing unused packages: ${installed[*]}"
        run_chroot_pacman -Rns "${installed[@]}"
    fi

    run_chroot_pacman -Scc
}

strip_image() {
    echo "    → Stripping docs, man pages, unused locales and DTBs..."

    rm -rf mnt/usr/share/doc mnt/usr/share/man mnt/usr/share/info mnt/usr/share/help
    find mnt/usr/share/locale -mindepth 1 -maxdepth 1 \
        ! -name 'en*' ! -name 'zh_CN' ! -name 'zh_TW' -exec rm -rf {} + 2>/dev/null || true
    rm -rf mnt/usr/share/i18n

    # Only the R2C device tree and the raw kernel image are used by boot.scr.
    rm -f mnt/boot/Image.gz
    find mnt/boot/dtbs -mindepth 1 -maxdepth 1 -type d ! -name rockchip -exec rm -rf {} + 2>/dev/null || true
}

verify_appliance_stack() {
    echo "    → Verifying appliance stack..."

    local failures=0

    if [ ! -u mnt/usr/bin/udevil ]; then
        echo "       udevil: FAIL (missing or not setuid)" >&2
        failures=1
    else
        echo "       udevil: OK (setuid)"
    fi

    if grep -q 'namecase' mnt/etc/udevil/udevil.conf; then
        echo "       udevil exFAT options: FAIL (namecase still present)" >&2
        failures=1
    else
        echo "       udevil exFAT options: OK"
    fi

    if [ ! -x mnt/usr/bin/ksmbd.mountd ]; then
        echo "       ksmbd: FAIL (ksmbd.mountd missing)" >&2
        failures=1
    else
        echo "       ksmbd: OK"
    fi

    if grep -qE "^wheel:.*[[:space:],]${APPLIANCE_USER}(,|$)" mnt/etc/group; then
        echo "       wheel group: OK"
    else
        echo "       wheel group: FAIL ($APPLIANCE_USER missing)" >&2
        failures=1
    fi

    if [ -x mnt/usr/bin/vim ] && [ ! -e mnt/usr/bin/nano ] && grep -qx 'EDITOR=vim' mnt/etc/environment; then
        echo "       editor: OK (vim default, nano absent)"
    else
        echo "       editor: FAIL (vim missing, nano present, or EDITOR unset)" >&2
        failures=1
    fi

    if [ ! -e mnt/usr/bin/iptables ]; then
        echo "       firewall: OK (nftables only)"
    else
        echo "       firewall: FAIL (iptables still installed)" >&2
        failures=1
    fi

    [ "$failures" -eq 0 ] || {
        echo "Error: appliance stack verification failed" >&2
        exit 1
    }
}
