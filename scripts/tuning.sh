# SPDX-License-Identifier: GPL-2.0-or-later
# Appliance tuning: USTC mirrors, archlinuxcn, full upgrade, the generic USB
# automounter and image slimming. ksmbd-tools is installed but left disabled.

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

    # Keep ALARM's [aur] binary repository: it carries qt6-base-headless,
    # which qbittorrent-nox from [extra] needs (libQt6Core.so.6).

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
    echo "    → Installing appliance packages (parted, exfatprogs, dosfstools, ntfs-3g, ntfsprogs, zsh, sudo)..."
    run_chroot_pacman -S --needed parted exfatprogs dosfstools ntfs-3g ntfsprogs \
        zsh zsh-syntax-highlighting zsh-autosuggestions zsh-completions sudo

    # Nanopi appliance user: passwordless sudo via wheel.
    run_arch_chroot usermod -aG wheel "$APPLIANCE_USER"
    if [ -f mnt/etc/sudoers ]; then
        sed -i -E 's/^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL/%wheel ALL=(ALL:ALL) ALL/' mnt/etc/sudoers
    fi
}

build_aur_package() {
    local name="$1"
    local pkgdir="mnt/var/tmp/aur/$name"

    [ -d "$SCRIPT_DIR/packaging/$name" ] || {
        echo "Error: missing vendor packaging for $name" >&2
        exit 1
    }

    rm -rf "$pkgdir"
    install -d -m 0755 mnt/var/tmp/aur
    cp -a "$SCRIPT_DIR/packaging/$name" "$pkgdir"
    chown -R "${APPLIANCE_UID}:${APPLIANCE_GID}" mnt/var/tmp/aur

    run_arch_chroot test -d "/var/tmp/aur/$name" || {
        echo "Error: /var/tmp/aur/$name is not visible inside the chroot" >&2
        exit 1
    }

    echo "    → Building $name (aarch64 makepkg)..."
    run_arch_chroot su -s /bin/bash "$APPLIANCE_USER" -c \
        "export HOME=/home/$APPLIANCE_USER; cd /var/tmp/aur/$name && makepkg -f --nodeps --noconfirm"
}

install_aur_packages() {
    local cache="$CACHE_DIR/aur-packages"
    local name=ksmbd-tools

    echo "    → Installing ksmbd-tools (vendored AUR package)..."
    mkdir -p "$cache"
    rm -rf mnt/var/tmp/aur-pkgs
    install -d -m 0755 mnt/var/tmp/aur-pkgs

    if compgen -G "$cache/${name}-*.pkg.tar.*" >/dev/null; then
        echo "    → Using cached $name package"
        cp "$cache/${name}-"*.pkg.tar.* mnt/var/tmp/aur-pkgs/
    else
        run_chroot_pacman -S --needed base-devel git meson ninja intltool gettext

        build_aur_package "$name"
        cp mnt/var/tmp/aur/"$name"/*.pkg.tar.* "$cache"/
        cp mnt/var/tmp/aur/"$name"/*.pkg.tar.* mnt/var/tmp/aur-pkgs/

        # Drop the build toolchain again; runtime deps (glib2, libnl) stay.
        run_chroot_pacman -Rns --noconfirm base-devel >/dev/null 2>&1 || true
        run_chroot_pacman -Rns --noconfirm git meson ninja intltool >/dev/null 2>&1 || true
        rm -rf mnt/var/tmp/aur
    fi

    run_arch_chroot sh -c 'pacman -U --noconfirm /var/tmp/aur-pkgs/*.pkg.tar.*'
    rm -rf mnt/var/tmp/aur-pkgs
}

configure_usb_mount() {
    echo "    → Installing generic USB automounter (any filesystem, any label)..."

    install -D -m 0755 "$TEMPLATES_DIR/usb-mount" mnt/usr/local/sbin/usb-mount
    install -D -m 0644 "$TEMPLATES_DIR/usb-mount.conf" mnt/etc/usb-mount.conf
    install -D -m 0644 "$TEMPLATES_DIR/usb-mount@.service" \
        mnt/etc/systemd/system/usb-mount@.service
    install -D -m 0644 "$TEMPLATES_DIR/90-usb-mount.rules" \
        mnt/etc/udev/rules.d/90-usb-mount.rules
    install -D -m 0644 "$TEMPLATES_DIR/ksmbd-usb-mount.conf" \
        mnt/etc/systemd/system/ksmbd.service.d/usb-mount.conf

    # Mounted files must belong to the appliance user, not to root.
    sed -i -E \
        "s/^OWNER_UID=.*/OWNER_UID=${APPLIANCE_UID}/; s/^OWNER_GID=.*/OWNER_GID=${APPLIANCE_GID}/" \
        mnt/etc/usb-mount.conf
}

configure_zsh() {
    echo "    → Installing zsh setup for $APPLIANCE_USER and root..."

    install -D -m 0644 "$TEMPLATES_DIR/zshrc" "mnt/home/$APPLIANCE_USER/.zshrc"
    install -D -m 0644 "$TEMPLATES_DIR/zshrc" mnt/root/.zshrc
    chown "$APPLIANCE_UID:$APPLIANCE_GID" "mnt/home/$APPLIANCE_USER/.zshrc"

    run_arch_chroot usermod -s /usr/bin/zsh "$APPLIANCE_USER"
    run_arch_chroot usermod -s /usr/bin/zsh root
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
    local -a remove=(nano netctl dhcpcd net-tools)
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

    # pacman -Scc answers "no" to the cache prompt under --noconfirm, and the
    # firmware slim-down downloads again afterwards; drop the cache for real.
    rm -rf mnt/var/cache/pacman/pkg/*

    # Only the R2C device tree and the raw kernel image are used by boot.scr.
    rm -f mnt/boot/Image.gz
    find mnt/boot/dtbs -mindepth 1 -maxdepth 1 -type d ! -name rockchip -exec rm -rf {} + 2>/dev/null || true
}

verify_appliance_stack() {
    echo "    → Verifying appliance stack..."

    local failures=0

    if [ -x mnt/usr/local/sbin/usb-mount ] &&
        [ -f mnt/etc/udev/rules.d/90-usb-mount.rules ] &&
        [ -f mnt/etc/systemd/system/usb-mount@.service ] &&
        [ -f mnt/etc/systemd/system/ksmbd.service.d/usb-mount.conf ]; then
        echo "       usb automount: OK (udev + systemd, no setuid helper)"
    else
        echo "       usb automount: FAIL (helper, udev rule, unit or ksmbd drop-in missing)" >&2
        failures=1
    fi

    if run_arch_chroot test -x /usr/bin/mkntfs; then
        echo "       ntfs tools: OK (ntfs-3g + ntfsprogs)"
    else
        echo "       ntfs tools: FAIL (mkntfs missing)" >&2
        failures=1
    fi

    if run_arch_chroot bash -n /usr/local/sbin/usb-mount; then
        echo "       usb automount helper: OK (syntax)"
    else
        echo "       usb automount helper: FAIL (syntax)" >&2
        failures=1
    fi

    if run_arch_chroot udevadm verify /etc/udev/rules.d/90-usb-mount.rules >/dev/null 2>&1; then
        echo "       usb automount udev rule: OK (syntax)"
    else
        echo "       usb automount udev rule: FAIL (syntax)" >&2
        failures=1
    fi

    if grep -q 'usb-mount@%k.service' mnt/etc/udev/rules.d/90-usb-mount.rules; then
        echo "       usb automount rule: OK (hotplug -> usb-mount@.service)"
    else
        echo "       usb automount rule: FAIL (missing SYSTEMD_WANTS/RUN)" >&2
        failures=1
    fi

    if [ ! -e mnt/usr/bin/udevil ] && [ ! -e mnt/usr/bin/devmon ]; then
        echo "       udevil: OK (not installed)"
    else
        echo "       udevil: FAIL (udevil/devmon still installed)" >&2
        failures=1
    fi

    if grep -q '^\[aur\]' mnt/etc/pacman.conf; then
        echo "       pacman [aur]: OK (qt6-base-headless available)"
    else
        echo "       pacman [aur]: FAIL (ALARM [aur] repo was removed)" >&2
        failures=1
    fi

    if [ -x mnt/usr/bin/zsh ] &&
        [ -f mnt/usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] &&
        [ -f mnt/usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ] &&
        [ -f "mnt/home/$APPLIANCE_USER/.zshrc" ] && [ -f mnt/root/.zshrc ]; then
        echo "       zsh: OK (highlighting + autosuggestions, alarm and root)"
    else
        echo "       zsh: FAIL (packages, plugins or .zshrc missing)" >&2
        failures=1
    fi

    if grep -qE "^${APPLIANCE_USER}:.*:/usr/bin/zsh$" mnt/etc/passwd &&
        grep -qE '^root:.*:/usr/bin/zsh$' mnt/etc/passwd; then
        echo "       zsh login shells: OK (alarm, root)"
    else
        echo "       zsh login shells: FAIL (alarm/root still use another shell)" >&2
        failures=1
    fi

    if run_arch_chroot zsh -n /root/.zshrc; then
        echo "       zsh rc: OK (syntax)"
    else
        echo "       zsh rc: FAIL (syntax)" >&2
        failures=1
    fi

    # /usr/bin/ksmbd.mountd is an absolute symlink into /usr/lib/ksmbd-tools;
    # test it inside the chroot, not against the build host's root.
    if run_arch_chroot test -x /usr/bin/ksmbd.mountd; then
        echo "       ksmbd: OK (tools installed)"
    else
        echo "       ksmbd: FAIL (ksmbd.mountd missing)" >&2
        failures=1
    fi

    if [ -e mnt/etc/systemd/system/multi-user.target.wants/ksmbd.service ]; then
        echo "       ksmbd service: FAIL (enabled at boot; must be manual)" >&2
        failures=1
    else
        echo "       ksmbd service: OK (disabled, manual start)"
    fi

    if grep -qE "^wheel:.*[[:space:],:]${APPLIANCE_USER}(,|$)" mnt/etc/group; then
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

    if [ -x mnt/usr/bin/nft ]; then
        echo "       firewall: OK (nft; iptables kept for iproute2's libxtables)"
    else
        echo "       firewall: FAIL (nft missing)" >&2
        failures=1
    fi

    [ "$failures" -eq 0 ] || {
        echo "Error: appliance stack verification failed" >&2
        exit 1
    }
}
