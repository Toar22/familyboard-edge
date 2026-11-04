#!/usr/bin/env python3
"""
FamilyBoard Edge Lite — Hotspot config server

Kjører på 192.168.4.1:80 mens Pi er i hotspot-modus.
Brukeren kobler telefonen til FamilyBoard-Setup-XXXX, åpner http://192.168.4.1,
velger nytt WiFi-nettverk og skriver passord. Selve tilkoblingen gjøres av
familyboard-wifi-connect.sh i en egen systemd-enhet (systemd-run), fordi denne
web-tjenesten stoppes sammen med hotspoten. Feiler tilkoblingen, starter
hotspoten igjen.
"""

import subprocess
import re
import os
import time
from flask import Flask, request, render_template_string

app = Flask(__name__)

INDEX_HTML = """<!DOCTYPE html>
<html lang="nb"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FamilyBoard – WiFi-oppsett</title>
<style>
body{font-family:-apple-system,system-ui,sans-serif;max-width:520px;margin:0 auto;
     padding:20px;background:#f5f5f5;color:#222}
h1{font-size:22px;margin:0 0 8px 0}
.lead{color:#666;margin-bottom:24px;font-size:14px}
form{background:#fff;padding:20px;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
label{display:block;margin:14px 0 6px 0;font-weight:600;font-size:14px}
select,input{width:100%;padding:12px;font-size:16px;border:1px solid #ccc;
             border-radius:8px;box-sizing:border-box}
button{margin-top:20px;width:100%;padding:14px;font-size:17px;font-weight:600;
       background:#0066cc;color:#fff;border:0;border-radius:8px}
button:active{background:#004c99}
.msg{padding:12px;border-radius:8px;margin-bottom:16px;font-size:14px}
.err{background:#fdd;color:#900}
.ok{background:#dfd;color:#060}
.foot{margin-top:24px;color:#888;font-size:12px;text-align:center}
</style></head><body>
<h1>📺 FamilyBoard – WiFi</h1>
<p class="lead">Velg det WiFi-nettverket Pi-en skal koble til.</p>
{% if msg %}<div class="msg {{ msg_class }}">{{ msg }}</div>{% endif %}
<form method="POST" action="/connect">
<label for="ssid">Nettverk</label>
<select name="ssid" id="ssid">
  {% for n in networks %}
    <option value="{{ n }}">{{ n }}</option>
  {% endfor %}
  <option value="">Annet nettverk (skriv navnet under)</option>
</select>
<label for="ssid_manual">…eller skriv nettverksnavnet</label>
<input type="text" name="ssid_manual" id="ssid_manual" autocapitalize="off"
       autocorrect="off" spellcheck="false" placeholder="Navn på WiFi (valgfritt)">
<label for="psk">Passord</label>
<input type="password" name="psk" id="psk" required minlength="8" placeholder="WiFi-passord">
<button type="submit">Koble til</button>
</form>
<div class="foot">FamilyBoard Edge Lite – setup-modus</div>
</body></html>"""

DONE_HTML = """<!DOCTYPE html>
<html lang="nb"><head>
<meta charset="utf-8"><title>Kobler til...</title>
<style>body{font-family:sans-serif;max-width:400px;margin:60px auto;text-align:center;
padding:20px}h1{color:#060}</style></head><body>
<h1>✅ Konfigurert!</h1>
<p>Pi-en kobler seg nå til <b>{{ ssid }}</b>.</p>
<p>Hotspoten slås av om noen sekunder, og telefonen mister forbindelsen.</p>
<p>Innen ca. 1 minutt skal FamilyBoard vises på skjermen.</p>
<p>Kommer <b>{{ hotspot }}</b> tilbake etter 1–3 minutter, var navnet eller
passordet feil. Koble til den igjen og prøv på nytt.</p>
</body></html>"""


SSID_LIST = "/run/familyboard-ssids.txt"
PENDING = "/run/familyboard-wifi-pending"
CONNECT_SCRIPT = "/usr/local/bin/familyboard-wifi-connect.sh"


def hotspot_name():
    try:
        with open("/etc/hostapd/familyboard.conf", encoding="utf-8") as f:
            for line in f:
                if line.startswith("ssid="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "FamilyBoard-Setup"


def scan_networks():
    """Nettverk funnet før hotspoten startet (+ best-effort skann nå)."""
    ssids = set()
    try:
        with open(SSID_LIST, encoding="utf-8", errors="replace") as f:
            ssids.update(line.strip() for line in f if line.strip())
    except OSError:
        pass
    try:
        result = subprocess.run(["iwlist", "wlan0", "scan"],
                                capture_output=True, text=True, timeout=8)
        for line in result.stdout.splitlines():
            m = re.search(r'ESSID:"([^"]+)"', line)
            if m:
                ssids.add(m.group(1))
    except Exception:
        pass
    ssids.discard(hotspot_name())
    return sorted(ssids, key=str.lower)


def start_connect(ssid, psk):
    """Lagre valget (0600) og start tilkoblingen i en egen systemd-enhet."""
    if "\n" in ssid or "\n" in psk:
        raise ValueError("Ugyldige tegn")
    try:
        os.unlink(PENDING)
    except FileNotFoundError:
        pass
    fd = os.open(PENDING, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(ssid + "\n" + psk + "\n")
    subprocess.run(["systemctl", "reset-failed", "familyboard-wifi-connect"],
                   capture_output=True, timeout=5, check=False)
    proc = subprocess.run(
        ["systemd-run", "--unit=familyboard-wifi-connect", "--no-block",
         "--collect", CONNECT_SCRIPT],
        capture_output=True, text=True, timeout=10,
    )
    if proc.returncode != 0:
        raise RuntimeError("Kunne ikke starte tilkobling: " + (proc.stderr or "").strip()[:200])


@app.route("/")
def index():
    networks = scan_networks()
    return render_template_string(INDEX_HTML, networks=networks,
                                  msg=None, msg_class="")


@app.route("/connect", methods=["POST"])
def connect():
    ssid = (request.form.get("ssid_manual", "").strip()
            or request.form.get("ssid", "").strip())
    psk = request.form.get("psk", "")
    if not ssid or not (8 <= len(psk) <= 63):
        return render_template_string(
            INDEX_HTML, networks=scan_networks(),
            msg="Velg eller skriv nettverk, og skriv passord (8–63 tegn).", msg_class="err"
        )
    try:
        start_connect(ssid, psk)
    except Exception as e:
        return render_template_string(
            INDEX_HTML, networks=scan_networks(),
            msg=f"Feil: {e}", msg_class="err"
        )
    return render_template_string(DONE_HTML, ssid=ssid, hotspot=hotspot_name())


# Captive-portal-emulering: ALLE requests vil treffe oss (DNS-redirect i dnsmasq)
@app.route("/<path:_path>", methods=["GET", "POST"])
def catch_all(_path):
    return index()


if __name__ == "__main__":
    # Lytt på 192.168.4.1:80 — krever root for port 80
    app.run(host="192.168.4.1", port=80, debug=False)
