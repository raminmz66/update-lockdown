#!/usr/bin/env bash
#
# Removes update-lockdown, restoring updates first if the system is locked.
#
set -euo pipefail

BIN=/usr/local/bin/update-lockdown
UNIT=/etc/systemd/system/update-lockdown.service
STATE=/var/lib/update-lockdown/state.tsv

[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo" >&2; exit 3; }

# Never leave a machine frozen with no tool left to unfreeze it.
if [ -f "$STATE" ] && [ -x "$BIN" ]; then
  echo "System is locked - restoring updates before uninstalling."
  "$BIN" unlock
fi

systemctl disable --now update-lockdown.service >/dev/null 2>&1 || true
rm -f "$UNIT" "$BIN"
rmdir /var/lib/update-lockdown 2>/dev/null || true
systemctl daemon-reload

echo "update-lockdown removed. Background updates are running normally."
