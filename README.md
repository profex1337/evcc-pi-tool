# evcc companion

Schlanke **Android-App** (clean minimal dark), die [evcc](https://evcc.io) auf
einem Raspberry Pi **per Knopfdruck via SSH aktualisiert** — und es bei Bedarf
auch **installieren** kann. IP + Pi-Zugang eintragen, tippen, fertig. Für mich +
Freunde, Verteilung als **APK über GitHub Releases**.

> ⚠️ Hinweis: Die App führt mit deinem eingegebenen Passwort `sudo apt-get`
> auf dem Pi aus. Nutze sie nur für Geräte, die dir gehören.

## Was die App macht

Beim Tippen auf **„evcc aktualisieren"** läuft genau die validierte SSH-Sequenz:

1. Version vorher: `dpkg-query -W -f='${Version}' evcc`
2. `sudo -S apt-get update -qq`
3. `sudo -S apt-get install --only-upgrade -y evcc`
   (bei aktiviertem Schalter **„Komplettes System-Upgrade"** stattdessen
   `sudo -S apt-get full-upgrade -y`)
4. `systemctl is-active evcc` → erwartet `active`
5. Version nachher → Diff wird gemeldet („evcc 0.310.0 → 0.311.0 aktualisiert"
   bzw. „war schon aktuell").

Der Dienst startet beim apt-Upgrade automatisch neu. Mit **„Probelauf (ändert
nichts)"** läuft dieselbe Sequenz mit `--dry-run` — nichts wird verändert,
ideal zum gefahrlosen Testen, ob ein Update verfügbar ist.

Mit **„Verbindung testen"** prüfst du in Sekunden, ob Host/Port/Benutzer/Passwort
stimmen: die App verbindet, liest die evcc-Version und den Dienststatus — **ohne
`sudo`/`apt`**, also ohne irgendetwas anzufassen.

### evcc installieren (experimentell)

Über das **⋮-Menü → „evcc installieren"** richtet die App evcc auf einem frisch
konfigurierten Pi ein (nach [offizieller evcc-Doku](https://docs.evcc.io/en/installation/linux)):
offizielles apt-Repo via `setup.deb.sh` hinzufügen → `apt install -y evcc` →
`systemctl enable --now evcc`. Alles läuft als root über **einen** `sudo -S bash -s`
-Aufruf (Passwort als erste stdin-Zeile, **nie** in der Befehlszeile). Danach
zeigt die App **„Einrichtung öffnen"** → `http://<pi>:7070`.

> Experimentell: nach offizieller Doku gebaut, aber noch nicht End-to-End gegen
> einen frischen Pi validiert (anders als die Update-Mechanik). Erst auf einem
> Test-Pi ausprobieren.

## Installation (Sideload)

1. Auf der [Releases-Seite](../../releases) die neueste **`app-release.apk`**
   herunterladen (Handy-Browser genügt, kein GitHub-Account nötig).
2. Beim Öffnen fragt Android nach **„Unbekannte Quellen / Apps aus dieser
   Quelle zulassen"** → erlauben.
3. APK installieren, App öffnen.

## Nutzung

| Feld | Bedeutung | Default |
|------|-----------|---------|
| **Host / IP** | IP des Pi (z. B. `192.168.178.64`) oder Tailscale-IP | – |
| **Benutzer** | SSH-Benutzer | `pi` |
| **Port** | SSH-Port | `22` |
| **Passwort** | Pi-Passwort (für SSH + `sudo`) | – |
| **Komplettes System-Upgrade** | Aus = nur evcc; Ein = alle apt-Pakete | Aus |

Eingaben werden **verschlüsselt im Android Keystore** gespeichert
(`flutter_secure_storage`) — einmal eintragen, danach nur noch tippen.

## Sicherheit

- Das Passwort liegt **nur verschlüsselt** im Keystore, niemals im Klartext.
- Es wird der `sudo`-Abfrage **über stdin** übergeben (`sudo -S`), **nie** als
  Teil der Befehlszeile — und aus der sichtbaren Log-Ausgabe **herausgefiltert**.
- Kein Account, kein Cloud-Backend. Annahme: LAN-Nutzung (zuhause im WLAN).
  Remote optional über **Tailscale-IP** (kein Portforwarding nötig).
- `sudo -S` funktioniert auch ohne passwortloses sudo.

## Build & Releases (CI)

Der APK-Build läuft komplett in **GitHub Actions** — lokal ist **keine
Android-Toolchain** nötig.

- Workflow: [`.github/workflows/build.yml`](.github/workflows/build.yml)
- Trigger: Push auf `main` (baut + testet) und Tag `v*` (baut + signiert +
  legt ein **Release mit `app-release.apk`** an).
- Schritte: `flutter pub get` → `flutter analyze` → `flutter test` →
  `flutter build apk --release`, signiert mit einem Release-Keystore aus den
  Repo-Secrets.

### Ein neues Release veröffentlichen

```bash
# Version in pubspec.yaml anheben (z. B. 0.1.1+2), committen, dann:
git tag v0.1.1
git push origin v0.1.1
```

CI baut die signierte APK und hängt sie ans GitHub-Release.

### Benötigte Repo-Secrets (Signierung)

| Secret | Inhalt |
|--------|--------|
| `KEYSTORE_BASE64` | Release-Keystore (`.jks`), base64-kodiert |
| `KEYSTORE_PASSWORD` | Keystore-Passwort |
| `KEY_ALIAS` | Key-Alias (`evcc`) |
| `KEY_PASSWORD` | Key-Passwort |

> Der Keystore wird **nie** ins Repo committet (`.gitignore`). Bewahre die
> `.jks`-Datei + Passwort sicher auf — sie wird für künftige signierte Updates
> gebraucht.

## Entwicklung

```bash
flutter pub get
flutter analyze
flutter test
```

Die Architektur trennt **testbare reine Logik** (Kommando-Bau, Output-Parsing,
Ergebnis-Zusammenfassung in `lib/src/commands.dart` + `lib/src/parsing.dart`)
von der **SSH-/Update-Orchestrierung** (`lib/src/evcc_updater.dart`, hinter dem
`SshRunner`-Interface für Unit-Tests ohne echtes SSH) und der **UI**
(`lib/main.dart`). Die SSH-Mechanik selbst steckt im dünnen Adapter
`lib/src/dartssh2_runner.dart`.

## Roadmap

- iOS: bewusst später. Die Flutter-Codebasis hält die Tür offen.
