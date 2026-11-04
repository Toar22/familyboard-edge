#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — Hotspot setup
# =============================================================================
# Forbereder wlan0 for hostapd + dnsmasq.
# Genererer unik SSID basert på MAC: FamilyBoard-Setup-XXXX
# Kjøres som ExecStartPre i familyboard-hotspot.service.
# =============================================================================

set -eu
exec > >(tee -a /var/log/familyboard-hotspot.log) 2>&1
echo "[$(date -Is)] hotspot-start preparing wlan0"

IFACE="wlan0"

# Hent siste 4 tegn av MAC for unik SSID
MAC_FILE="/sys/class/net/${IFACE}/address"
if [[ -f "$MAC_FILE" ]]; then
  MAC=$(cat "$MAC_FILE")
  SUFFIX=$(echo "$MAC" | tr -d ':' | tail -c 5 | tr 'a-z' 'A-Z')
else
  SUFFIX="UNKW"
fi
SSID="FamilyBoard-Setup-${SUFFIX}"
echo "[$(date -Is)] SSID = ${SSID}"

# Skriv hostapd-config (passord 'familyboard', ingen PIN — brukerens valg)
mkdir -p /etc/hostapd
cat > /etc/hostapd/familyboard.conf <<EOF
interface=${IFACE}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=7
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=familyboard
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ignore_broadcast_ssid=0
EOF

# Skriv dnsmasq-config (DHCP-range 192.168.4.10-50, gateway 192.168.4.1)
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/familyboard.conf <<'EOF'
interface=wlan0
bind-interfaces
domain-needed
bogus-priv
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,12h
dhcp-option=3,192.168.4.1
dhcp-option=6,192.168.4.1
# Captive portal: redirect all DNS to 192.168.4.1 så telefonen får setup-skjerm
address=/#/192.168.4.1
EOF

rfkill unblock wifi 2>/dev/null || true

# Skann etter nettverk NÅ, mens wlan0 fortsatt er i klient-modus. I AP-modus
# gir skanning ofte ingenting, og da ville nedtrekkslisten på 192.168.4.1 vært tom.
SSID_LIST="/run/familyboard-ssids.txt"
: > "${SSID_LIST}"
if command -v nmcli >/dev/null 2>&1; then
  nmcli radio wifi on 2>/dev/null || true
  timeout 20 nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null \
    | sed 's/\\:/:/g' | grep -v '^$' >> "${SSID_LIST}" || true
fi
if [[ ! -s "${SSID_LIST}" ]] && command -v iw >/dev/null 2>&1; then
  ip link set "${IFACE}" up 2>/dev/null || true
  timeout 15 iw dev "${IFACE}" scan 2>/dev/null \
    | sed -n 's/^[[:space:]]*SSID: //p' | grep -v '^$' >> "${SSID_LIST}" || true
fi
sort -u -o "${SSID_LIST}" "${SSID_LIST}" 2>/dev/null || true
grep -vx "${SSID}" "${SSID_LIST}" > "${SSID_LIST}.tmp" 2>/dev/null && mv "${SSID_LIST}.tmp" "${SSID_LIST}" || rm -f "${SSID_LIST}.tmp"
echo "[$(date -Is)] Fant $(wc -l < "${SSID_LIST}") nettverk ved skanning"

# Stopp NetworkManager-håndtering av wlan0 mens hotspot kjører
if command -v nmcli >/dev/null 2>&1; then
  nmcli device disconnect "${IFACE}" 2>/dev/null || true
  nmcli device set "${IFACE}" managed no 2>/dev/null || true
  sleep 2
fi

# Bring opp interface med statisk IP
ip link set "${IFACE}" down 2>/dev/null || true
ip addr flush dev "${IFACE}" 2>/dev/null || true
ip addr add 192.168.4.1/24 dev "${IFACE}"
ip link set "${IFACE}" up

echo "[$(date -Is)] wlan0 klar for hostapd+dnsmasq, SSID=${SSID}"
