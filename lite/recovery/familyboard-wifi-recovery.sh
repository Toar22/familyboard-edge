#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — WiFi recovery
# =============================================================================
# Kjøres ved boot av wifi-recovery.service.
# Logikk (godkjent av bruker 2026-05-10):
#   - Vent 60s totalt for internett-tilkobling
#   - Hver 5s: sjekk om USB-stick har familyboard-wifi.conf (Lag 1)
#   - Hver 5s: ping 8.8.8.8 — hvis OK, exit
#   - Etter 60s uten tilkobling: start hotspot (Lag 2)
# =============================================================================

set -u
exec > >(tee -a /var/log/familyboard-wifi-recovery.log) 2>&1
echo "[$(date -Is)] wifi-recovery startet"

CHECK_INTERVAL=5
TOTAL_TIMEOUT=60
elapsed=0

check_internet() {
  ping -c1 -W2 -q 8.8.8.8 >/dev/null 2>&1
}

apply_usb_config() {
  # Lag 1: Lett etter familyboard-wifi.conf på USB-stick
  # Format på USB-stick:
  #   SSID=NyttNett
  #   PSK=NyttPassord
  local found=0
  for dev in /dev/sd?1 /dev/mmcblk[1-9]p1; do
    [[ -b "$dev" ]] || continue
    local mnt
    mnt=$(mktemp -d /tmp/recovery-usb-XXXXXX)
    if mount -o ro "$dev" "$mnt" 2>/dev/null; then
      if [[ -f "$mnt/familyboard-wifi.conf" ]]; then
        echo "[$(date -Is)] Fant WiFi-config på $dev"
        # shellcheck disable=SC1091
        source "$mnt/familyboard-wifi.conf"
        if [[ -n "${SSID:-}" && -n "${PSK:-}" ]]; then
          # Prefer NetworkManager (Ubuntu 24.04 + Pi OS Bookworm default) — den
          # lager et persistent connection-profil som overlever reboot.
          if command -v nmcli >/dev/null 2>&1 \
             && systemctl is-active NetworkManager >/dev/null 2>&1; then
            echo "[$(date -Is)] nmcli connect (SSID=$SSID)"
            nmcli device wifi connect "$SSID" password "$PSK" 2>/dev/null \
              && found=1
          fi
          # Fallback: wpa_supplicant.conf (Pi OS uten NM / server)
          if [[ $found -eq 0 && -d /etc/wpa_supplicant ]]; then
            echo "[$(date -Is)] Skriver wpa_supplicant.conf (SSID=$SSID)"
            {
              echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
              echo "update_config=1"
              echo "country=NO"
              wpa_passphrase "$SSID" "$PSK"
            } > /etc/wpa_supplicant/wpa_supplicant.conf
            systemctl restart wpa_supplicant 2>/dev/null || true
            found=1
          fi
        fi
      fi
      umount "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
    [[ $found -eq 1 ]] && return 0
  done
  return 1
}

# Hovedloop
while [[ $elapsed -lt $TOTAL_TIMEOUT ]]; do
  if check_internet; then
    echo "[$(date -Is)] Internett OK etter ${elapsed}s — exit"
    exit 0
  fi

  if apply_usb_config; then
    echo "[$(date -Is)] USB-config anvendt — venter 10s på tilkobling"
    sleep 10
    if check_internet; then
      echo "[$(date -Is)] USB-config fungerte — exit"
      exit 0
    fi
  fi

  sleep "$CHECK_INTERVAL"
  elapsed=$((elapsed + CHECK_INTERVAL))
done

# Ingen tilkobling etter 60s → start hotspot (Lag 2)
echo "[$(date -Is)] Ingen WiFi etter ${TOTAL_TIMEOUT}s — starter hotspot"
systemctl start familyboard-hotspot.service || true
