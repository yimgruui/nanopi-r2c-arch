#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

# Resolve the PWM controller that the device tree actually enables instead of
# assuming pwmchip0. On the NanoPi R2 family the fan header is wired to PWM2
# (rk3328 /pwm@ff1b0020), but the sysfs chip index depends on probe order and
# on the kernel version.
chip=""

for dir in /sys/class/pwm/pwmchip*; do
    [ -d "$dir" ] || continue

    node="$(readlink -f "$dir/device/of_node" 2>/dev/null || true)"
    [ -n "$node" ] && [ -d "$node" ] || continue

    [ -f "$node/status" ] || continue
    status="$(tr -d '\0' < "$node/status")"
    [ "$status" = "okay" ] || continue

    chip="${dir##*pwmchip}"
    break
done

if [ -z "$chip" ]; then
    echo "fan-monitor: no enabled PWM controller in the device tree; fan control skipped" >&2
    exit 0
fi

export FAN_PWM_CHIP="$chip"
export FAN_PWM_CHANNEL="0"

exec /usr/local/bin/fan-monitor64
