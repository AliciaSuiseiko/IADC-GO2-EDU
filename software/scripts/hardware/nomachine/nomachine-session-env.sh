#!/usr/bin/env bash

# Source the active NoMachine GNOME session environment from an SSH shell.
_nx_gnome_pid="$(pgrep -u "$USER" -x gnome-shell | head -n 1)"
if [[ -z "$_nx_gnome_pid" || ! -r "/proc/$_nx_gnome_pid/environ" ]]; then
  echo "No active NoMachine GNOME desktop was found." >&2
  return 1 2>/dev/null || exit 1
fi

while IFS= read -r -d '' _nx_entry; do
  case "$_nx_entry" in
    DISPLAY=*|XAUTHORITY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*)
      export "$_nx_entry"
      ;;
  esac
done < "/proc/$_nx_gnome_pid/environ"

unset _nx_entry _nx_gnome_pid
