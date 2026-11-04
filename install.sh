#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge – installasjon med én kommando
# =============================================================================
#   curl -fsSL https://raw.githubusercontent.com/Toar22/familyboard-edge/main/install.sh | sudo bash
#
# Henter (eller oppdaterer) installeren til ~/familyboard-edge og starter den.
# Installeren spør etter skjerm-lenken fra familyboard.cloud → «Min konto» → URLer.
# Lenken kan også gis direkte:
#   curl -fsSL …/install.sh | sudo KIOSK_URL="https://familyboard.cloud/d/DIN-KODE" bash
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Kjør med sudo:  curl -fsSL https://raw.githubusercontent.com/Toar22/familyboard-edge/main/install.sh | sudo bash" >&2
  exit 1
fi
U="${SUDO_USER:-}"
if [[ -z "$U" || "$U" == "root" ]]; then
  echo "Kjør som vanlig bruker med sudo (ikke som root), så kiosken settes opp for riktig bruker." >&2
  exit 1
fi
H="$(eval echo ~"$U")"
DIR="${H}/familyboard-edge"

command -v git >/dev/null 2>&1 || { echo "▶ Installerer git…"; apt-get update -y -q >/dev/null; apt-get install -y -q git >/dev/null; }

if [[ -d "${DIR}/.git" ]]; then
  echo "▶ Oppdaterer ${DIR}…"
  sudo -u "$U" git -C "$DIR" pull --ff-only -q
else
  echo "▶ Henter FamilyBoard Edge til ${DIR}…"
  sudo -u "$U" git clone -q https://github.com/Toar22/familyboard-edge.git "$DIR"
fi

# Spørsmålene må leses fra terminalen (stdin er dette skriptet når det kommer via curl)
if [[ -r /dev/tty ]]; then
  exec bash "${DIR}/install_thin_pi.sh" < /dev/tty
else
  exec bash "${DIR}/install_thin_pi.sh"
fi
