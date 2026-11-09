#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — Pi-installer (thin client)
# =============================================================================
# Versjon: 1.1 (OS-agnostisk via komponent-deteksjon)
# Kilde: https://github.com/Toar22/familyboard-edge (offentlig)
#
# Filosofi:
#   - Pi er en TYNN KLIENT — Chromium i kiosk-modus mot Cloud-URL
#   - Ingen Python/Flask/SQLite på Pi (kun for hotspot-config-UI)
#   - Bygger på den tidligere FamilyBoard Edge-installeren
#     (henvisninger som "[ORIGINAL L<linje>]" peker til den)
#   - OS-agnostisk: detekterer KOMPONENTER (display manager, autologin-metode,
#     nettverksstakk) via lite/detect-env.sh og tilpasser seg selv
#
# Støttede OS:
#   - Raspberry Pi OS (Bookworm/Bullseye) — LightDM/labwc/Wayfire, raspi-config
#   - Ubuntu 24.04 Desktop (GDM3 eller LightDM)
#   - Ubuntu med LightDM + lettvekts-skrivebord
#   - Ubuntu Server (getty-autologin — krever cage/xinit, se README)
#   - Debian (LightDM/GDM)
# =============================================================================

set -euo pipefail

# =============================================================================
# Header og metadata
# =============================================================================
EDGE_LITE_VERSION="1.1.0"
INSTALLER_NAME="install_thin_pi.sh"

echo "🚀 FamilyBoard Edge Lite Installer v${EDGE_LITE_VERSION}"
echo "📅 $(date)"
echo "================================================"

# =============================================================================
# Hjelpefunksjoner
# =============================================================================
say()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m" >&2; }
progress() { echo -e "\n\033[1;36m▶ $*\033[0m"; }

retry_apt() {
  # Robust apt-install med 3 forsøk og DEBIAN_FRONTEND=noninteractive
  # [ORIGINAL L202-224 — safe_install()]
  local package="$1"
  local attempt=1
  while [[ $attempt -le 3 ]]; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$package" 2>/dev/null; then
      return 0
    fi
    warn "apt install $package failed (attempt $attempt/3) — retrying"
    sleep 3
    attempt=$((attempt+1))
  done
  warn "apt install $package gave opp etter 3 forsøk — fortsetter"
  return 1
}

# =============================================================================
# Krav-sjekk
# =============================================================================
progress "Sjekker krav"

if [[ $EUID -ne 0 ]]; then
  err "Kjør meg med sudo: sudo bash $0"
  exit 1
fi

# =============================================================================
# Auto-detect bruker (PI_USER) — [ORIGINAL L99-107]
# (må skje FØR detect-env, som bruker PI_HOME for autostart-deteksjon)
# =============================================================================
if [[ -n "${SUDO_USER:-}" ]]; then
  PI_USER="$SUDO_USER"
elif [[ -n "${USER:-}" && "$USER" != "root" ]]; then
  PI_USER="$USER"
else
  PI_USER=$(logname 2>/dev/null || echo "pi")
fi
PI_HOME="$(eval echo ~"${PI_USER}")"
APP_DIR="${PI_HOME}/familyboard-lite"

# =============================================================================
# Miljø-deteksjon (OS-agnostisk) — laster capability-variabler
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LITE_SRC="${SCRIPT_DIR}/lite"

if [[ -f "${LITE_SRC}/detect-env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${LITE_SRC}/detect-env.sh"
  detect_env
else
  err "Fant ikke ${LITE_SRC}/detect-env.sh — kjør fra git-klonet repo."
  exit 1
fi

progress "Miljø-deteksjon"
say "OS:              ${FB_OS_PRETTY}"
say "Pi-hardware:     ${FB_IS_PI_HARDWARE}"
say "Display manager: ${FB_DISPLAY_MANAGER}"
say "Autologin:       ${FB_AUTOLOGIN_METHOD}"
say "Autostart:       ${FB_AUTOSTART_KIND}"
say "Session:         ${FB_SESSION_TYPE}"
say "Nettverk:        ${FB_NET_STACK}"

# Sikkerhetssjekk: må ha en autologin-vei og et display manager (eller getty)
if [[ "$FB_AUTOLOGIN_METHOD" == "manual" ]]; then
  warn "Klarte ikke finne en autologin-metode for dette OS-et."
  warn "Installasjonen fortsetter, men du må sette opp autologin manuelt."
fi

if [[ ! -d "$PI_HOME" ]]; then
  err "Hjemmekatalog ${PI_HOME} finnes ikke. PI_USER=${PI_USER}"
  exit 1
fi
say "PI_USER=${PI_USER}, PI_HOME=${PI_HOME}, APP_DIR=${APP_DIR}"

# =============================================================================
# Interaktiv input — kun kiosk-URL (forenklet vs original)
# =============================================================================
progress "Konfigurasjon"

# Default: peker mot prod-Cloud. Bruker limer inn /d/<token> eller scan av QR.
KIOSK_URL_DEFAULT="https://familyboard.cloud"

# Gjenbruk eksisterende URL ved re-install (idempotent). Rekkefølge:
#   1. KIOSK_URL fra miljø (non-interaktiv: KIOSK_URL=... sudo -E bash ...)
#   2. Eksisterende ~/.config/familyboard/kiosk.env
#   3. Interaktiv prompt
EXISTING_URL=""
if [[ -f "${PI_HOME}/.config/familyboard/kiosk.env" ]]; then
  # NB: || true — grep exit 1 (ingen match) ville ellers abortet under set -e/pipefail
  EXISTING_URL="$(grep -E '^KIOSK_URL=' "${PI_HOME}/.config/familyboard/kiosk.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi

# Terminal for spørsmål: fungerer også med «curl … | sudo bash» (stdin er da skriptet)
TTY_IN=""
if [[ -n "${FB_NONINTERACTIVE:-}" ]]; then :; elif [[ -t 0 ]]; then TTY_IN="/dev/stdin"; elif [[ -r /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then TTY_IN="/dev/tty"; fi
[[ -n "$TTY_IN" ]] && exec 3<"$TTY_IN"   # åpnes én gang, så svarene leses i rekkefølge
ask() {  # ask "Spørsmål" → svar i $REPLY ("" hvis ikke interaktiv)
  REPLY=""
  [[ -n "$TTY_IN" ]] || return 0
  printf '%s' "$1" >&2
  read -r REPLY <&3 || REPLY=""
}

# Godta hel lenke, lenke uten https://, eller bare koden fra «Min konto → URLer»
normalize_kiosk_url() {
  local v="${1//[[:space:]]/}"
  v="${v%/}"
  if [[ "$v" =~ ^https?:// ]]; then echo "$v"; return; fi
  if [[ "$v" == */d/* || "$v" == *.* ]]; then echo "https://${v}"; return; fi
  if [[ -n "$v" ]]; then echo "${KIOSK_URL_DEFAULT}/d/${v}"; fi
  return 0
}

# 0 = gyldig visnings-URL, 1 = ugyldig (404), 2 = kunne ikke sjekke (nett nede o.l.)
check_kiosk_url() {
  command -v curl >/dev/null 2>&1 || return 2
  local code loc
  read -r code loc < <(curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' "$1" 2>/dev/null || echo "000 -")
  case "$code" in
    200|301|302|303|307|308) return 0 ;;   # /d/<kode> sender videre til /dashboard
    404|410) return 1 ;;                    # «Ugyldig lenke»
    *) return 2 ;;
  esac
}

if [[ -n "${KIOSK_URL:-}" ]]; then
  KIOSK_URL="$(normalize_kiosk_url "$KIOSK_URL")"
  say "Kiosk-URL fra miljøvariabel: ${KIOSK_URL}"
elif [[ -n "$EXISTING_URL" ]]; then
  KIOSK_URL="$EXISTING_URL"
  ask "Bruke samme skjerm-lenke som før (${EXISTING_URL})? [J/n] "
  if [[ "${REPLY,,}" == n* ]]; then KIOSK_URL=""; fi
  [[ -n "$KIOSK_URL" ]] && say "Gjenbruker kiosk-URL: ${KIOSK_URL}"
fi

if [[ -z "${KIOSK_URL:-}" ]]; then
  if [[ -z "$TTY_IN" ]]; then
    err "Ingen skjerm-lenke. Kjør på nytt med: sudo KIOSK_URL=\"https://familyboard.cloud/d/DIN-KODE\" bash install_thin_pi.sh"
    exit 1
  fi
  echo
  echo "📺 Hvilken FamilyBoard-skjerm skal denne Pi-en vise?"
  echo "   Finn lenken på familyboard.cloud → «👤 Min konto» → URLer"
  echo "   (lag en med «Opprett» hvis du ikke har noen)."
  echo "   Lim inn hele lenken, f.eks. https://familyboard.cloud/d/abc123 – eller bare koden."
  echo
  for attempt in 1 2 3 4 5; do
    ask "Skjerm-lenke: "
    KIOSK_URL="$(normalize_kiosk_url "$REPLY")"
    if [[ -z "$KIOSK_URL" ]]; then warn "Tomt svar – prøv igjen."; continue; fi
    rc=0; check_kiosk_url "$KIOSK_URL" || rc=$?
    if [[ $rc -eq 0 ]]; then say "✔ Lenken virker: $KIOSK_URL"; break; fi
    if [[ $rc -eq 1 ]]; then
      warn "Fant ingen skjerm med den lenken (ugyldig eller slettet). Sjekk under «Min konto» → URLer."
      KIOSK_URL=""; continue
    fi
    warn "Fikk ikke sjekket lenken nå (ingen nettforbindelse?)."
    ask "Bruke den likevel? [j/N] "
    if [[ "${REPLY,,}" == j* ]]; then break; fi
    KIOSK_URL=""
  done
  if [[ -z "${KIOSK_URL:-}" ]]; then err "Ingen gyldig skjerm-lenke – avbryter uten endringer."; exit 1; fi
fi

if [[ ! "$KIOSK_URL" =~ ^https?:// ]]; then
  err "URL må starte med http:// eller https://. Fikk: $KIOSK_URL"
  exit 1
fi
say "Kiosk-URL satt: $KIOSK_URL"

# =============================================================================
# BLOKK E — Cleanup av tidligere installasjoner
# [ORIGINAL: cleanup_edge_install.sh L49-103, install L270-318]
# =============================================================================
progress "BLOKK E — Cleanup av forrige installasjon"

# Stopp services
for s in familyboard familyboard-kiosk familyboard-kiosk-restart.timer \
         chromium-kiosk chromium-kiosk-restart.timer \
         familyboard-hotspot wifi-recovery; do
  systemctl stop "${s}.service" 2>/dev/null || true
  systemctl stop "${s}.timer" 2>/dev/null || true
done

# User-services (krever DBUS-eksport — se BLOKK D senere)
for s in familyboard-backend chromium-kiosk chromium-kiosk-restart.timer chromium-kiosk-nightly \
         familyboard-kiosk familyboard-kiosk-restart.timer; do
  sudo -u "${PI_USER}" bash -lc "
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
    systemctl --user stop ${s}.service 2>/dev/null || true
    systemctl --user stop ${s}.timer 2>/dev/null || true
  " 2>/dev/null || true
done

# Kill prosesser
pkill -f "chromium.*familyboard" 2>/dev/null || true
pkill -f "chromium.*kiosk"       2>/dev/null || true
pkill -f "gunicorn.*familyboard" 2>/dev/null || true

# Fjern service-filer (både system og user)
rm -f /etc/systemd/system/familyboard*.service
rm -f /etc/systemd/system/familyboard*.timer
rm -f /etc/systemd/system/chromium-kiosk*.service
rm -f /etc/systemd/system/chromium-kiosk*.timer
rm -f /etc/systemd/system/wifi-recovery.service
rm -f "${PI_HOME}/.config/systemd/user/familyboard"*.service
rm -f "${PI_HOME}/.config/systemd/user/familyboard"*.timer
rm -f "${PI_HOME}/.config/systemd/user/chromium-kiosk"*.service
rm -f "${PI_HOME}/.config/systemd/user/chromium-kiosk"*.timer
# Fjern drop-in-mapper fra tidligere Edge (f.eks. 10-clone-hdmi.conf som
# endret skjermgeometri etter Chromium-start → halv skjerm)
rm -rf "${PI_HOME}/.config/systemd/user/chromium-kiosk.service.d"
rm -rf "${PI_HOME}/.config/systemd/user/familyboard-kiosk.service.d"

systemctl daemon-reload || true
sudo -u "${PI_USER}" bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
  systemctl --user daemon-reload || true
" 2>/dev/null || true

say "Cleanup fullført"

# =============================================================================
# BLOKK F — loginctl enable-linger
# [ORIGINAL L330] — kreves for user-services ved boot
# =============================================================================
progress "BLOKK F — Aktiver user-service linger"
loginctl enable-linger "${PI_USER}" 2>/dev/null || true
say "Linger aktivert for ${PI_USER}"

# =============================================================================
# Steg 1 — OS-pakker (trimmet fra original)
# [ORIGINAL L327-358] — droppet python/sqlite/build-essential
# =============================================================================
progress "Steg 1 — Installerer pakker"
export DEBIAN_FRONTEND=noninteractive

apt-get update -y -q || warn "apt update feilet — fortsetter likevel"

# Sikre at 'universe' er aktivert (openbox/unclutter/wmctrl bor der på Ubuntu)
if command -v add-apt-repository >/dev/null 2>&1; then
  add-apt-repository -y universe >/dev/null 2>&1 || true
  apt-get update -y -q >/dev/null 2>&1 || true
fi

# System-verktøy (alle Pi-OS-installer trenger disse)
apt-get install -y -q \
  curl ca-certificates jq unclutter xdotool wmctrl \
  x11-xserver-utils xauth \
  fonts-noto-color-emoji \
  iw wireless-tools wpasupplicant \
  hostapd dnsmasq \
  python3-flask python3-requests \
  || warn "noen basispakker feilet"

# openbox = lettvekts kiosk-WM (GNOME/mutter dekorerer --kiosk-vinduet og gir
# halv skjerm + panel; openbox gir ekte fullskjerm). KRITISK — installer den
# separat med retry og verifiser at sesjonen faktisk finnes, ellers havner vi
# i GNOME med halv skjerm (regresjon av problem #5).
retry_apt openbox || warn "openbox-install feilet"
if [[ ! -f /usr/share/xsessions/openbox.desktop ]]; then
  warn "⚠ openbox.desktop mangler etter install — kiosk kan havne i GNOME (halv skjerm)"
  warn "  Prøv manuelt: sudo apt-get install -y openbox, så re-kjør denne installeren"
else
  say "openbox verifisert (/usr/share/xsessions/openbox.desktop)"
fi

# Chromium + codecs (varianthåndtering for Bullseye/Bookworm — [ORIGINAL L344-358])
say "Installerer Chromium..."
if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
  apt-get install -y -q chromium-browser 2>/dev/null \
    || apt-get install -y -q chromium 2>/dev/null \
    || warn "Chromium ikke funnet"
fi
apt-get install -y -q chromium-codecs-ffmpeg 2>/dev/null \
  || apt-get install -y -q chromium-codecs-ffmpeg-extra 2>/dev/null \
  || true

CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || echo /usr/bin/chromium)"
say "Chromium: $CHROMIUM_BIN"

# =============================================================================
# BLOKK H — Popup-purge (Q7)
# Krav fra bruker 2026-05-10: ingen Pi-OS-popups, ingen keyring-låser,
# ingen oppdaterings-/nettverks-/software-varsler.
# =============================================================================
progress "BLOKK H — Slår av popups, varsler og keyring"

# Fjern pakker BARE hvis det ikke drar med seg noe annet. På Raspberry Pi OS
# trixie fjernet f.eks. purge av gnome-keyring også skrivebordsøkta (rpd-labwc),
# så autologin feilet og skjermen ble stående svart. Simuler først; hopp over
# hvis apt vil fjerne flere pakker enn de vi ba om.
safe_purge() {
  local want=() p extra
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && want+=("$p")
  done
  [[ ${#want[@]} -gt 0 ]] || return 0
  extra="$(apt-get -s -y purge "${want[@]}" 2>/dev/null \
    | awk '/^(Purg|Remv) /{print $2}' \
    | grep -vxF -f <(printf '%s\n' "${want[@]}") || true)"
  if [[ -n "$extra" ]]; then
    warn "Fjerner ikke ${want[*]} – det ville også fjernet: $(echo $extra | tr '\n' ' ')"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -y -q purge "${want[@]}" >/dev/null 2>&1 || true
}

# Update-popups — kilde for "Updates available"-bannere.
# VIKTIG: IKKE purge update-notifier — den er en avhengighet av
# ubuntu-desktop-metapakken, og purge drar hele metapakken med seg (som
# markerer skrivebordet som autoremovable). Vi deaktiverer autostart i
# stedet (se autostart-loop under) og masker tjenestene.
systemctl mask update-notifier-download.timer update-notifier-motd.timer 2>/dev/null || true
safe_purge unattended-upgrades
# software-properties-gtk alene er trygt å fjerne (ingen desktop-kaskade)
safe_purge software-properties-gtk

# Generelle systemvarsler
safe_purge notify-osd lxqt-notificationd

# Keyring/wallet (Chromium har --password-store=basic, men annet kan trigge popup)
safe_purge gnome-keyring gnome-keyring-pkcs11
safe_purge seahorse
safe_purge kwalletmanager kwallet-pam libpam-kwallet5
safe_purge libpam-gnome-keyring

# Polkit-popups (sjelden, men kan komme hvis script-er bruker pkexec)
safe_purge policykit-1-gnome polkit-kde-agent-1

# Bluetooth-pairing-popups
safe_purge blueman

# ssh-askpass-popup ved nettverk-ssh
safe_purge ssh-askpass ssh-askpass-gnome

# Maskér nm-applet (uten å fjerne pakken — den brukes av nettverks-stack)
mkdir -p "${PI_HOME}/.config/autostart"
cat > "${PI_HOME}/.config/autostart/nm-applet.desktop" <<'EOF'
[Desktop Entry]
Hidden=true
EOF
# Maskér også andre vanlige autostart-applikasjoner som kan vise popups.
# update-notifier + update-notifier-crash hides her (i stedet for purge)
# for å unngå å dra med ubuntu-desktop-metapakken.
for app in update-notifier update-notifier-crash print-applet \
           blueman-applet xscreensaver; do
  cat > "${PI_HOME}/.config/autostart/${app}.desktop" <<EOF
[Desktop Entry]
Hidden=true
EOF
done
chown -R "${PI_USER}:${PI_USER}" "${PI_HOME}/.config/autostart"

# Slå av automatiske bakgrunns-oppdateringer (ingen "restart kreves"-popup)
systemctl mask packagekit.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask motd-news.timer 2>/dev/null || true

# PCManFM (filhåndterer) skal ikke vise volume-popup ved USB-mount
PCMANFM_CONF_DIR="${PI_HOME}/.config/pcmanfm/LXDE-pi"
mkdir -p "${PCMANFM_CONF_DIR}"
if [[ -f "${PCMANFM_CONF_DIR}/pcmanfm.conf" ]]; then
  cp "${PCMANFM_CONF_DIR}/pcmanfm.conf" "${PCMANFM_CONF_DIR}/pcmanfm.conf.bak-$(date +%Y%m%d%H%M%S)"
fi
cat > "${PCMANFM_CONF_DIR}/pcmanfm.conf" <<'EOF'
[volume]
mount_on_startup=0
mount_removable=0
autorun=0
EOF
chown -R "${PI_USER}:${PI_USER}" "${PI_HOME}/.config/pcmanfm"

say "Popups, varsler og keyring slått av"

# =============================================================================
# BLOKK A — Autologin og GUI (OS-agnostisk via detect-env)
# Velger riktig metode: raspi-config | lightdm | gdm | sddm | getty
# [ORIGINAL L395-424 — nå generalisert i lite/autologin-setup.sh]
# =============================================================================
progress "BLOKK A — Autologin (${FB_AUTOLOGIN_METHOD}) + skjermsparer av"

if [[ -f "${LITE_SRC}/autologin-setup.sh" ]]; then
  # shellcheck disable=SC1091
  source "${LITE_SRC}/autologin-setup.sh"
  setup_autologin "${PI_USER}"
  disable_screensaver
else
  warn "autologin-setup.sh mangler — hopper over autologin (må settes manuelt)"
fi

# =============================================================================
# Steg 8 — Skriv kiosk-konfig (drastisk forenklet vs original)
# [ORIGINAL L989-1080] — kun KIOSK_URL, ingen secrets
# =============================================================================
progress "Steg 8 — Skriver kiosk-konfig"

USER_CONF_DIR="${PI_HOME}/.config/familyboard"
mkdir -p "${USER_CONF_DIR}"

cat > "${USER_CONF_DIR}/kiosk.env" <<EOF
# FamilyBoard Edge Lite — kiosk-konfig
# Endre KIOSK_URL og restart chromium-kiosk.service for å bytte mål.
KIOSK_URL=${KIOSK_URL}
RELAUNCH_DELAY=10
EOF
chown -R "${PI_USER}:${PI_USER}" "${USER_CONF_DIR}"
say "Skrevet ${USER_CONF_DIR}/kiosk.env"

# =============================================================================
# Steg 10 — Kiosk launcher-script
# [ORIGINAL L1112-1286] — forenklet (ingen /api/kiosk_url-fetch)
# =============================================================================
progress "Steg 10 — Installerer kiosk-launcher"

mkdir -p "${APP_DIR}/kiosk"

cat > "${APP_DIR}/kiosk/familyboard-kiosk.sh" <<'KIOSK_EOF'
#!/usr/bin/env bash
# FamilyBoard Edge Lite — Chromium kiosk launcher (robust)
# Kjøres av chromium-kiosk.service (systemd --user).
# EIER hele livssyklusen selv via intern while-loop → nøyaktig én Chromium.
# systemd-servicen bruker Restart=on-failure (ikke always) for å unngå
# dobbel-restart / overlappende instanser.
#
# Driftssikkerhet lært fra live-install (Ubuntu 24.04 + snap chromium):
#   1. Snap-chromium kan KUN skrive profil under ~/snap/chromium/common/
#      → detekter snap og velg riktig profil-sti (ellers Permission denied 13)
#   2. Selv-helbredende profil: hvis mappa ikke er skrivbar, slett og lag ny
#   3. Sett skjerm-geometri ÉN gang FØR Chromium (aldri etter — det gir halv
#      skjerm). Dynamisk oppløsning (ikke hardkodet 1920x1080).
#   4. Tving vindus-geometri til primær-skjermens størrelse + --kiosk.

set -u
exec > >(tee -a /tmp/familyboard-kiosk.log) 2>&1

log() { echo "[$(date -Is)] $*"; }

# --- Last konfig ---
KENV="${HOME}/.config/familyboard/kiosk.env"
if [[ -f "$KENV" ]]; then
  set -a; source "$KENV"; set +a
fi
KIOSK_URL="${KIOSK_URL:-https://familyboard.cloud}"
RECOVERY_URL="http://127.0.0.1:5001"
RELAUNCH_DELAY="${RELAUNCH_DELAY:-10}"
# Ekstra Chromium-flagg for feilsøking, f.eks. i kiosk.env:
#   CHROMIUM_EXTRA_FLAGS="--remote-debugging-port=9222 --disable-gpu"
read -r -a EXTRA_ARGS <<<"${CHROMIUM_EXTRA_FLAGS:-}"

# --- Wayland-økt? (Raspberry Pi OS Bookworm/Trixie kjører labwc/wayfire) ---
# Da er :0 ofte innloggingsskjermens Xwayland (eid av lightdm) – Chromium blir
# avvist der («Invalid MIT-MAGIC-COOKIE-1 key»). Bruk Wayland-socketen i stedet.
SESSION_KIND="x11"
_wp="$(pgrep -u "$(id -u)" -x 'labwc|wayfire|sway|cage|weston' 2>/dev/null | head -1)"
if [[ -n "$_wp" ]]; then
  _wenv="$(tr '\0' '\n' 2>/dev/null < "/proc/${_wp}/environ" || true)"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  _wd="$(sed -n 's/^WAYLAND_DISPLAY=//p' <<<"$_wenv" | head -1)"
  if [[ -z "$_wd" ]]; then
    for _ws in "${XDG_RUNTIME_DIR}"/wayland-[0-9]; do [[ -S "$_ws" ]] && _wd="${_ws##*/}" && break; done
  fi
  if [[ -n "$_wd" && -S "${XDG_RUNTIME_DIR}/${_wd}" ]]; then
    SESSION_KIND="wayland"
    export WAYLAND_DISPLAY="$_wd"
    unset DISPLAY XAUTHORITY
    log "Wayland-økt: $(cat /proc/${_wp}/comm 2>/dev/null) WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
  fi
fi

# --- X-miljø (for xrandr + chromium) ---
if [[ "$SESSION_KIND" == "x11" ]]; then
# Ta DISPLAY/XAUTHORITY fra den kjørende skrivebordsøkta – den har alltid riktig
# X-cookie. (En gammel ~/.Xauthority ga «Invalid MIT-MAGIC-COOKIE-1 key».)
for _p in $(pgrep -u "$(id -u)" -x 'openbox|lxsession|lxsession-xdg-autostart|xfce4-session|gnome-shell|Xsession|x-session-manager' 2>/dev/null); do
  _env="$(tr '\0' '\n' 2>/dev/null < "/proc/${_p}/environ")" || continue
  _d="$(sed -n 's/^DISPLAY=//p' <<<"$_env" | head -1)"
  [[ -n "$_d" ]] || continue
  export DISPLAY="$_d"
  _x="$(sed -n 's/^XAUTHORITY=//p' <<<"$_env" | head -1)"
  [[ -n "$_x" && -f "$_x" ]] && export XAUTHORITY="$_x"
  break
done
# Ellers: finn faktisk X-display dynamisk (GDM kan gi :1, ikke alltid :0).
if [[ -z "${DISPLAY:-}" ]]; then
  for _s in /tmp/.X11-unix/X*; do
    [[ -e "$_s" ]] || continue
    DISPLAY=":${_s##*/X}"
    break
  done
fi
export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${XAUTHORITY:-}" ]]; then
  for _xa in "${HOME}/.Xauthority" "/run/user/$(id -u)/gdm/Xauthority" \
             "/var/run/lightdm/${USER:-$(id -un)}/xauthority" "/run/lightdm/${USER:-$(id -un)}/xauthority"; do
    [[ -f "$_xa" ]] && export XAUTHORITY="$_xa" && break
  done
fi
log "X: DISPLAY=${DISPLAY} XAUTHORITY=${XAUTHORITY:-unset}"
fi

# --- Finn Chromium-binær ---
CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || echo /usr/bin/chromium)"

# --- Profil-sti: snap-chromium MÅ ha profil under ~/snap/chromium/common ---
if readlink -f "$CHROMIUM_BIN" 2>/dev/null | grep -q '/snap/' \
   || snap list chromium >/dev/null 2>&1; then
  KIOSK_PROFILE_DIR="${HOME}/snap/chromium/common/familyboard-kiosk-profile"
  log "Chromium er snap → profil: ${KIOSK_PROFILE_DIR}"
else
  KIOSK_PROFILE_DIR="${HOME}/.config/familyboard-kiosk-profile"
  log "Chromium er deb → profil: ${KIOSK_PROFILE_DIR}"
fi

# --- Selv-helbredende profil: fjern hvis ikke skrivbar (root-eid o.l.) ---
if [[ -e "$KIOSK_PROFILE_DIR" && ! -w "$KIOSK_PROFILE_DIR" ]]; then
  log "Profil ikke skrivbar — fjerner og gjenoppretter"
  rm -rf "$KIOSK_PROFILE_DIR" 2>/dev/null || true
fi
mkdir -p "$KIOSK_PROFILE_DIR" 2>/dev/null || true

# --- Robust skjerm-oppsett (X11): speil alle skjermer til primær, ÉN gang ---
SCREEN_W=1920; SCREEN_H=1080
setup_display_x11() {
  command -v xrandr >/dev/null 2>&1 || return 0
  # Vent på at X er klar (opptil 20s)
  local i
  for i in $(seq 1 20); do xrandr >/dev/null 2>&1 && break; sleep 1; done
  xrandr >/dev/null 2>&1 || { log "xrandr ikke tilgjengelig — hopper over skjerm-oppsett"; return 0; }

  local primary mode others o
  primary="$(xrandr | awk '/ connected primary/{print $1; exit}')"
  [[ -z "$primary" ]] && primary="$(xrandr | awk '/ connected/{print $1; exit}')"
  [[ -z "$primary" ]] && { log "Ingen tilkoblet skjerm funnet"; return 0; }

  # Primærens aktive/foretrukne modus (linje med * eller +)
  mode="$(xrandr | awk -v p="$primary" '
    $0 ~ "^"p" connected"{f=1; next}
    /^[A-Za-z]/{f=0}
    f && /[*+]/{gsub(/[^0-9x]/,"",$1); print $1; exit}')"
  [[ -z "$mode" ]] && mode="1920x1080"

  # Sett primær til modus @ 0,0. Dette nullstiller framebuffer-bredden
  # (fjerner ev. gammelt extended-oppsett som ga halv skjerm).
  xrandr --output "$primary" --primary --mode "$mode" --pos 0x0 --rotate normal 2>/dev/null || \
    xrandr --output "$primary" --primary --auto --pos 0x0 2>/dev/null || true

  # Speil alle andre tilkoblede skjermer til primær (samme innhold, samme fb)
  for o in $(xrandr | awk '/ connected/{print $1}'); do
    [[ "$o" == "$primary" ]] && continue
    xrandr --output "$o" --same-as "$primary" --mode "$mode" 2>/dev/null \
      || xrandr --output "$o" --same-as "$primary" --auto 2>/dev/null \
      || xrandr --output "$o" --off 2>/dev/null || true
  done

  SCREEN_W="${mode%x*}"
  SCREEN_H="${mode#*x}"
  log "Skjerm satt: primær=${primary} modus=${mode} (speiler øvrige)"

  # Skjermsparer/DPMS av + skjul musepeker (X11)
  xset -dpms s off s noblank 2>/dev/null || true
  command -v unclutter >/dev/null 2>&1 && (unclutter -idle 1 -root >/dev/null 2>&1 &) || true
}

# --- Velg mål-URL: Cloud hvis nåbar, ellers lokal recovery-side ---
pick_target() {
  if curl -fsS --max-time 5 -o /dev/null "${KIOSK_URL}/healthz" 2>/dev/null \
     || curl -fsS --max-time 5 -o /dev/null "${KIOSK_URL}" 2>/dev/null; then
    echo "${KIOSK_URL}"
  else
    log "Cloud ikke nåbar — fallback til recovery (${RECOVERY_URL})" >&2
    echo "${RECOVERY_URL}"
  fi
}

# =============================================================================
# Hovedloop — nøyaktig én Chromium om gangen. Restart internt hvis den dør.
# =============================================================================
while true; do
  # Skjerm settes FØR HVER chromium-start. Kritisk ved treg kald-boot: hvis X
  # ikke var klar ved første forsøk, får neste runde speilingen på plass — ellers
  # kunne dual-HDMI halv-skjerm-bugen (framebuffer extended) blitt permanent.
  [[ "$SESSION_KIND" == "x11" ]] && setup_display_x11

  # Rens lock-filer + drep ev. rester før ny start
  rm -f "${KIOSK_PROFILE_DIR}/SingletonLock" \
        "${KIOSK_PROFILE_DIR}/SingletonSocket" \
        "${KIOSK_PROFILE_DIR}/SingletonCookie" 2>/dev/null || true
  pkill -f "chromium.*familyboard-kiosk-profile" 2>/dev/null || true
  sleep 1

  TARGET_URL="$(pick_target)"
  log "Starter Chromium mot: ${TARGET_URL} (${SCREEN_W}x${SCREEN_H})"

  # Fallback: hvis window-manageren dekorerer/halv-størrelser --kiosk-vinduet
  # (f.eks. GNOME/mutter), tving fullskjerm via EWMH når vinduet dukker opp.
  # Ufarlig under openbox (der --kiosk allerede er fullskjerm).
  if [[ "$SESSION_KIND" == "x11" ]] && command -v wmctrl >/dev/null 2>&1; then
    (
      for _w in $(seq 1 30); do
        ids="$(wmctrl -l 2>/dev/null | grep -iE 'dashboard|familyboard|chromium' | awk '{print $1}')"
        if [[ -n "$ids" ]]; then
          for id in $ids; do
            wmctrl -i -r "$id" -b add,fullscreen 2>/dev/null || true
          done
          break
        fi
        sleep 1
      done
    ) &
  fi

  # -------------------------------------------------------------------------
  # Chromium kiosk-flagg [ORIGINAL L1256-1279]
  # -------------------------------------------------------------------------
  # MERK: IKKE bruk --window-size/--window-position sammen med --kiosk —
  # de tvinger Chromium til vindusmodus (viser verktøylinje). Med korrekt
  # framebuffer (display-setup) + openbox-sesjon dekker --kiosk hele skjermen.
  if [[ "$SESSION_KIND" == "wayland" ]]; then
    PLATFORM_ARGS=(--ozone-platform=wayland --enable-features=UseOzonePlatform,SharedArrayBuffer)
  else
    PLATFORM_ARGS=(--ozone-platform=x11 --enable-features=SharedArrayBuffer)
  fi
  "${CHROMIUM_BIN}" \
    "${PLATFORM_ARGS[@]}" \
    "${EXTRA_ARGS[@]}" \
    --kiosk \
    --start-fullscreen \
    --no-first-run \
    --no-default-browser-check \
    --disable-infobars \
    --disable-extensions \
    --disable-plugins \
    --disable-features=Translate,TranslateUI,VizDisplayCompositor \
    --lang=nb-NO \
    --accept-lang=nb-NO,nb,no,en \
    --password-store=basic \
    --user-data-dir="${KIOSK_PROFILE_DIR}" \
    --profile-directory="FamilyBoardKiosk" \
    --disable-background-timer-throttling \
    --disable-renderer-backgrounding \
    --disable-backgrounding-occluded-windows \
    --disable-component-extensions-with-background-pages \
    --no-sandbox \
    --disable-setuid-sandbox \
    --disable-dev-shm-usage \
    --noerrdialogs \
    --disable-session-crashed-bubble \
    --disable-translate \
    "${TARGET_URL}"

  EC=$?
  log "Chromium avsluttet (exit ${EC}) — starter på nytt om ${RELAUNCH_DELAY}s"
  sleep "${RELAUNCH_DELAY}"
done
KIOSK_EOF

chmod +x "${APP_DIR}/kiosk/familyboard-kiosk.sh"
chown -R "${PI_USER}:${PI_USER}" "${APP_DIR}"
say "Skrevet ${APP_DIR}/kiosk/familyboard-kiosk.sh"

# =============================================================================
# BLOKK C — systemd kiosk-service-mal
# Launcheren eier livssyklusen selv (intern while-loop), så servicen bruker
# Restart=on-failure — IKKE always. Det unngår dobbel-restart / overlappende
# Chromium-instanser (som ga forvirrende krasj-loop under debugging).
# =============================================================================
progress "BLOKK C — Installerer systemd kiosk-service"

# Fjern gamle drop-in-mapper fra tidligere Edge (f.eks. 10-clone-hdmi.conf
# som endret skjermen ETTER Chromium-start og ga halv skjerm).
rm -rf "${PI_HOME}/.config/systemd/user/chromium-kiosk.service.d" 2>/dev/null || true

mkdir -p "${PI_HOME}/.config/systemd/user"

# Installer display-setup-scriptet (kjøres som ExecStartPre med eksplisitt
# DISPLAY/XAUTHORITY — det er det min in-launcher-xrandr feilet på).
if [[ -f "${LITE_SRC}/familyboard-display-setup.sh" ]]; then
  install -m 0755 "${LITE_SRC}/familyboard-display-setup.sh" \
    /usr/local/bin/familyboard-display-setup.sh
  say "Display-setup installert (/usr/local/bin/familyboard-display-setup.sh)"
fi

cat > "${PI_HOME}/.config/systemd/user/chromium-kiosk.service" <<EOF
[Unit]
Description=Chromium i kioskmodus (FamilyBoard Edge Lite)
After=graphical-session.target network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/familyboard/kiosk.env
WorkingDirectory=%h/familyboard-lite
# Sett skjerm-geometri FØR Chromium (utprøvd mønster fra gamle Edge):
# eksplisitt DISPLAY/XAUTHORITY inne i scriptet → speiler skjermer →
# framebuffer = skjermstørrelse → --kiosk fyller hele.
ExecStartPre=/usr/local/bin/familyboard-display-setup.sh
ExecStart=%h/familyboard-lite/kiosk/familyboard-kiosk.sh
# Launcheren looper internt; on-failure fanger kun hvis SELVE scriptet dør.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

# Fjern ev. gammel restart-timer — launcheren håndterer restart selv, og en
# ekstra timer skapte overlappende instanser. Ukentlig minne-restart kan
# heller gjøres via en enkel cron/timer senere hvis det viser seg nødvendig.
rm -f "${PI_HOME}/.config/systemd/user/chromium-kiosk-restart.timer" 2>/dev/null || true
rm -f "${PI_HOME}/.config/systemd/user/chromium-kiosk-restart.service" 2>/dev/null || true

# Nattlig omstart av Chromium kl. 04:15 (minnerydding). Bruker
# 'systemctl restart', som stopper launcher + Chromium helt før ny start,
# så det blir aldri to instanser. Dashbordet laster i tillegg seg selv på
# nytt 03:30-03:50 (Cloud), som holder kalenderen fersk.
cat > "${PI_HOME}/.config/systemd/user/chromium-kiosk-nightly.service" <<'UNIT'
[Unit]
Description=Nattlig omstart av FamilyBoard-kiosk

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --user restart chromium-kiosk.service
UNIT

cat > "${PI_HOME}/.config/systemd/user/chromium-kiosk-nightly.timer" <<'UNIT'
[Unit]
Description=Start FamilyBoard-kiosk på nytt hver natt kl. 04:15

[Timer]
OnCalendar=*-*-* 04:15:00
Persistent=false

[Install]
WantedBy=timers.target
UNIT

chown -R "${PI_USER}:${PI_USER}" "${PI_HOME}/.config/systemd"
say "systemd-service installert (Restart=on-failure, nattlig omstart 04:15)"

# =============================================================================
# BLOKK G — Fjern gammel kiosk-autostart (OS-agnostisk)
# Rydder LXDE / Wayfire / labwc / GNOME-autostart avhengig av detektert WM.
# [ORIGINAL L1417-1430 — generalisert]
# =============================================================================
progress "BLOKK G — Fjerner gammel autostart (${FB_AUTOSTART_KIND})"

# LXDE (Bullseye, Pi 3/Zero — og Ubuntu med LXDE)
LXDE_AUTOSTART="${PI_HOME}/.config/lxsession/LXDE-pi/autostart"
[[ -f "$LXDE_AUTOSTART" ]] || LXDE_AUTOSTART="${PI_HOME}/.config/lxsession/LXDE/autostart"
if [[ -f "${LXDE_AUTOSTART}" ]]; then
  cp "${LXDE_AUTOSTART}" "${LXDE_AUTOSTART}.bak-$(date +%Y%m%d%H%M%S)"
  sed -i '/chromium/d; /familyboard/d' "${LXDE_AUTOSTART}" || true
  say "LXDE autostart ryddet"
fi

# Wayfire (Bookworm Pi 4/5 tidlig)
WAYFIRE_CONF="${PI_HOME}/.config/wayfire.ini"
if [[ -f "${WAYFIRE_CONF}" ]]; then
  cp "${WAYFIRE_CONF}" "${WAYFIRE_CONF}.bak-$(date +%Y%m%d%H%M%S)"
  sed -i '/chromium/d; /familyboard/d' "${WAYFIRE_CONF}" || true
  say "Wayfire autostart ryddet"
fi

# labwc (Raspberry Pi OS Bookworm/Trixie) — NAKEN KIOSK-ØKT, som gamle Edge
# hadde med openbox. Systemets /etc/xdg/labwc/autostart starter panel
# (wf-panel-pi, som også er nm-applet → «Authentication required by Wi-Fi
# network»-vinduer over dashbordet), skrivebord (pcmanfm-pi) og xdg-autostart
# (polkit/keyring m.m.). En egen ~/.config/labwc/autostart erstatter systemets.
# Vi beholder bare kanshi (skjermoppsett). Kiosken startes av systemd.
# Fullt skrivebord igjen: rm ~/.config/labwc/autostart && sudo reboot
LABWC_AUTOSTART="${PI_HOME}/.config/labwc/autostart"
if [[ -f /etc/xdg/labwc/autostart ]]; then
  mkdir -p "$(dirname "${LABWC_AUTOSTART}")"
  if [[ -f "${LABWC_AUTOSTART}" ]] && ! grep -q "FamilyBoard Edge Lite" "${LABWC_AUTOSTART}"; then
    cp "${LABWC_AUTOSTART}" "${LABWC_AUTOSTART}.bak-$(date +%Y%m%d%H%M%S)"
  fi
  {
    echo "# FamilyBoard Edge Lite — naken kiosk-økt (ingen panel/skrivebord/popups)."
    echo "# Kiosken startes av systemd (chromium-kiosk.service), ikke herfra."
    echo "# Fullt skrivebord igjen: rm ~/.config/labwc/autostart && sudo reboot"
    grep -E '^[^#]*kanshi' /etc/xdg/labwc/autostart || true
  } > "${LABWC_AUTOSTART}"
  chown -R "${PI_USER}:${PI_USER}" "$(dirname "${LABWC_AUTOSTART}")"
  say "labwc: naken kiosk-økt (uten panel, skrivebord og WiFi-passordvinduer)"
elif [[ -f "${LABWC_AUTOSTART}" ]]; then
  cp "${LABWC_AUTOSTART}" "${LABWC_AUTOSTART}.bak-$(date +%Y%m%d%H%M%S)"
  sed -i '/chromium/d; /familyboard/d' "${LABWC_AUTOSTART}" || true
  say "labwc autostart ryddet"
fi

# openbox autostart — VIKTIG: gamle Edge la en 'exec snap run chromium ...
# http://127.0.0.1:5000'-kiosk her, som starter en KONKURRERENDE kiosk under
# openbox-sesjonen (mot dødt localhost). Vi eier fila: backup + skriv ren
# versjon som KUN gjør skjermsparer-av. Kiosken startes av systemd-tjenesten.
OPENBOX_AUTOSTART="${PI_HOME}/.config/openbox/autostart"
mkdir -p "$(dirname "$OPENBOX_AUTOSTART")"
if [[ -f "${OPENBOX_AUTOSTART}" ]]; then
  cp "${OPENBOX_AUTOSTART}" "${OPENBOX_AUTOSTART}.bak-$(date +%Y%m%d%H%M%S)"
fi
cat > "${OPENBOX_AUTOSTART}" <<'EOF'
# FamilyBoard Edge Lite — openbox autostart
# Kiosken startes av systemd (chromium-kiosk.service), IKKE herfra.
# (Gammel Edge la en konkurrerende chromium-kiosk her — den er fjernet.)
xset s off
xset s noblank
xset -dpms
# Gi kiosk-tjenesten (samme bruker) tilgang til skjermen uten X-cookie –
# en gammel ~/.Xauthority ga ellers «Invalid MIT-MAGIC-COOKIE-1 key».
xhost +SI:localuser:"$(id -un)" >/dev/null 2>&1
systemctl --user import-environment DISPLAY XAUTHORITY 2>/dev/null
EOF
chown -R "${PI_USER}:${PI_USER}" "$(dirname "$OPENBOX_AUTOSTART")"
say "openbox autostart ryddet (ingen konkurrerende kiosk)"

# Fjern gammel Edge kiosk-profil (peker på localhost:5000)
rm -rf "${PI_HOME}/snap/chromium/common/familyboard-kiosk" 2>/dev/null || true

# GNOME / XDG-autostart (Ubuntu Desktop) — fjern kiosk .desktop-filer
XDG_AUTOSTART="${PI_HOME}/.config/autostart"
if [[ -d "${XDG_AUTOSTART}" ]]; then
  find "${XDG_AUTOSTART}" -maxdepth 1 -name '*familyboard*' -delete 2>/dev/null || true
  find "${XDG_AUTOSTART}" -maxdepth 1 -name '*kiosk*' -delete 2>/dev/null || true
  say "XDG/GNOME kiosk-autostart ryddet"
fi

# =============================================================================
# BLOKK J — Robusthet (J1-J7)
# Brukerens krav 2026-05-10: alltid boot til desktop, alltid komme på nett.
# =============================================================================
progress "BLOKK J — Robusthet (alltid boot til desktop)"

# --- J1: Boot fra SD-kort først (forhindrer USB-boot) ---
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_order B1 2>/dev/null || true
  say "J1: SD-kort prioritert som boot-enhet"
fi

# --- J2: Cap network-wait-online til 15s ---
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/timeout.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=15
EOF

mkdir -p /etc/systemd/system/NetworkManager-wait-online.service.d
cat > /etc/systemd/system/NetworkManager-wait-online.service.d/timeout.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/nm-online -s -q --timeout=15
EOF
say "J2: Network-wait kappet til 15s"

# --- J3: Ingen USB-automount ---
# pcmanfm-konfig allerede skrevet i Blokk H. Her: udev-regel som backstop.
cat > /etc/udev/rules.d/85-familyboard-no-automount.rules <<'EOF'
# FamilyBoard Edge Lite: ikke auto-mount USB-disker i kiosk-modus
# (wifi-recovery.sh mounter eksplisitt når den trenger det)
ENV{ID_FS_USAGE}=="filesystem", ENV{UDISKS_IGNORE}="1"
EOF
udevadm control --reload-rules 2>/dev/null || true

# Fjern gvfs-backends så ingen popups
safe_purge gvfs-backends
say "J3: USB-automount slått av"

# --- J4: Logg-størrelse cap ---
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/familyboard.conf <<'EOF'
[Journal]
# Behold loggen over omstart, så nettfall o.l. kan feilsøkes etterpå
Storage=persistent
SystemMaxUse=200M
SystemKeepFree=500M
RuntimeMaxUse=50M
EOF
mkdir -p /var/log/journal
systemctl restart systemd-journald 2>/dev/null || true

cat > /etc/logrotate.d/familyboard-kiosk <<'EOF'
/tmp/familyboard-kiosk.log {
    size 10M
    rotate 3
    missingok
    notifempty
    compress
    copytruncate
}
/var/log/familyboard-wifi-recovery.log
/var/log/familyboard-hotspot.log {
    size 5M
    rotate 3
    missingok
    notifempty
    compress
}
EOF
systemctl restart systemd-journald 2>/dev/null || true
say "J4: Logg-cap konfigurert (journal 200M, kiosk-log 10M)"

# --- J5: WiFi power-saving av (forhindrer drop i kiosk-modus) ---
cat > /etc/systemd/system/wifi-no-powersave.service <<'EOF'
[Unit]
Description=Slå av WiFi power saving (forhindrer drop i kiosk-modus)
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/sbin/iw wlan0 set power_save off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable wifi-no-powersave.service 2>/dev/null || true
say "J5: WiFi power-save deaktivert"

# --- J5c: WiFi skal aldri gi opp ---
# Faller WiFi ut, ber NetworkManager om passordet på nytt. Uten svar («no
# secrets») gir den opp profilen etter noen forsøk – da ble skjermen stående
# uten nett i timevis. Uendelige forsøk for alle WiFi-profiler.
if command -v nmcli >/dev/null 2>&1; then
  while IFS=: read -r _name _type; do
    [[ "$_type" == "802-11-wireless" ]] || continue
    nmcli connection modify "$_name" connection.autoconnect yes connection.autoconnect-retries 0 2>/dev/null || true
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
  say "J5c: WiFi prøver å koble til igjen i det uendelige"
fi

# --- J5b: Skjermblanking av på Raspberry Pi OS (gjelder også Wayland/labwc) ---
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_blanking 1 2>/dev/null && say "J5b: Skjermblanking slått av (raspi-config)" || true
fi

# --- J6: Kiosk Restart=always (allerede satt i Blokk C above) ---
say "J6: chromium-kiosk.service har Restart=always (Blokk C)"

# --- J6b: Chromium-policy for kiosken ---
# Google-kalenderen er en iframe (google.com inne i familyboard.cloud). Den ser
# bare innloggingen hvis tredjeparts-cookies er tillatt – Chromium på Raspberry
# Pi OS blokkerer dem, så private kalendere ble skjult («du har ikke tillatelse»).
_FB_POLICY='{
  "BlockThirdPartyCookies": false,
  "TranslateEnabled": false
}'
for _pd in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
  mkdir -p "$_pd" && printf '%s\n' "$_FB_POLICY" > "${_pd}/familyboard.json"
done
say "J6b: Chromium-policy satt (tredjeparts-cookies for kalender, ingen oversetting)"

# --- J6c: Nettvakt – koble WiFi til på nytt hvis nettet har vært borte i 3 min ---
if [[ -f "${LITE_SRC}/recovery/familyboard-net-watchdog.sh" ]]; then
  install -m 0755 "${LITE_SRC}/recovery/familyboard-net-watchdog.sh" /usr/local/bin/familyboard-net-watchdog.sh
  cat > /etc/systemd/system/familyboard-net-watchdog.service <<'UNIT'
[Unit]
Description=FamilyBoard nettvakt (kobler WiFi til på nytt ved nettfall)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/familyboard-net-watchdog.sh
UNIT
  cat > /etc/systemd/system/familyboard-net-watchdog.timer <<'UNIT'
[Unit]
Description=Kjør FamilyBoard nettvakt hvert minutt

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now familyboard-net-watchdog.timer 2>/dev/null || true
  say "J6c: Nettvakt aktivert (WiFi kobles til på nytt etter 3 min uten nett)"
fi

# --- J7: Recovery-server + HTML ---
# NB: || warn på hvert steg — under set -e ville én manglende fil ellers
# hard-abortet installasjonen midt i (med alt over allerede utført).
if [[ -d "$LITE_SRC" ]]; then
  install -m 0755 "${LITE_SRC}/recovery/familyboard-recovery-server.py" \
    /usr/local/bin/familyboard-recovery-server.py || warn "recovery-server install feilet"
  install -d -m 0755 /usr/local/share/familyboard || true
  if install -m 0644 "${LITE_SRC}/share/recovery.html" \
       /usr/local/share/familyboard/recovery.html; then
    # Injiser faktisk kiosk-URL i recovery-siden (erstatter __KIOSK_URL__)
    sed -i "s|__KIOSK_URL__|${KIOSK_URL}|g" /usr/local/share/familyboard/recovery.html || true
  else
    warn "recovery.html install feilet"
  fi
  install -m 0644 "${LITE_SRC}/systemd/familyboard-recovery.service" \
    /etc/systemd/system/familyboard-recovery.service || warn "recovery.service install feilet"
  systemctl daemon-reload || true
  systemctl enable familyboard-recovery.service || warn "kunne ikke enable recovery-service"
  say "J7: Recovery-server installert (127.0.0.1:5001)"
fi

# =============================================================================
# BLOKK I — WiFi-recovery (Q6)
# Brukerens krav 2026-05-10: Pi må kunne flyttes mellom hjem/WiFi uten
# re-flash. To-lags fallback (USB-config + hotspot).
# =============================================================================
progress "BLOKK I — WiFi-recovery (USB-fallback + hotspot)"

# LITE_SRC ble satt øverst (ved detect-env). Gjenbruk den.
if [[ ! -d "$LITE_SRC" ]]; then
  warn "lite/-mappen mangler i installasjons-kilden. Hopper over Blokk I."
  warn "WiFi-recovery vil IKKE være installert. Fix: hent fra git og kjør på nytt."
else
  # Recovery-skripter til /usr/local/bin (|| warn — ikke abort under set -e)
  install -m 0755 "${LITE_SRC}/recovery/familyboard-wifi-recovery.sh" \
    /usr/local/bin/familyboard-wifi-recovery.sh || warn "wifi-recovery install feilet"
  install -m 0755 "${LITE_SRC}/recovery/familyboard-hotspot-start.sh" \
    /usr/local/bin/familyboard-hotspot-start.sh || warn "hotspot-start install feilet"
  install -m 0755 "${LITE_SRC}/recovery/hotspot-config-server.py" \
    /usr/local/bin/familyboard-hotspot-config-server.py || warn "hotspot-config install feilet"
  install -m 0755 "${LITE_SRC}/recovery/familyboard-wifi-connect.sh" \
    /usr/local/bin/familyboard-wifi-connect.sh || warn "wifi-connect install feilet"
  say "Recovery-skripter installert i /usr/local/bin/"

  # systemd-units til /etc/systemd/system/
  for unit in wifi-recovery.service familyboard-hotspot.service \
              familyboard-hotspot-dnsmasq.service familyboard-hotspot-web.service; do
    install -m 0644 "${LITE_SRC}/systemd/${unit}" "/etc/systemd/system/${unit}" \
      || warn "${unit} install feilet"
  done
  say "systemd-units installert"

  # Aktivér KUN wifi-recovery (hotspot kjøres kun ved behov)
  systemctl daemon-reload || true
  systemctl enable wifi-recovery.service || warn "kunne ikke enable wifi-recovery"
  say "wifi-recovery.service aktivert (kjøres ved hver boot)"

  # Forhindre at NetworkManager/dnsmasq auto-starter på systemnivå
  # (dnsmasq starter kun når hotspot trenger den)
  systemctl mask dnsmasq.service 2>/dev/null || true
  # Behold hostapd masked — vi starter den via familyboard-hotspot.service
  systemctl disable hostapd.service 2>/dev/null || true
  systemctl mask hostapd.service 2>/dev/null || true
fi

# =============================================================================
# BLOKK D — Aktivér user-services via DBUS
# [ORIGINAL L1346-1355] — bash-pattern kopiert, forenklet til kun kiosk
# =============================================================================
progress "BLOKK D — Aktiverer user-services"

sudo -u "${PI_USER}" bash -lc "
  export XDG_RUNTIME_DIR=/run/user/\$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
  systemctl --user daemon-reload
  systemctl --user enable chromium-kiosk.service
  # Rydd ev. gammel timer fra tidligere versjon
  systemctl --user disable chromium-kiosk-restart.timer 2>/dev/null || true
  systemctl --user enable --now chromium-kiosk-nightly.timer
" || warn "kunne ikke aktivere user-services automatisk — kjør manuelt etter neste login"

say "User-services aktivert (starter ved neste login eller reboot)"

# =============================================================================
# Final
# =============================================================================
echo
echo "================================================"
say "🎉 Edge Lite v${EDGE_LITE_VERSION} installert (OS: ${FB_OS_PRETTY})"
echo
echo "📺 Kiosk-URL: ${KIOSK_URL}"
echo "🔧 Konfig:     ${USER_CONF_DIR}/kiosk.env"
echo "📜 Logg:       /tmp/familyboard-kiosk.log"
echo
echo "🔄 For å starte kiosken: reboot (eller logg ut + inn)"
echo "   sudo reboot"
echo
echo "🩺 Diagnose:"
echo "   systemctl --user status chromium-kiosk.service"
echo "   tail -f /tmp/familyboard-kiosk.log"
echo
warn "IKKE kjør 'sudo apt autoremove' på denne Pi-en — popup-purgen fjernet"
warn "ubuntu-desktop-metapakken, og autoremove ville da fjerne skrivebordet."

REPLY="n"
[[ -z "${FB_NO_REBOOT_PROMPT:-}" ]] && ask "Start på nytt nå så skjermen tar i bruk FamilyBoard? [J/n] "
if [[ -n "$TTY_IN" && -z "${FB_NO_REBOOT_PROMPT:-}" && "${REPLY,,}" != n* ]]; then
  say "Starter på nytt om 5 sekunder…"
  sleep 5
  reboot
fi
