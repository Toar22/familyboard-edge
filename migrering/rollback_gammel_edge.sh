#!/bin/bash
# Setter skjermen tilbake til eldre FamilyBoard Edge fra backup_gammel_edge.sh.
# Bruk:  sudo bash migrering/rollback_gammel_edge.sh [backup-mappe]  &&  sudo reboot
set -u
B="${1:-$(cat /root/fb-edge-backup-latest 2>/dev/null)}"
[ -n "$B" ] && [ -f "$B/files.tgz" ] || { echo "Fant ikke backup (${B:-ingen})"; exit 1; }
U=$(cat "$B/user.txt"); H=$(eval echo ~"$U"); UIDN=$(id -u "$U")
uctl(){ sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus systemctl --user "$@"; }
echo "1/4 Stopper Edge Lite"
uctl disable --now chromium-kiosk.service chromium-kiosk-nightly.timer 2>/dev/null
systemctl disable --now wifi-recovery.service familyboard-hotspot.service 2>/dev/null
pkill -f "familyboard-kiosk-profile" 2>/dev/null
echo "2/4 Fjerner Edge Lite-oppsett"
rm -f /etc/lightdm/lightdm.conf.d/60-familyboard-autologin.conf /etc/lightdm/lightdm.conf.d/61-familyboard-session.conf
rm -rf "$H/.config/systemd/user"
echo "3/4 Gjenoppretter eldre Edge"
tar -xzpf "$B/files.tgz" -P
systemctl unmask apt-daily.timer apt-daily-upgrade.timer packagekit.service motd-news.timer \
  update-notifier-download.timer update-notifier-motd.timer 2>/dev/null
[ -s "$B/root-crontab.txt" ] && crontab "$B/root-crontab.txt"
[ -s "$B/user-crontab.txt" ] && sudo -u "$U" crontab "$B/user-crontab.txt"
systemctl daemon-reload; uctl daemon-reload
echo "4/4 Ferdig – start på nytt: sudo reboot"
