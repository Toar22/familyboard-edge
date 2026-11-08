#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — nettvakt (kjøres hvert minutt av en systemd-timer)
# =============================================================================
# Har Pi-en mistet nettet i minst 3 minutter (og hotspoten ikke er i bruk),
# slås WiFi av og på og kobles til igjen – høyst hvert 5. minutt. Ellers kunne
# skjermen bli stående med samme bilde i timevis til noen dro ut strømmen.
# Alt logges til journalen (journalctl -t fb-net-watchdog).
# =============================================================================
set -u
IFACE="wlan0"
STATE_DIR="/run/familyboard"
DOWN_FILE="${STATE_DIR}/net-down-since"
RESET_FILE="${STATE_DIR}/net-last-reset"
mkdir -p "$STATE_DIR"
log() { logger -t fb-net-watchdog "$*"; }

online() {
  local gw
  ping -c1 -W3 -q 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W3 -q 8.8.8.8 >/dev/null 2>&1 && return 0
  gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
  [[ -n "$gw" ]] && curl -fsS -m 5 -o /dev/null https://familyboard.cloud/healthz 2>/dev/null && return 0
  return 1
}

# Hotspot (WiFi-oppsett) i bruk → ikke rør wlan0
systemctl is-active --quiet familyboard-hotspot.service && exit 0

now=$(date +%s)
if online; then
  if [[ -f "$DOWN_FILE" ]]; then
    log "Nett tilbake etter $(( now - $(cat "$DOWN_FILE") )) s"
    rm -f "$DOWN_FILE"
  fi
  exit 0
fi

[[ -f "$DOWN_FILE" ]] || { echo "$now" > "$DOWN_FILE"; log "Nett borte – følger med"; \
  log "Status: $(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | tr '\n' ' ') IP: $(ip -4 -br addr show "$IFACE" 2>/dev/null)"; exit 0; }
down=$(( now - $(cat "$DOWN_FILE") ))
last=$(cat "$RESET_FILE" 2>/dev/null || echo 0)
if (( down >= 180 && now - last >= 300 )); then
  echo "$now" > "$RESET_FILE"
  log "Nett borte i ${down} s – kobler WiFi til på nytt"
  log "Før: $(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null | tr '\n' ' ') IP: $(ip -4 -br addr show "$IFACE" 2>/dev/null)"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi off 2>/dev/null; sleep 3; nmcli radio wifi on 2>/dev/null; sleep 8
    nmcli device connect "$IFACE" >/dev/null 2>&1 || true
  else
    ip link set "$IFACE" down; sleep 3; ip link set "$IFACE" up
  fi
fi
exit 0
