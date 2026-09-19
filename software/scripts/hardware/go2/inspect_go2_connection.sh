#!/usr/bin/env bash
set -euo pipefail

ROOT="${LIANAIWEI_ROOT:-$HOME/lianaiwei}"
IFACE="${GO2_IFACE:-eth0}"
LOG_DIR="$ROOT/logs/hardware/go2/inspect-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

if ! ip link show "$IFACE" | grep -q 'LOWER_UP'; then
  echo "BLOCKED: $IFACE has no carrier" | tee "$LOG_DIR/status.txt"
  exit 2
fi
if ! ip -4 address show "$IFACE" | grep -q '192\.168\.123\.99/24'; then
  echo "BLOCKED: $IFACE is not using the Go2 profile (192.168.123.99/24)" | \
    tee "$LOG_DIR/status.txt"
  exit 2
fi

source "$ROOT/scripts/hardware/go2/unitree_go2_env.sh"
timeout 12 ros2 topic list >"$LOG_DIR/topics.txt" 2>"$LOG_DIR/ros2.err" || true

if grep -Fxq '/sportmodestate' "$LOG_DIR/topics.txt"; then
  timeout 8 ros2 topic echo --once /sportmodestate \
    >"$LOG_DIR/sportmodestate.txt" 2>"$LOG_DIR/sportmodestate.err" || true
  echo "COMPLETE: Go2 DDS discovered; read-only state captured" | tee "$LOG_DIR/status.txt"
else
  echo "PARTIAL: Ethernet is configured, but /sportmodestate was not discovered" | \
    tee "$LOG_DIR/status.txt"
  exit 3
fi
