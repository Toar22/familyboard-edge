#!/usr/bin/env bash
# =============================================================================
# FamilyBoard Edge Lite — oppdater denne skjermen
# =============================================================================
# Henter siste versjon fra https://github.com/Toar22/familyboard-edge og kjører
# installeren på nytt. Skjerm-URL-en (KIOSK_URL) gjenbrukes, så den spør ikke.
#
# Bruk:
#   bash ~/familyboard-edge/update_thin_pi.sh
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "▶ Henter siste versjon…"
BEFORE="$(git rev-parse HEAD)"
git pull --ff-only
AFTER="$(git rev-parse HEAD)"

if [[ "$BEFORE" == "$AFTER" ]]; then
  echo "✅ Allerede nyeste versjon."
else
  echo "⬆️  Oppdatert: ${BEFORE:0:7} → ${AFTER:0:7}"
fi

echo "▶ Kjører installeren på nytt (beholder skjerm-URL)…"
sudo bash "${REPO_DIR}/install_thin_pi.sh"

echo "▶ Starter kiosken på nytt…"
systemctl --user restart chromium-kiosk.service 2>/dev/null || true

echo "✅ Ferdig."
