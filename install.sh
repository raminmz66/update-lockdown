#!/usr/bin/env bash
#
# Installs update-lockdown and enables the boot-time enforcement unit.
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/bin/update-lockdown
UNIT=/etc/systemd/system/update-lockdown.service

[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo" >&2; exit 3; }

install -m 0755 "$SRC/update-lockdown" "$BIN"
install -m 0644 "$SRC/systemd/update-lockdown.service" "$UNIT"
systemctl daemon-reload
systemctl enable update-lockdown.service >/dev/null

cat <<DONE

Installed:
  $BIN
  $UNIT  (enabled - re-applies the lockdown at every boot)

Next steps:
  sudo update-lockdown lock      freeze background updates
       update-lockdown status    see what is frozen
  sudo update-lockdown unlock    put everything back exactly as it was

The boot unit stays inert until you run 'lock' at least once.
DONE
