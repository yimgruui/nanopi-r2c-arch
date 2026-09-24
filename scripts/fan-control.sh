# SPDX-License-Identifier: GPL-2.0-or-later
# Fan speed control (vendored avafinger/fan-speed-control). Cross-compiled on
# the build host and installed into the image rootfs with its systemd unit.

# For normal-polarity PWM fans build with: FAN_CONTROL_EXTRAFLAGS='-DPOLARITY=1'
# (the default build targets inverted polarity, the common 2-wire fan case).
FAN_CONTROL_EXTRAFLAGS="${FAN_CONTROL_EXTRAFLAGS:-}"

verify_fan_pwm0() {
    # fan-monitor drives /sys/class/pwm/pwmchip0/pwm0; the NanoPi R2C dtb must
    # enable pwm0 (RK3328 node /pwm@ff1b0000). We deliberately do NOT patch the
    # dtb in the build: fdtput-patching broke boot on this image. Without pwm0
    # the fan-monitor service simply fails at runtime, which does not affect
    # system boot.
    local dtb="$1" status
    status=$(fdtget -t s "$dtb" /pwm@ff1b0000 status 2>/dev/null || echo "")
    if [ "$status" = "okay" ]; then
        echo "    -> dtb enables pwm0 - fan control ready"
    else
        echo "       Note: dtb leaves pwm0 '${status:-absent}'; fan-monitor will not run" >&2
        echo "             until pwm0 is enabled in the dtb (future validated dtb work)." >&2
    fi
}

install_fan_control() {
    echo "    -> Installing fan speed control (fan-monitor64)..."

    verify_fan_pwm0 "mnt/boot/dtbs/$BOOT_DTB"

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
    echo "       Curve: 51C->5% 52C->10% 54C->20% 55C->30% 58C->50% 63C->70% 75C->100%"
}
