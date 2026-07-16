# OxiCloud Deployment-Tooling

Drei Scripts, um OxiCloud als vorkompiliertes Release-Paket zu bauen, auf
einem Server zu installieren und später zu aktualisieren — ohne dass der
Zielserver einen Rust- oder Node-Compiler braucht.

| Script | Version | Läuft wo? | Zweck |
|---|---|---|---|
| `build-package.sh` | 2.0 | Build-Maschine / CI | Baut Backend + Frontend, schnürt `.tar.gz` |
| `install.sh` | 1.4 | Zielserver | Erstinstallation (User, Verzeichnisse, systemd, PostgreSQL-Check, Config-Backups) |
| `update.sh` | 1.0 | Zielserver | Aktualisiert eine bestehende Installation, mit Rollback |

Lizenz: MIT

---

## Grundidee

Diese drei Scripts folgen der Philosophie **„einmal bauen, überall
verteilen"**: Ein Build-Rechner (Laptop, CI-Runner) kompiliert OxiCloud
einmal und verpackt Binary + Frontend-Assets in ein `.tar.gz`. Zielserver
brauchen dafür weder Rust noch Node.js — nur das fertige Paket.

Das steht im Gegensatz zu einem alternativen Ansatz, bei dem der Zielserver
den Quellcode selbst klont und kompiliert (z. B. per Cronjob mit `rustup`,
`cargo build --release` direkt auf der Maschine, die auch OxiCloud betreibt).
Beide Ansätze sind legitim — dieses Tooling deckt den **Prebuilt-Weg** ab.
Wer den Build-on-Target-Weg bevorzugt, braucht dieses Tooling nicht.

---

## Voraussetzungen

**Build-Maschine** (wo `build-package.sh` läuft):
- Rust-Toolchain (`cargo build --release`)
- Node.js + npm (für den Vite-Build des Svelte-Frontends)
- Ein Checkout des OxiCloud-Repos

**Zielserver** (wo `install.sh`/`update.sh` laufen):
- Debian/Ubuntu mit systemd
- root-Zugriff (bzw. `sudo`)
- Eine erreichbare PostgreSQL-Instanz — entweder bereits vorhanden (auch
  remote/managed) oder von `install.sh` optional lokal mitinstalliert
  (siehe Abschnitt „PostgreSQL" unten)
- **Kein** Rust, **kein** Node.js nötig

---

## Empfohlene Ordnerstruktur

```
~/oxicloud-tooling/            # eigenes Tooling-Verzeichnis/Repo
  ├── build-package.sh
  ├── install.sh
  └── update.sh

~/src/OxiCloud/                # normaler Git-Checkout des OxiCloud-Projekts
  ├── Cargo.toml
  ├── frontend/
  └── ...
```

Wichtig: `build-package.sh` liegt **nicht** im OxiCloud-Checkout selbst,
sondern daneben in einem eigenen Ordner. Der Quellcode-Pfad wird ihm als
Parameter übergeben (siehe unten). Das verhindert Namenskollisionen und
Merge-Konflikte, falls der Zielserver-Checkout von einem separaten
Git-Pull-Script verwaltet wird.

---

## 1. Paket bauen: `build-package.sh`

```bash
./build-package.sh <pfad-zum-oxicloud-checkout> [version] [output-dir]
```

**Beispiele:**

```bash
# Version wird automatisch per "git describe" im Checkout ermittelt
./build-package.sh ~/src/OxiCloud

# Feste Version, Standard-Ausgabeordner (./dist neben diesem Script)
./build-package.sh ~/src/OxiCloud v0.8.1

# Feste Version, eigener Ausgabeordner
./build-package.sh ~/src/OxiCloud v0.8.1 /srv/oxicloud-packages
```

**Was passiert:**
1. `cargo build --release` im Checkout
2. `npm ci && npm run build` im `frontend/`-Unterordner (Vite-Build)
3. Staging-Verzeichnis mit `bin/`, `static/`, `example.env`, optional
   `migrations/`, plus `install.sh`/`update.sh` aus dem Tooling-Ordner
4. `VERSION`-Datei wird geschrieben (liest `install.sh`/`update.sh` später aus)
5. Alles wird zu `oxicloud-<version>-linux-<arch>.tar.gz` gepackt, inkl.
   SHA256-Prüfsumme daneben

**Ergebnis:** `<output-dir>/oxicloud-<version>-linux-<arch>.tar.gz`

---

## PostgreSQL: Erreichbarkeits-Check und optionale lokale Installation

`install.sh` verhält sich hier zweistufig:

**Immer (ohne Flag):** Nach dem Anlegen/Prüfen der `.env` wird die dort
hinterlegte `OXICLOUD_DB_CONNECTION_STRING` ausgelesen und die
Erreichbarkeit geprüft — erst ein reiner TCP-Check (`/dev/tcp`, keine
Zusatzpakete nötig), zusätzlich ein echter Auth-Check per `psql`, falls
dieses auf dem Zielserver vorhanden ist. Das Ergebnis ist immer nur eine
**Warnung**, kein harter Abbruch — die Installation läuft in jedem Fall
durch, du siehst am Ende nur, ob die DB schon erreichbar ist.

**Optional (`--with-local-postgres`):** Installiert PostgreSQL zusätzlich
lokal auf demselben Server, legt Rolle + Datenbank an und trägt die
Connection-String automatisch in die `.env` ein — aber **nur**, wenn die
`.env` bei diesem Lauf frisch erzeugt wird (eine bereits bestehende `.env`
bleibt wie gehabt unangetastet, du bekommst dann nur die Zugangsdaten zum
manuellen Eintragen angezeigt).

```bash
# Variante A: PostgreSQL läuft schon (remote/managed) - einfach normal installieren,
# .env danach manuell mit der Connection-String befüllen
sudo ./install.sh

# Variante B: PostgreSQL soll gleich mit auf diesem Server eingerichtet werden
sudo ./install.sh --with-local-postgres
```

Das erzeugte Passwort für die lokale Rolle wird unter
`/etc/oxicloud/.db_password` gespeichert (`chmod 600`) und bei erneuten
Läufen wiederverwendet (stabil über mehrere Installationen hinweg).

**Randfall:** Enthält das Passwort in der Connection-String selbst ein
`@`-Zeichen, kann der eingebaute Parser Host/Port nicht zuverlässig
herauslösen — der Check wird dann sauber mit einer Warnung übersprungen,
statt das Script abbrechen zu lassen.

---

## Was bei erneuten Läufen garantiert nicht überschrieben wird

| Was | Schutzmechanismus |
|---|---|
| `.env`-Inhalt (Connection-String, Secrets, Base-URL) | Wird nur bei der allerersten Installation angelegt; jeder weitere Lauf lässt eine bestehende Datei komplett unangetastet |
| Lokales DB-Passwort (`--with-local-postgres`) | Persistiert separat in `/etc/oxicloud/.db_password` (`chmod 600`); bei Vorhandensein wiederverwendet statt neu generiert |
| Postgres-Rolle/Datenbank | Anlage erfolgt idempotent (`SELECT` vor jedem `CREATE`) — kein doppeltes Anlegen, keine Passwort-Überschreibung in Postgres selbst |
| systemd-Unit | Vor jedem Überschreiben wird eine Zeitstempel-Kopie unter `/etc/systemd/system/backups/oxicloud.service.<timestamp>.bak` angelegt |
| Bereits installiertes Release | `install.sh` bricht ab, wenn die Zielversion schon unter `releases/<version>/` existiert — für neue Versionen ist `update.sh` zuständig, das `.env`, DB-Passwort und Postgres gar nicht erst anfasst |

---

## 2. Erstinstallation: `install.sh`

Paket auf den Zielserver kopieren, entpacken, Installer starten:

```bash
scp dist/oxicloud-v0.8.1-linux-x86_64.tar.gz server:/tmp/
ssh server
mkdir -p /srv/oxicloud-packages && cd /srv/oxicloud-packages
tar -xzf /tmp/oxicloud-v0.8.1-linux-x86_64.tar.gz
cd oxicloud-v0.8.1-linux-x86_64
sudo ./install.sh
```

**Was passiert:**
- Legt Systemuser/-gruppe `oxicloud` an (kein Login)
- Installiert Binary + Static-Assets nach
  `/opt/oxicloud/releases/<version>/`
- Setzt den Symlink `/opt/oxicloud/current` darauf
- Legt `/etc/oxicloud/.env` aus `example.env` an (**überschreibt eine
  bestehende `.env` nie**)
- Legt das Datenverzeichnis `/var/lib/oxicloud/storage` an
- Setzt restriktive Dateirechte (Details siehe Tabelle unten)
- Installiert eine gehärtete systemd-Unit (`oxicloud.service`)
- Installiert `update.sh` fest als `/usr/local/sbin/oxicloud-update`

**Danach unbedingt:**
1. `/etc/oxicloud/.env` anpassen (DB-Connection, Base-URL, Secrets)
2. PostgreSQL-Erreichbarkeit sicherstellen
3. `sudo systemctl start oxicloud`
4. `sudo systemctl status oxicloud`

---

## 3. Updates: `update.sh` (bzw. `oxicloud-update`)

Nach der Erstinstallation liegt `update.sh` systemweit unter
`/usr/local/sbin/oxicloud-update` — du musst also nie wieder das alte
Paketverzeichnis wiederfinden:

```bash
# Neues Paket irgendwo entpacken
mkdir -p /tmp/oxicloud-new && cd /tmp/oxicloud-new
tar -xzf oxicloud-v0.8.2-linux-x86_64.tar.gz

# Update von überall anstoßen
sudo oxicloud-update /tmp/oxicloud-new/oxicloud-v0.8.2-linux-x86_64
```

**Was passiert:**
1. Neues Release nach `/opt/oxicloud/releases/v0.8.2/` kopieren
   (altes Release bleibt unangetastet liegen)
2. Dienst stoppen, `current`-Symlink auf das neue Release umschalten
3. Dienst starten
4. Health-Check gegen `http://127.0.0.1:<port>/health` (mehrere Versuche)
5. **Bei Erfolg:** fertig, alte Releases über `KEEP_RELEASES` (Standard: 5)
   automatisch aufräumen
6. **Bei Fehlschlag:** automatischer Rollback — Symlink zurück auf die
   vorherige Version, Dienst neu gestartet, Script bricht mit Fehler ab

**Manuelles Rollback**, falls doch mal nötig:

```bash
sudo ln -sfn /opt/oxicloud/releases/<alte-version> /opt/oxicloud/current
sudo systemctl restart oxicloud
```

Alle Update-Läufe werden zusätzlich in `/var/log/oxicloud-update.log`
protokolliert.

---

## Verzeichnis- und Rechte-Referenz

| Pfad | Inhalt | Owner:Gruppe | Rechte |
|---|---|---|---|
| `/opt/oxicloud/releases/<version>/` | Binary + Static-Assets je Release | `root:oxicloud` | `755` (Dirs) / `644` (Static-Dateien) / `750` (Binary) |
| `/opt/oxicloud/current` | Symlink auf aktives Release | `root:oxicloud` | — |
| `/etc/oxicloud/.env` | Konfiguration inkl. Secrets | `root:oxicloud` | `640` |
| `/var/lib/oxicloud/storage` | Uploads/Nutzdaten | `oxicloud:oxicloud` | `750` |
| `/etc/systemd/system/oxicloud.service` | systemd-Unit | `root:root` | `644` |
| `/etc/systemd/system/backups/` | Zeitstempel-Backups der systemd-Unit vor jedem Überschreiben | `root:root` | — |
| `/usr/local/sbin/oxicloud-update` | Update-Wrapper | `root:oxicloud` | `750` |
| `/var/log/oxicloud-update.log` | Update-Protokoll | — | — |

---

## Dienst verwalten

```bash
sudo systemctl start oxicloud
sudo systemctl stop oxicloud
sudo systemctl restart oxicloud
sudo systemctl status oxicloud
journalctl -u oxicloud -f
```

---

## Troubleshooting

**`update.sh`/Health-Check schlägt fehl, Rollback greift:**
- Prüfe `journalctl -u oxicloud -n 100` auf der neuen Version *vor* dem
  automatischen Rollback (Log-Zeitpunkt beachten)
- Prüfe, ob `HEALTH_PATH` (Standard `/health`) in `update.sh` zur
  tatsächlichen Version passt
- Prüfe, ob Datenbank-Migrationen für die neue Version nötig sind (siehe
  Hinweis im Script-Kopf von `update.sh`)

**`install.sh` bricht mit „Release X ist bereits installiert" ab:**
- Für ein bereits vorhandenes Release ist `install.sh` nicht der richtige
  Weg — dafür ist `update.sh`/`oxicloud-update` da.

**Zwei Deployment-Strategien parallel im Kopf behalten:**
- Dieses Tooling (Prebuilt-Paket) und ein eventuelles zweites Script, das
  OxiCloud direkt auf dem Zielserver aus dem Quellcode baut, schließen
  sich gegenseitig aus. Nicht beide auf derselben Maschine gegen dasselbe
  `/opt/oxicloud` laufen lassen.

---

## Versionsübersicht

| Datei | Version | Wichtigste Änderung |
|---|---|---|
| `build-package.sh` | 2.0 | Quellcode-Pfad als Parameter statt festem Repo-Root-Aufruf |
| `install.sh` | 1.4 | Backup der systemd-Unit vor jedem Überschreiben (Zeitstempel-Kopie) |
| `update.sh` | 1.0 | Erstversion mit Health-Check-Rollback |

Lizenz: **MIT**
