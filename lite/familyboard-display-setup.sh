#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — display-setup (kjøres som ExecStartPre)
# =============================================================================
# Kjøres FØR Chromium av chromium-kiosk.service via en systemd drop-in.
# Setter EKSPLISITT DISPLAY/XAUTHORITY (kritisk — i systemd --user-kontekst
# er de ikke satt), venter på X, og speiler alle tilkoblede skjermer til
# primær ved primærens foretrukne modus. Dette gir én framebuffer =
# skjermstørrelsen, slik at --kiosk fyller HELE skjermen.
#
# Bakgrunn: dual-HDMI ga utvidet framebuffer (f.eks. 3840x1080) → --kiosk
# fylte bare halve. Denne kollapser til speiling (samme +0+0) = korrekt fb.
#
# Idempotent og trygg å kjøre gjentatte ganger.
# =============================================================================

set -u

# Finn faktisk X-display dynamisk (GDM kan gi :1, ikke alltid :0).
if [[ -z "${DISPLAY:-}" ]]; then
  for _s in /tmp/.X11-unix/X*; do
    [[ -e "$_s" ]] || continue
    DISPLAY=":${_s##*/X}"
    break
  done
fi
export DISPLAY="${DISPLAY:-:0}"

# Finn en gyldig X-authority (LightDM: ~/.Xauthority; andre varianter dekket)
for xa in "${HOME}/.Xauthority" \
          "/run/user/$(id -u)/gdm/Xauthority" \
          "/var/run/lightdm/${USER}/xauthority" \
          "/run/lightdm/${USER}/xauthority"; do
  if [[ -f "$xa" ]]; then export XAUTHORITY="$xa"; break; fi
done

log() { echo "[display-setup] $*"; }

command -v xrandr >/dev/null 2>&1 || { log "xrandr mangler — hopper over"; exit 0; }

# Vent på at X er klar (opptil 30s)
for _i in $(seq 1 30); do
  xrandr >/dev/null 2>&1 && break
  sleep 1
done
if ! xrandr >/dev/null 2>&1; then
  log "X ikke tilgjengelig (DISPLAY=$DISPLAY XAUTHORITY=${XAUTHORITY:-unset}) — hopper over"
  exit 0
fi

# Primær = 'connected primary', ellers første 'connected'
primary="$(xrandr | awk '/ connected primary/{print $1; exit}')"
[[ -z "$primary" ]] && primary="$(xrandr | awk '/ connected/{print $1; exit}')"
if [[ -z "$primary" ]]; then log "Ingen tilkoblet skjerm"; exit 0; fi

# Primærens foretrukne/aktive modus (linje med * eller +)
mode="$(xrandr | awk -v p="$primary" '
  $0 ~ "^"p" connected"{f=1; next}
  /^[A-Za-z]/{f=0}
  f && /[*+]/{gsub(/[^0-9x]/,"",$1); print $1; exit}')"
[[ -z "$mode" ]] && mode="1920x1080"

# Sett primær @ 0,0 med modus → nullstiller framebuffer-bredde
xrandr --output "$primary" --primary --mode "$mode" --pos 0x0 --rotate normal 2>/dev/null \
  || xrandr --output "$primary" --primary --auto --pos 0x0 2>/dev/null || true

# Speil alle andre tilkoblede skjermer til primær (samme innhold + samme fb)
for o in $(xrandr | awk '/ connected/{print $1}'); do
  [[ "$o" == "$primary" ]] && continue
  xrandr --output "$o" --same-as "$primary" --mode "$mode" 2>/dev/null \
    || xrandr --output "$o" --same-as "$primary" --auto 2>/dev/null \
    || xrandr --output "$o" --off 2>/dev/null || true
done

# Skjermsparer/DPMS av
xset -dpms s off s noblank 2>/dev/null || true

log "OK: primær=$primary modus=$mode (speiler øvrige, framebuffer=$mode)"
exit 0
