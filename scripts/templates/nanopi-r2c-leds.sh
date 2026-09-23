#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

LAN_IFACE=""
WAN_IFACE=""

find_iface_by_driver() {
    local wanted="$1"
    local netdir iface driver_path

    for netdir in /sys/class/net/*; do
        iface="${netdir##*/}"
        [ "$iface" = "lo" ] && continue
        driver_path="$(readlink -f "$netdir/device/driver" 2>/dev/null || true)"
        [ -n "$driver_path" ] || continue
        [ "${driver_path##*/}" = "$wanted" ] || continue
        printf '%s\n' "$iface"
        return 0
    done
    return 1
}

wait_for_network_devices() {
    local attempt

    for attempt in {1..8}; do
        [ -n "$LAN_IFACE" ] || LAN_IFACE="$(find_iface_by_driver r8152 || true)"
        [ -n "$WAN_IFACE" ] || WAN_IFACE="$(find_iface_by_driver rk_gmac-dwmac || true)"
        [ -z "$LAN_IFACE" ] || [ -z "$WAN_IFACE" ] || return 0
        sleep 1
    done
}

configure_led() {
    local led="$1"
    local iface="$2"
    local led_dir="/sys/class/leds/$led"
    local attr

    [ -n "$iface" ] || return 0
    [ -d "$led_dir" ] || return 0

    printf '%s\n' netdev > "$led_dir/trigger" 2>/dev/null || return 0
    printf '%s\n' "$iface" > "$led_dir/device_name" 2>/dev/null || true
    for attr in link rx tx; do
        printf '1\n' > "$led_dir/$attr" 2>/dev/null || true
    done
}

wait_for_network_devices
configure_led "nanopi-r2c:green:lan" "$LAN_IFACE"
configure_led "nanopi-r2c:green:wan" "$WAN_IFACE"
