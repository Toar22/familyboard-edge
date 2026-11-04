# FamilyBoard Edge – Raspberry Pi som FamilyBoard-skjerm

Gjør en Raspberry Pi (eller en annen liten Linux-PC) med skjerm til en fast
FamilyBoard-skjerm. Den viser **visnings-URL-en** din i fullskjerm, starter av
seg selv, kommer seg selv etter strømbrudd og kan settes opp på nytt WiFi fra
mobilen. Alt innhold og alle innstillinger ligger på kontoen din på
[familyboard.cloud](https://familyboard.cloud) – skjermen lagrer ingen passord.

Ingen GitHub-konto trengs.

## Det du trenger

- Raspberry Pi 4/5 (eller annen maskin) med **Raspberry Pi OS (64-bit) med skrivebord**
  eller **Ubuntu Desktop**. Slå på **SSH** og legg inn **WiFi** i Raspberry Pi Imager.
- En **visnings-URL**: familyboard.cloud → **«👤 Min konto» → URLer → «Opprett»**.
  Den ser ut som `https://familyboard.cloud/d/…`.

## Installere

Logg inn på Pi-en (med tastatur eller `ssh bruker@pi-navn`) og kjør:

```bash
curl -fsSL https://raw.githubusercontent.com/Toar22/familyboard-edge/main/install.sh | sudo bash
```

Installeren spør etter visnings-URL-en din (lim inn hele lenken, eller bare koden
etter `/d/`), sjekker at den virker, og spør til slutt om Pi-en skal starte på nytt.
Etter omstart viser skjermen dashboardet i fullskjerm.

<details><summary>Uten spørsmål (f.eks. for flere Pi-er)</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/Toar22/familyboard-edge/main/install.sh \
  | sudo KIOSK_URL="https://familyboard.cloud/d/DIN-KODE" bash
sudo reboot
```
</details>

> Har skjermen en **eldre FamilyBoard Edge** fra før? Ta en sikkerhetskopi først,
> se [Bytte fra eldre Edge](#bytte-fra-eldre-edge).

## Oppdatere

```bash
bash ~/familyboard-edge/update_thin_pi.sh
```

## Bytte hvilken skjerm/visnings-URL Pi-en viser

```bash
sudo bash ~/familyboard-edge/install_thin_pi.sh
```

Svar **n** på «Bruke samme skjerm-lenke som før?» og lim inn den nye lenken.

Endringer i layout, design, kalender og bilder gjøres på familyboard.cloud og vises
på skjermen innen ca. 5 minutter – du trenger ikke røre Pi-en.

## Google-kalender (privat kalender)

En privat Google-kalender vises bare når skjermens nettleser er logget inn på Google.
Koble til tastatur og mus, og kjør i et terminalvindu på Pi-en:

```bash
systemctl --user stop chromium-kiosk.service
DISPLAY=:0 chromium-browser --user-data-dir=$HOME/snap/chromium/common/familyboard-kiosk-profile \
  --profile-directory=FamilyBoardKiosk https://accounts.google.com &
# logg inn, lukk vinduet, og så:
systemctl --user start chromium-kiosk.service
```

På Raspberry Pi OS (uten snap) er profilmappen `$HOME/.config/familyboard-kiosk-profile`,
og nettleseren heter ofte `chromium`.

## Flytte skjermen / nytt WiFi

1. Sett Pi-en i strøm og vent 1–2 minutter. Finner den ikke kjent WiFi, viser skjermen
   **«FamilyBoard Recovery»** med navnet på et oppsettsnett.
2. Koble mobilen til **FamilyBoard-Setup-XXXX** (passord **familyboard**).
3. Siden **«📺 FamilyBoard – WiFi»** åpnes (ellers gå til **http://192.168.4.1**).
4. Velg nettet ditt, skriv passordet og trykk **«Koble til»**.

Med nettverkskabel trengs ingen oppsett.

## Bytte fra eldre Edge

Installeren rydder bort eldre FamilyBoard Edge automatisk. Ta likevel sikkerhetskopi
først, så du kan gå tilbake:

```bash
git clone https://github.com/Toar22/familyboard-edge.git ~/familyboard-edge
cd ~/familyboard-edge
sudo bash migrering/backup_gammel_edge.sh        # lager /root/fb-edge-backup-…
sudo bash install_thin_pi.sh                      # spør etter visnings-URL og omstart
```

Tilbake til eldre Edge:

```bash
sudo bash ~/familyboard-edge/migrering/rollback_gammel_edge.sh && sudo reboot
```

## Avinstallere

```bash
sudo bash ~/familyboard-edge/cleanup_thin_pi.sh
```

## Feilsøking

| Problem | Tiltak |
|---|---|
| Svart skjerm / «Ingen signal» | Bruk HDMI-porten nærmest strømkontakten. |
| Dashboardet bruker bare halve skjermen | To skjermer/HDMI-kabler tilkoblet – bruk én. |
| «FamilyBoard Recovery» vises | Ingen nettforbindelse. Se *Flytte skjermen / nytt WiFi*. |
| Kalenderen er tom eller ber om innlogging | Se *Google-kalender*. |
| Status | `systemctl --user status chromium-kiosk.service` og `tail -20 /tmp/familyboard-kiosk.log` |

**Ikke** kjør `sudo apt autoremove` etter installasjonen – installeren fjerner noen
skrivebordsvarsler, og autoremove kan da fjerne mer enn ønsket.

Brukerhjelp for FamilyBoard: [familyboard-docs](https://github.com/Toar22/familyboard-docs).
