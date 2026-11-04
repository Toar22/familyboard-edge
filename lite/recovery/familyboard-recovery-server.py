#!/usr/bin/env python3
"""
FamilyBoard Edge Lite — Recovery-server (Blokk J7)

Vises i Chromium-kiosken hvis hovedsiden (familyboard.cloud) ikke svarer.
Gir brukeren synlig diagnose-info: IP, SSID, hjelpetekst.

Lytter på 127.0.0.1:5001. Startes ved boot via systemd-user-service.
"""

import http.server
import socketserver
import json
import subprocess
import os

PORT = 5001
SHARE_DIR = "/usr/local/share/familyboard"


def shell(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, timeout=3,
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return ""


def hotspot_ssid():
    """Samme navn som familyboard-hotspot-start.sh lager (siste 4 tegn av MAC)."""
    mac = shell("cat /sys/class/net/wlan0/address 2>/dev/null").replace(":", "")
    return "FamilyBoard-Setup-" + (mac[-4:].upper() if len(mac) >= 4 else "XXXX")


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/recovery-info":
            info = {
                "ip": shell("hostname -I | awk '{print $1}'") or "ingen IP",
                "ssid": shell("iwgetid -r") or "ikke koblet til WiFi",
                "mac": shell("cat /sys/class/net/wlan0/address 2>/dev/null") or "?",
                "host": shell("hostname") or "?",
                "hotspot_ssid": hotspot_ssid(),
                "hotspot_active": shell("systemctl is-active familyboard-hotspot.service") == "active",
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(json.dumps(info).encode())
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            # Default: serve recovery.html
            self.path = "/recovery.html"
            super().do_GET()

    def log_message(self, *_args):
        # Stille — vi spammer ikke systemd-journalen
        pass


if __name__ == "__main__":
    os.chdir(SHARE_DIR)
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as srv:
        srv.serve_forever()
