#!/usr/bin/env bash

set -euo pipefail

mode="${1:-status}"
nxserver=/usr/NX/bin/nxserver

if [[ ! -x "$nxserver" ]]; then
  echo "NoMachine server was not found at $nxserver." >&2
  exit 1
fi

show_status() {
  echo "default_target=$(systemctl get-default)"
  echo "display_manager=$(systemctl is-active display-manager 2>/dev/null || true)"
  echo "nomachine=$(systemctl is-active nxserver 2>/dev/null || true)"
  echo "tailscale=$(systemctl is-active tailscaled 2>/dev/null || true)"
  echo "x_servers=$(pgrep -fc 'Xorg|Xwayland' || true)"
}

case "$mode" in
  status)
    show_status
    ;;
  headless)
    # NoMachine's documented headless mode requires the physical X server to
    # be stopped so its embedded X server can provide the remote desktop.
    # Keep graphical.target for the next boot; the automatic selector will
    # choose physical or headless mode from the actual DP connection state.
    sudo systemctl set-default graphical.target
    sudo systemctl stop display-manager
    sudo "$nxserver" --restart
    show_status
    ;;
  shared)
    # GDM auto-login provides one GNOME desktop. A local monitor and NoMachine
    # then show the same session; NVIDIA's Xorg config permits it headless too.
    sudo systemctl set-default graphical.target
    sudo systemctl start display-manager
    sudo "$nxserver" --restart
    show_status
    ;;
  local)
    # Backwards-compatible alias for the shared local/remote desktop.
    sudo systemctl set-default graphical.target
    sudo systemctl start display-manager
    sudo "$nxserver" --restart
    show_status
    ;;
  *)
    echo "Usage: $0 {status|headless|shared|local}" >&2
    exit 2
    ;;
esac
