# SPDX-License-Identifier: GPL-2.0-or-later
# Fan speed control (vendored avafinger/fan-speed-control). Cross-compiled on
# the build host and installed into the image rootfs with its systemd unit.

# For normal-polarity PWM fans build with: FAN_CONTROL_EXTRAFLAGS='-DPOLARITY=1'
# (the default build targets inverted polarity, the common 2-wire fan case).
FAN_CONTROL_EXTRAFLAGS="${FAN_CONTROL_EXTRAFLAGS:-}"

# PWM controllers in rk3328.dtsi, in probe order.
FAN_PWM_NODES=(/pwm@ff1b0000 /pwm@ff1b0010 /pwm@ff1b0020 /pwm@ff1b0030)

verify_fan_pwm() {
    # The fan header on the NanoPi R2 family is wired to PWM2
    # (/pwm@ff1b0020). Do not patch the dtb (that broke boot on this image);
    # just report which controller is enabled, because the runtime wrapper
    # resolves the pwmchip index from /sys/class/pwm/pwmchip*/device/of_node.
    local dtb="$1" node status index=0 enabled=""

    for node in "${FAN_PWM_NODES[@]}"; do
        status=$(fdtget -t s "$dtb" "$node" status 2>/dev/null || echo "")
        if [ "$status" = "okay" ]; then
            enabled="${enabled}${enabled:+, }${node} (pwmchip${index})"
        fi
        index=$((index + 1))
    done

    if [ -n "$enabled" ]; then
        echo "    -> dtb enables ${enabled}; fan-monitor picks it at runtime"
    else
        echo "       Note: dtb enables no PWM controller; fan-monitor will no-op" >&2
        echo "             (the fan is optional and this does not affect boot)" >&2
    fi
}

install_fan_control() {
    echo "    -> Installing fan speed control (fan-monitor64)..."

    verify_fan_pwm "mnt/boot/dtbs/$BOOT_DTB"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Cross-compile on the build host; no toolchain inside the image.
    aarch64-linux-gnu-gcc -O2 -Wall -DNDEBUG ${FAN_CONTROL_EXTRAFLAGS} \
        -o "$tmpdir/fan-monitor64" \
        "$SCRIPT_DIR/vendor/fan-monitor/fan-monitor.c" -lrt

    install -Dm0755 "$tmpdir/fan-monitor64" mnt/usr/local/bin/fan-monitor64
    install -Dm0755 "$TEMPLATES_DIR/fan-monitor-start.sh" \
        mnt/usr/local/sbin/fan-monitor-start.sh
    install -Dm0644 "$SCRIPT_DIR/vendor/fan-monitor/fan-monitor.service" \
        mnt/etc/systemd/system/fan-monitor.service

    mkdir -p mnt/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/fan-monitor.service \
        mnt/etc/systemd/system/multi-user.target.wants/fan-monitor.service

    rm -rf "$tmpdir"

    echo "       fan-monitor64 installed; fan-monitor.service enabled"
    echo "       Curve: 51C->5% 52C->10% 54C->20% 55C->30% 58C->50% 63C->70% 75C->100%"
}
