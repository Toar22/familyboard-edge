#!/bin/bash
# Sikkerhetskopi før Edge Lite installeres over en eldre FamilyBoard Edge.
# Tar vare på alt installeren endrer, så rollback_gammel_edge.sh kan sette
# skjermen tilbake slik den var.  Bruk:  sudo bash migrering/backup_gammel_edge.sh
set -e
U="${SUDO_USER:?Kjør med sudo}"; H=$(eval echo ~"$U"); UIDN=$(id -u "$U")
B="/root/fb-edge-backup-$(date +%Y%m%d-%H%M)"; mkdir -p "$B"
echo "$U" > "$B/user.txt"
systemctl list-unit-files --state=enabled --no-legend > "$B/system-enabled.txt" || true
sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus \
  systemctl --user list-unit-files --state=enabled --no-legend > "$B/user-enabled.txt" 2>/dev/null || true
crontab -l > "$B/root-crontab.txt" 2>/dev/null || true
sudo -u "$U" crontab -l > "$B/user-crontab.txt" 2>/dev/null || true
tar -czpf "$B/files.tgz" --ignore-failed-read -P \
  /etc/systemd/system /etc/lightdm /etc/gdm3 /var/lib/AccountsService/users /etc/xdg/autostart \
  "$H/.config/systemd" "$H/.config/autostart" "$H/.config/openbox" "$H/.config/lxsession" \
  "$H/.config/labwc" "$H/.config/wayfire.ini" 2>/dev/null
echo "$B" > /root/fb-edge-backup-latest
echo "✅ Backup: $B"; ls -la "$B"
echo "Kontroll – disse skal være med:"
tar -tzf "$B/files.tgz" 2>/dev/null | grep -E "systemd/user/[^/]+\.(service|timer)$" || echo "  (ingen brukertjenester funnet)"
