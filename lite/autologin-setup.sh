#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — autologin-oppsett (OS-agnostisk)
# =============================================================================
# Sources av install_thin_pi.sh etter detect-env.sh.
# Setter opp autologin til desktop for den bruker + metode som ble detektert.
#
# Krever: PI_USER, og FB_AUTOLOGIN_METHOD + FB_DISPLAY_MANAGER fra detect-env.
# =============================================================================

setup_autologin() {
  local user="$1"
  local method="${FB_AUTOLOGIN_METHOD:-manual}"

  echo "  Autologin-metode: ${method} (DM: ${FB_DISPLAY_MANAGER:-none})"

  case "$method" in
    # -------------------------------------------------------------------------
    raspi-config)
      # Raspberry Pi OS — enkleste og tryggeste vei
      raspi-config nonint do_boot_behaviour B4 || {
        echo "  ⚠ raspi-config B4 feilet — faller tilbake til lightdm-metode"
        _autologin_lightdm "$user"
      }
      ;;

    # -------------------------------------------------------------------------
    lightdm)
      _autologin_lightdm "$user"
      ;;

    # -------------------------------------------------------------------------
    gdm)
      _autologin_gdm "$user"
      ;;

    # -------------------------------------------------------------------------
    sddm)
      _autologin_sddm "$user"
      ;;

    # -------------------------------------------------------------------------
    getty)
      # Server uten display manager — autologin på tty1 + startx
      _autologin_getty "$user"
      ;;

    *)
      echo "  ⚠ Ukjent autologin-metode. Autologin må settes opp manuelt."
      return 1
      ;;
  esac

  # Sikre grafisk boot-target (gjelder alle DM-metoder)
  systemctl set-default graphical.target 2>/dev/null || true
}

# -----------------------------------------------------------------------------
_autologin_lightdm() {
  local user="$1"
  local conf_dir="/etc/lightdm/lightdm.conf.d"
  mkdir -p "$conf_dir"

  # Velg en LETTVEKTS kiosk-sesjon hvis tilgjengelig. GNOME/mutter dekorerer
  # og halv-størrelser --kiosk-vinduet (gir "halv skjerm + 2 headere");
  # openbox/LXDE respekterer --kiosk fullt ut. Prioritet: openbox > LXDE.
  local session=""
  if [[ -f /usr/share/xsessions/openbox.desktop ]]; then
    session="openbox"
  elif [[ -f /usr/share/xsessions/LXDE.desktop ]]; then
    session="LXDE"
  fi

  cat > "${conf_dir}/60-familyboard-autologin.conf" <<EOF
[Seat:*]
autologin-user=${user}
autologin-user-timeout=0
EOF

  if [[ -n "$session" ]]; then
    cat > "${conf_dir}/61-familyboard-session.conf" <<EOF
[Seat:*]
autologin-session=${session}
user-session=${session}
EOF
    echo "  ✅ LightDM autologin satt for ${user} (kiosk-sesjon: ${session})"
  else
    echo "  ✅ LightDM autologin satt for ${user}"
    echo "  ⚠ Fant ikke openbox/LXDE — kiosk kjører under default-sesjon"
    echo "     (installer med: sudo apt-get install -y openbox for ekte fullskjerm)"
  fi
}

# -----------------------------------------------------------------------------
_autologin_gdm() {
  local user="$1"
  local conf="/etc/gdm3/custom.conf"
  [[ -f "$conf" ]] || conf="/etc/gdm/custom.conf"
  if [[ -f "$conf" ]]; then
    cp -a "$conf" "${conf}.bak_$(date +%Y%m%d_%H%M%S)"
  else
    mkdir -p "$(dirname "$conf")"
    printf '[daemon]\n' > "$conf"
  fi
  # Fjern eksisterende autologin-linjer, legg til nye under [daemon]
  sed -i '/^AutomaticLoginEnable/d; /^AutomaticLogin=/d' "$conf"
  if grep -q '^\[daemon\]' "$conf"; then
    sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=${user}" "$conf"
  else
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$user" >> "$conf"
  fi

  # GDM velger sesjon via AccountsService — sett openbox/LXDE der (så vi ikke
  # havner i GNOME/mutter, som dekorerer og halv-størrelser --kiosk-vinduet).
  local session=""
  if [[ -f /usr/share/xsessions/openbox.desktop ]]; then
    session="openbox"
  elif [[ -f /usr/share/xsessions/LXDE.desktop ]]; then
    session="LXDE"
  fi
  if [[ -n "$session" ]]; then
    local as="/var/lib/AccountsService/users/${user}"
    mkdir -p /var/lib/AccountsService/users
    if [[ -f "$as" ]]; then
      cp -a "$as" "${as}.bak_$(date +%Y%m%d_%H%M%S)"
      sed -i '/^Session=/d; /^XSession=/d' "$as"
      # legg til under [User], ellers opprett seksjonen
      if grep -q '^\[User\]' "$as"; then
        sed -i "/^\[User\]/a Session=${session}\nXSession=${session}" "$as"
      else
        printf '[User]\nSession=%s\nXSession=%s\n' "$session" "$session" >> "$as"
      fi
    else
      printf '[User]\nSession=%s\nXSession=%s\nSystemAccount=false\n' \
        "$session" "$session" > "$as"
    fi
    echo "  ✅ GDM autologin satt for ${user} (kiosk-sesjon: ${session})"
  else
    echo "  ✅ GDM autologin satt for ${user}"
    echo "  ⚠ Fant ikke openbox/LXDE — kiosk kjører under GNOME (kan gi halv skjerm)"
  fi
}

# -----------------------------------------------------------------------------
_autologin_sddm() {
  local user="$1"
  local conf_dir="/etc/sddm.conf.d"
  mkdir -p "$conf_dir"
  cat > "${conf_dir}/60-familyboard-autologin.conf" <<EOF
[Autologin]
User=${user}
Session=default
EOF
  echo "  ✅ SDDM autologin satt for ${user}"
}

# -----------------------------------------------------------------------------
_autologin_getty() {
  local user="$1"
  # Autologin på tty1
  local dropin="/etc/systemd/system/getty@tty1.service.d"
  mkdir -p "$dropin"
  cat > "${dropin}/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${user} --noclear %I \$TERM
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  ✅ getty autologin satt for ${user} på tty1"
  echo "  ⚠ NB: server uten display manager — kiosk-launcher må starte X/Wayland selv."
  echo "     (Se README_EDGE_LITE.md — server-modus krever xinit eller cage.)"
}

# -----------------------------------------------------------------------------
# Skjermsparer av — metode avhenger av session-type
disable_screensaver() {
  case "${FB_DISPLAY_MANAGER:-none}" in
    lightdm)
      local conf_dir="/etc/lightdm/lightdm.conf.d"
      mkdir -p "$conf_dir"
      cat > "${conf_dir}/50-no-blank.conf" <<'EOF'
[Seat:*]
xserver-command=X -s 0 -dpms
EOF
      echo "  ✅ LightDM skjermsparer av"
      ;;
    *)
      # For Wayland/GNOME/andre: skjermsparer-av skjer i kiosk-launcher
      # (wlr-randr / gsettings / xset) — se familyboard-kiosk.sh
      echo "  ℹ Skjermsparer-av håndteres i kiosk-launcher (session=${FB_SESSION_TYPE:-?})"
      ;;
  esac
}
