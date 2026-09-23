# SPDX-License-Identifier: GPL-2.0-or-later
# Fan speed control (vendored avafinger/fan-speed-control). Cross-compiled on
# the build host and installed into the image rootfs with its systemd unit.

# For normal-polarity PWM fans build with: FAN_CONTROL_EXTRAFLAGS='-DPOLARITY=1'
# (the default build targets inverted polarity, the common 2-wire fan case).
FAN_CONTROL_EXTRAFLAGS="${FAN_CONTROL_EXTRAFLAGS:-}"

enable_fan_pwm0() {
    # Ensure the NanoPi R2C dtb exposes pwm0 (RK3328 node /pwm@ff1b0000) so
    # fan-monitor can drive /sys/class/pwm/pwmchip0/pwm0. Patches the dtb
    # in place inside the image — no kernel package changes required.
    local dtb="$1" status pinph

    status=$(fdtget -t s "$dtb" /pwm@ff1b0000 status 2>/dev/null || echo "")

    if [ "$status" = "okay" ]; then
        echo "    → dtb already enables pwm0"
        return 0
    fi

    echo "    → Enabling pwm0 in dtb (was '${status:-absent}')..."

    fdtput -t s "$dtb" /pwm@ff1b0000 status okay || {
        echo "Error: fdtput failed on $dtb (/pwm@ff1b0000 status)" >&2
        exit 1
    }

    # rk3328.dtsi keeps pinctrl-0 on disabled nodes; if this node lacks it,
    # restore the pinmux from the pwm0-pin pinctrl entry.
    if ! fdtget "$dtb" /pwm@ff1b0000 pinctrl-0 >/dev/null 2>&1; then
        pinph=$(fdtget "$dtb" /pinctrl/pwm0/pwm0-pin 2>/dev/null || echo "")
        if [ -n "$pinph" ]; then
            fdtput -t x "$dtb" /pwm@ff1b0000 pinctrl-0 "$pinph"
            echo "       pinctrl-0 restored (pwm0-pin phandle $pinph)"
        else
            echo "       Warning: /pwm@ff1b0000 lacks pinctrl-0 and pwm0-pin was not found;" >&2
            echo "               pwm signal may not reach the pin." >&2
        fi
    fi

    echo "       pwm0 enabled in $dtb"
}

install_fan_control() {
    echo "    → Installing fan speed control (fan-monitor64)..."

    enable_fan_pwm0 "mnt/boot/dtbs/$BOOT_DTB"

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
