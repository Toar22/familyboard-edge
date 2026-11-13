#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — cleanup
# =============================================================================
# Stopper og fjerner alle Edge Lite-spor. Kan kjøres før re-installasjon,
# eller for å rense en Pi som var Edge (full) før Edge Lite-pilot.
#
# Beholder IKKE backup. Kjør kun hvis du vil starte helt på nytt.
# =============================================================================

set -u

PI_USER="${SUDO_USER:-pi}"
PI_HOME="$(eval echo ~"${PI_USER}")"

say()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }

if [[ $EUID -ne 0 ]]; then
  echo "Kjør med sudo." >&2
  exit 1
fi

cat <<EOF
🧹 FamilyBoard Edge Lite — Cleanup
====================================

Dette vil:
  • Stoppe og slette alle FamilyBoard-services (Lite + Full)
  • Fjerne /usr/local/bin/familyboard-*-skripter
  • Fjerne ~/familyboard-lite og ~/familyboard
  • Fjerne ~/.config/familyboard
  • Slette hotspot-konfig (/etc/hostapd, /etc/dnsmasq.d/familyboard.conf)
  • IKKE røre wpa_supplicant.conf, fstab, eller annet system-config

Pi-en blir IKKE re-flashed.
EOF

read -rp "Fortsette? [y/N]: " ans
[[ "${ans^^}" =~ ^[Yy]$ ]] || { echo "Avbrutt."; exit 0; }

# =============================================================================
# Stopp services
# =============================================================================
say "Stopper services..."

for s in chromium-kiosk chromium-kiosk-restart \
         familyboard familyboard-kiosk familyboard-kiosk-restart \
         familyboard-backend \
         familyboard-hotspot familyboard-hotspot-dnsmasq familyboard-hotspot-web \
         familyboard-recovery wifi-recovery wifi-no-powersave familyboard-net-watchdog; do
  systemctl stop "${s}.service" 2>/dev/null || true
  systemctl stop "${s}.timer" 2>/dev/null || true
  systemctl disable "${s}.service" 2>/dev/null || true
  systemctl disable "${s}.timer" 2>/dev/null || true
done

# User-services
sudo -u "${PI_USER}" bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
  for s in chromium-kiosk chromium-kiosk-restart chromium-kiosk-nightly \
           familyboard familyboard-kiosk familyboard-kiosk-restart \
           familyboard-backend; do
    systemctl --user stop \${s}.service 2>/dev/null || true
    systemctl --user stop \${s}.timer 2>/dev/null || true
    systemctl --user disable \${s}.service 2>/dev/null || true
    systemctl --user disable \${s}.timer 2>/dev/null || true
  done
" 2>/dev/null || true

# Kill prosesser
pkill -f "chromium.*familyboard" 2>/dev/null || true
pkill -f "chromium.*kiosk" 2>/dev/null || true
pkill -f "gunicorn.*familyboard" 2>/dev/null || true
pkill -f "familyboard-recovery-server" 2>/dev/null || true
pkill -f "familyboard-hotspot-config" 2>/dev/null || true

# =============================================================================
# Fjern service-filer
# =============================================================================
say "Fjerner service-filer..."

rm -f /etc/systemd/system/familyboard-hotspot.service
rm -f /etc/systemd/system/familyboard-hotspot-dnsmasq.service
rm -f /etc/systemd/system/familyboard-hotspot-web.service
rm -f /etc/systemd/system/familyboard-recovery.service
rm -f /etc/systemd/system/wifi-recovery.service
rm -f /etc/systemd/system/familyboard-net-watchdog.service /etc/systemd/system/familyboard-net-watchdog.timer
rm -f /etc/systemd/system/wifi-no-powersave.service
rm -f /etc/systemd/system/familyboard*.service
rm -f /etc/systemd/system/familyboard*.timer
rm -f /etc/systemd/system/chromium-kiosk*.service
rm -f /etc/systemd/system/chromium-kiosk*.timer
rm -rf /etc/systemd/system/systemd-networkd-wait-online.service.d
rm -rf /etc/systemd/system/NetworkManager-wait-online.service.d

# User-services
rm -f "${PI_HOME}/.config/systemd/user/chromium-kiosk"*.service
rm -f "${PI_HOME}/.config/systemd/user/chromium-kiosk"*.timer
rm -f "${PI_HOME}/.config/systemd/user/familyboard"*.service
rm -f "${PI_HOME}/.config/systemd/user/familyboard"*.timer

systemctl daemon-reload || true
sudo -u "${PI_USER}" bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
  systemctl --user daemon-reload || true
" 2>/dev/null || true

# =============================================================================
# Fjern installerte skripter og data
# =============================================================================
say "Fjerner skripter og data..."

rm -f /usr/local/bin/familyboard-wifi-recovery.sh
rm -f /usr/local/bin/familyboard-net-watchdog.sh
# Skrivebordet tilbake på Raspberry Pi OS (installeren kommenterte ut panel m.m.)
if [[ -f /etc/xdg/labwc/autostart.familyboard-orig ]]; then
  mv -f /etc/xdg/labwc/autostart.familyboard-orig /etc/xdg/labwc/autostart
fi
rm -f /usr/local/bin/familyboard-hotspot-start.sh
rm -f /usr/local/bin/familyboard-hotspot-config-server.py
rm -f /usr/local/bin/familyboard-wifi-connect.sh
rm -f /usr/local/bin/familyboard-recovery-server.py
rm -f /usr/local/bin/familyboard-display-setup.sh
rm -rf /usr/local/share/familyboard

# App-mapper (både Lite og Full)
rm -rf "${PI_HOME}/familyboard-lite"
rm -rf "${PI_HOME}/familyboard"
rm -rf "${PI_HOME}/.config/familyboard"
rm -f  "${PI_HOME}/.familyboard_edge.json"
rm -rf "${PI_HOME}/.config/familyboard-kiosk-profile"
rm -rf "${PI_HOME}/snap/chromium/common/familyboard-kiosk-profile"
# Drop-in-mapper fra tidligere Edge (HDMI-clone m.m.)
rm -rf "${PI_HOME}/.config/systemd/user/chromium-kiosk.service.d"
rm -rf "${PI_HOME}/.config/systemd/user/familyboard-kiosk.service.d"
# openbox autostart (gammel Edge la konkurrerende kiosk her)
rm -f "${PI_HOME}/.config/openbox/autostart"

# Hotspot-konfig
rm -f /etc/hostapd/familyboard.conf
rm -f /etc/dnsmasq.d/familyboard.conf
rm -f /etc/udev/rules.d/85-familyboard-no-automount.rules
rm -f /etc/systemd/journald.conf.d/familyboard.conf
rm -f /etc/logrotate.d/familyboard-kiosk
rm -f /etc/lightdm/lightdm.conf.d/50-no-blank.conf
rm -f /etc/lightdm/lightdm.conf.d/60-familyboard-autologin.conf
rm -f /etc/lightdm/lightdm.conf.d/61-familyboard-session.conf

# Logger
rm -f /tmp/familyboard-kiosk.log
rm -f /var/log/familyboard-wifi-recovery.log
rm -f /var/log/familyboard-hotspot.log

# Hidden autostart-stubber fra Blokk H
rm -f "${PI_HOME}/.config/autostart/nm-applet.desktop"
rm -f "${PI_HOME}/.config/autostart/print-applet.desktop"
rm -f "${PI_HOME}/.config/autostart/pulseaudio.desktop.desktop"
rm -f "${PI_HOME}/.config/autostart/blueman-applet.desktop"
rm -f "${PI_HOME}/.config/autostart/xscreensaver.desktop"

# =============================================================================
# Unmask services vi maskerte
# =============================================================================
say "Unmasker services..."

systemctl unmask packagekit.service 2>/dev/null || true
systemctl unmask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl unmask motd-news.timer 2>/dev/null || true
systemctl unmask dnsmasq.service 2>/dev/null || true
systemctl unmask hostapd.service 2>/dev/null || true

systemctl daemon-reload || true

# =============================================================================
# Status
# =============================================================================
say "✅ Cleanup fullført"
echo
echo "WiFi-config (wpa_supplicant.conf) er IKKE rørt — Pi-en holder seg på nett."
echo
echo "Neste steg:"
echo "  • Re-installer med: sudo bash install_thin_pi.sh"
echo "  • Eller reboot: sudo reboot"
