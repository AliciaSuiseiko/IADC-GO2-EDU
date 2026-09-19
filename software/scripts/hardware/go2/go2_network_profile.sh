#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
IFACE="${GO2_IFACE:-eth0}"
GO2_PROFILE="${GO2_PROFILE:-Go2 Wired}"
MID360_PROFILE="${MID360_PROFILE:-有线连接 1}"

show_status() {
  ip -brief link show "$IFACE"
  ip -brief address show "$IFACE"
  nmcli -f NAME,TYPE,DEVICE,AUTOCONNECT connection show | \
    grep -E "(^NAME|$GO2_PROFILE|$MID360_PROFILE)" || true
}

case "$ACTION" in
  prepare)
    if ! nmcli -t -f NAME connection show | grep -Fxq "$GO2_PROFILE"; then
      sudo nmcli connection add type ethernet ifname "$IFACE" con-name "$GO2_PROFILE" \
        ipv4.method manual ipv4.addresses 192.168.123.99/24 \
        ipv4.never-default yes ipv6.method disabled connection.autoconnect no
    fi
    nmcli connection show "$GO2_PROFILE"
    ;;
  up)
    if ! ip link show "$IFACE" | grep -q 'LOWER_UP'; then
      echo "BLOCKED: $IFACE has no carrier. Connect the Jetson to Go2 Ethernet first." >&2
      exit 2
    fi
    sudo nmcli connection up "$GO2_PROFILE"
    show_status
    ;;
  mid360)
    if ! ip link show "$IFACE" | grep -q 'LOWER_UP'; then
      echo "BLOCKED: $IFACE has no carrier. Connect the Mid-360 Ethernet first." >&2
      exit 2
    fi
    sudo nmcli connection up "$MID360_PROFILE"
    show_status
    ;;
  down)
    sudo nmcli connection down "$GO2_PROFILE" 2>/dev/null || true
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {prepare|up|mid360|down|status}" >&2
    exit 2
    ;;
esac
