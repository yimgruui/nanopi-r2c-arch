# SPDX-License-Identifier: GPL-2.0-or-later
# Fan speed control (vendored avafinger/fan-speed-control). Cross-compiled on
# the build host and installed into the image rootfs with its systemd unit.

# For normal-polarity PWM fans build with: FAN_CONTROL_EXTRAFLAGS='-DPOLARITY=1'
# (the default build targets inverted polarity, the common 2-wire fan case).
FAN_CONTROL_EXTRAFLAGS="${FAN_CONTROL_EXTRAFLAGS:-}"

verify_fan_pwm_node() {
    # fan-monitor drives /sys/class/pwm/pwmchip0/pwm0; the NanoPi R2C dtb must
    # enable pwm0 (RK3328 pwm0 node lives at /pwm@ff1b0000).
    local dtb="$1" status
    status=$(fdtget -t s "$dtb" /pwm@ff1b0000 status 2>/dev/null || echo "")
    if [ "$status" = "okay" ]; then
        echo "    → dtb enables pwm0 — fan control ready"
    else
        echo "       Warning: dtb does not enable pwm0 (status='${status:-absent}')." >&2
        echo "               fan-monitor will not run until the dtb exposes pwm0." >&2
    fi
}

install_fan_control() {
    echo "    → Installing fan speed control (fan-monitor64)..."

    verify_fan_pwm_node "mnt/boot/dtbs/$BOOT_DTB"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Cross-compile on the build host; no toolchain inside the image.
    aarch64-linux-gnu-gcc -O2 -Wall -DNEBUG ${FAN_CONTROL_EXTRAFLAGS} \
        -o "$tmpdir/fan-monitor64" \
        "$SCRIPT_DIR/vendor/fan-monitor/fan-monitor.c" -lrt

    install -Dm0755 "$tmpdir/fan-monitor64" mnt/usr/local/bin/fan-monitor64
    install -Dm0644 "$SCRIPT_DIR/vendor/fan-monitor/fan-monitor.service" \
        mnt/etc/systemd/system/fan-monitor.service

    mkdir -p mnt/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/fan-monitor.service \
        mnt/etc/systemd/system/multi-user.target.wants/fan-monitor.service

    rm -rf "$tmpdir"

    echo "       fan-monitor64 installed; fan-monitor.service enabled"
    echo "       Curve: 51°C→5% 52°C→10% 54°C→20% 55°C→30% 58°C→50% 63°C→70% 75°C→100%"
}
