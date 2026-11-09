#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — koble til WiFi valgt på hotspot-siden
# =============================================================================
# Startes av hotspot-config-server.py via systemd-run (egen enhet), slik at den
# overlever at hotspot- og web-tjenesten stoppes.
#
# Leser SSID (linje 1) og passord (linje 2) fra /run/familyboard-wifi-pending
# (0600, root) og sletter filen med en gang. Passordet logges aldri.
#
# Lykkes ikke tilkoblingen (f.eks. feil passord) startes hotspoten igjen, så
# brukeren kan prøve på nytt fra telefonen.
# =============================================================================

set -u
exec >> /var/log/familyboard-hotspot.log 2>&1
log() { echo "[$(date -Is)] [wifi-connect] $*"; }

IFACE="wlan0"
PENDING="/run/familyboard-wifi-pending"

if [[ ! -f "${PENDING}" ]]; then
  log "Ingen ${PENDING} — avbryter"
  exit 1
fi
{ IFS= read -r SSID; IFS= read -r PSK; } < "${PENDING}"
rm -f "${PENDING}"
log "Kobler til SSID=${SSID}"

check_internet() {
  ping -c1 -W2 -q 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W2 -q 1.1.1.1 >/dev/null 2>&1
}

# La telefonen få svaret før hotspoten forsvinner
sleep 3
systemctl stop familyboard-hotspot.service 2>/dev/null || true
ip addr flush dev "${IFACE}" 2>/dev/null || true

ok=0
existed=0
if command -v nmcli >/dev/null 2>&1 \
   && nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq -- "${SSID}"; then
  existed=1   # profilen fantes fra før — skal ikke slettes om noe feiler
fi
if command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
  nmcli device set "${IFACE}" managed yes 2>/dev/null || true
  nmcli radio wifi on 2>/dev/null || true
  sleep 3
  for attempt in 1 2 3; do
    nmcli device wifi rescan ifname "${IFACE}" 2>/dev/null || true
    sleep 4
    extra=()
    [[ ${attempt} -eq 3 ]] && extra=(hidden yes)   # skjult nettverk?
    if nmcli --wait 30 device wifi connect "${SSID}" password "${PSK}" ifname "${IFACE}" "${extra[@]}" >/dev/null 2>&1; then
      log "nmcli connect OK (forsøk ${attempt})"
      # Aldri gi opp profilen ved et kortvarig WiFi-fall
      nmcli connection modify id "${SSID}" connection.autoconnect-retries 0 >/dev/null 2>&1 || true
      ok=1
      break
    fi
    log "nmcli connect feilet (forsøk ${attempt})"
  done
else
  # Uten NetworkManager (eldre Pi OS): wpa_supplicant
  if [[ -d /etc/wpa_supplicant ]] && command -v wpa_passphrase >/dev/null 2>&1; then
    {
      echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
      echo "update_config=1"
      echo "country=NO"
      wpa_passphrase "${SSID}" "${PSK}" | grep -v '#psk='
    } > /etc/wpa_supplicant/wpa_supplicant.conf
    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
    systemctl restart wpa_supplicant 2>/dev/null || true
    systemctl restart dhcpcd 2>/dev/null || true
    ok=1
  fi
fi
unset PSK

if [[ ${ok} -eq 1 ]]; then
  for _ in $(seq 1 15); do
    if check_internet; then
      log "Internett OK via ${SSID} — ferdig"
      exit 0
    fi
    sleep 2
  done
  log "Koblet til ${SSID}, men ingen internett"
fi

# Feilet: fjern profilen vi nettopp lagde (ikke en som fantes) og start hotspoten igjen
if [[ ${existed} -eq 0 ]] && command -v nmcli >/dev/null 2>&1; then
  nmcli connection delete id "${SSID}" >/dev/null 2>&1 || true
fi
log "Tilkobling feilet — starter hotspot igjen"
systemctl start familyboard-hotspot.service 2>/dev/null || true
exit 1
