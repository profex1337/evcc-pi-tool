# Play Store — Listing & Einreichung (Pi-Tool)

Alles hier ist vorbereitet. Was nur **du** machen kannst, ist unten unter „Checkliste" markiert.

## Assets (in diesem Ordner)
- App-Icon 512×512: `icon-512.png`
- Feature-Graphic 1024×500: `feature-graphic-1024x500.png`
- Screenshots: **fehlen** — bitte 2–8 Handy-Screenshots der laufenden App machen (Play will min. 2).

## Texte

**App-Name (max. 30):**
```
Pi-Tool
```

**Kurz- & Vollbeschreibung:** maßgeblich sind die fastlane-Metadaten — **von dort kopieren**, damit es nur eine Quelle gibt (kein doppelter, driftender Text):
- Deutsch: [`fastlane/metadata/android/de-DE/short_description.txt`](../../fastlane/metadata/android/de-DE/short_description.txt) + [`full_description.txt`](../../fastlane/metadata/android/de-DE/full_description.txt)
- Englisch: [`fastlane/metadata/android/en-US/`](../../fastlane/metadata/android/en-US/)

Diese beschreiben den Multi-Service-Stand (evcc + Pi-hole + ganzer Pi) inkl. Affiliation-Hinweis „nicht mit evcc oder Pi-hole verbunden".

**Was ist neu (Release Notes):** siehe jeweiliges GitHub-Release.

## Kategorie / Kontakt
- Kategorie: **Tools** (Productivity ginge auch)
- Tags: Raspberry Pi, SSH, evcc, Pi-hole
- Website: https://profex1337.github.io/evcc-pi-tool/
- Datenschutz-URL: **https://profex1337.github.io/evcc-pi-tool/privacy.html**
- Kontakt-E-Mail: **hello@kyth.systems**
- Impressum-URL: **https://profex1337.github.io/evcc-pi-tool/impressum.html**

## Data Safety (Formular-Antworten)
- Werden Daten erfasst/geteilt? **Nein** – nichts wird an uns oder Dritte übertragen.
- Lokale Speicherung von Zugangsdaten (Host/Port/User/Passwort): verschlüsselt auf dem Gerät, verlässt das Gerät nicht.
- Datenverschlüsselung bei Übertragung: **Ja** (SSH zum eigenen Server).
- Löschung: durch Deinstallation.
- (Falls das Formular „App-Funktionalität / Credentials" abfragt: lokal, nicht geteilt.)

## Content Rating
- IARC-Fragebogen ausfüllen: keine Gewalt/Sexualität/Glücksspiel etc. → Ergebnis voraussichtlich **USK 0 / PEGI 3**.

## Signing
- **Play App Signing** aktivieren. Unser Release-Keystore wird zum **Upload-Key**
  (Secrets `KEYSTORE_*` sind schon gesetzt; der CI-Build erzeugt das `.aab`).

## Artefakt
- Das `app-release.aab` kommt aus dem GitHub-Actions-Lauf (Artifact **evcc-pi-tool-playstore-aab**)
  des jeweiligen `v*`-Tags. Herunterladen → in der Play Console als Bundle hochladen.

## Checkliste (nur du)
- [ ] Google-Play-Developer-Account (einmalig 25 $)
- [ ] Neuer Privat-Account: **Closed Test mit 12+ Testern über 14 Tage** vor Produktiv-Release
- [ ] 2–8 Screenshots erstellen
- [ ] Kontakt-E-Mail in der Console setzen
- [ ] `.aab` aus dem CI-Artifact hochladen, Data-Safety + Content-Rating ausfüllen, Datenschutz-URL eintragen
- [ ] (Empfohlen) im Listing klar „inoffiziell, nicht mit evcc oder Pi-hole verbunden" erwähnen (steht schon in der Beschreibung)
```
