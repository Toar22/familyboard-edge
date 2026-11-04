#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — miljø-deteksjon
# =============================================================================
# Sources av install_thin_pi.sh. Setter capability-variabler slik at resten
# av installeren tilpasser seg OS-et automatisk. Vi detekterer KOMPONENTER
# (display manager, autologin-metode, nettverksstakk) — ikke distro-navn —
# fordi det er mer robust på tvers av Raspberry Pi OS, Ubuntu og Debian.
#
# Setter (echo-bar via detect_env_print):
#   FB_OS_ID            raspbian|debian|ubuntu|unknown
#   FB_OS_PRETTY        "Ubuntu 24.04.3 LTS"
#   FB_DISPLAY_MANAGER  lightdm|gdm3|sddm|none
#   FB_AUTOLOGIN_METHOD raspi-config|lightdm|gdm|sddm|getty|manual
#   FB_AUTOSTART_KIND    lxde|wayfire|labwc|gnome|xdg
#   FB_SESSION_TYPE      x11|wayland|unknown
#   FB_NET_STACK         networkmanager|netplan|wpa-direct
#   FB_HAS_RASPI_CONFIG  yes|no
#   FB_HAS_NMCLI         yes|no
#   FB_IS_PI_HARDWARE    yes|no
# =============================================================================

detect_env() {
  # ---- OS ID ----
  FB_OS_ID="unknown"
  FB_OS_PRETTY="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    FB_OS_ID="${ID:-unknown}"
    FB_OS_PRETTY="${PRETTY_NAME:-unknown}"
  fi

  # ---- Pi-hardware? ----
  FB_IS_PI_HARDWARE="no"
  if [[ -f /sys/firmware/devicetree/base/model ]] \
     && tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null | grep -qi "raspberry"; then
    FB_IS_PI_HARDWARE="yes"
  fi

  # ---- raspi-config finnes? ----
  if command -v raspi-config >/dev/null 2>&1; then
    FB_HAS_RASPI_CONFIG="yes"
  else
    FB_HAS_RASPI_CONFIG="no"
  fi

  # ---- nmcli finnes? ----
  if command -v nmcli >/dev/null 2>&1; then
    FB_HAS_NMCLI="yes"
  else
    FB_HAS_NMCLI="no"
  fi

  # ---- Display manager ----
  FB_DISPLAY_MANAGER="none"
  if [[ -f /etc/X11/default-display-manager ]]; then
    local dm
    dm="$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null)")"
    case "$dm" in
      lightdm) FB_DISPLAY_MANAGER="lightdm" ;;
      gdm3|gdm) FB_DISPLAY_MANAGER="gdm3" ;;
      sddm) FB_DISPLAY_MANAGER="sddm" ;;
      *) FB_DISPLAY_MANAGER="$dm" ;;
    esac
  else
    # Fallback: sjekk hvilke som er installert
    if command -v lightdm >/dev/null 2>&1; then FB_DISPLAY_MANAGER="lightdm"
    elif command -v gdm3 >/dev/null 2>&1; then FB_DISPLAY_MANAGER="gdm3"
    elif command -v sddm >/dev/null 2>&1; then FB_DISPLAY_MANAGER="sddm"
    fi
  fi

  # ---- Autologin-metode (prioritert) ----
  # raspi-config er enklest og tryggest der den finnes (Pi OS).
  # Ellers direkte config i display manager. Ellers getty (server uten DM).
  if [[ "$FB_HAS_RASPI_CONFIG" == "yes" ]]; then
    FB_AUTOLOGIN_METHOD="raspi-config"
  else
    case "$FB_DISPLAY_MANAGER" in
      lightdm) FB_AUTOLOGIN_METHOD="lightdm" ;;
      gdm3)    FB_AUTOLOGIN_METHOD="gdm" ;;
      sddm)    FB_AUTOLOGIN_METHOD="sddm" ;;
      none)    FB_AUTOLOGIN_METHOD="getty" ;;
      *)       FB_AUTOLOGIN_METHOD="manual" ;;
    esac
  fi

  # ---- Autostart-type (for cleanup av gammel kiosk-autostart) ----
  FB_AUTOSTART_KIND="xdg"
  if [[ -f "${PI_HOME:-$HOME}/.config/wayfire.ini" ]]; then
    FB_AUTOSTART_KIND="wayfire"
  elif [[ -f "${PI_HOME:-$HOME}/.config/labwc/autostart" ]]; then
    FB_AUTOSTART_KIND="labwc"
  elif [[ -d "${PI_HOME:-$HOME}/.config/lxsession" ]]; then
    FB_AUTOSTART_KIND="lxde"
  elif command -v gnome-session >/dev/null 2>&1; then
    FB_AUTOSTART_KIND="gnome"
  fi

  # ---- Session-type (X11/Wayland) ----
  FB_SESSION_TYPE="unknown"
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    FB_SESSION_TYPE="wayland"
  elif [[ -n "${DISPLAY:-}" ]]; then
    FB_SESSION_TYPE="x11"
  elif [[ -f "${PI_HOME:-$HOME}/.config/wayfire.ini" ]] \
       || [[ -f "${PI_HOME:-$HOME}/.config/labwc/autostart" ]]; then
    FB_SESSION_TYPE="wayland"
  else
    # Pi OS Bookworm default = wayland på Pi 4/5, X11 ellers
    FB_SESSION_TYPE="x11"
  fi

  # ---- Nettverksstakk ----
  # NetworkManager foretrekkes (Bookworm + Ubuntu 24.04 default).
  # netplan på Ubuntu Server uten NM. wpa-direct som siste fallback.
  FB_NET_STACK="wpa-direct"
  if systemctl is-enabled NetworkManager >/dev/null 2>&1 \
     || systemctl is-active NetworkManager >/dev/null 2>&1; then
    FB_NET_STACK="networkmanager"
  elif command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
    FB_NET_STACK="netplan"
  elif [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
    FB_NET_STACK="wpa-direct"
  fi
}

detect_env_print() {
  cat <<EOF
FB_OS_ID=${FB_OS_ID}
FB_OS_PRETTY=${FB_OS_PRETTY}
FB_IS_PI_HARDWARE=${FB_IS_PI_HARDWARE}
FB_DISPLAY_MANAGER=${FB_DISPLAY_MANAGER}
FB_AUTOLOGIN_METHOD=${FB_AUTOLOGIN_METHOD}
FB_AUTOSTART_KIND=${FB_AUTOSTART_KIND}
FB_SESSION_TYPE=${FB_SESSION_TYPE}
FB_NET_STACK=${FB_NET_STACK}
FB_HAS_RASPI_CONFIG=${FB_HAS_RASPI_CONFIG}
FB_HAS_NMCLI=${FB_HAS_NMCLI}
EOF
}

# Hvis kjørt direkte (ikke sourced): detektér og skriv ut
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  detect_env
  detect_env_print
fi
