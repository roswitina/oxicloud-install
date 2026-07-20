# install-oxicloud.sh — Anleitung

Native (Nicht-Container-)Installation von OxiCloud, die den Quellcode
**direkt auf dem Zielserver** klont, kompiliert und als systemd-Dienst
betreibt — im Gegensatz zum separaten Prebuilt-Tooling
(`build-package.sh`/`install.sh`/`update.sh`), das auf einer separaten
Build-Maschine kompiliert und ein fertiges `.tar.gz` verteilt.

Version: 1.14
Lizenz: MIT

---

## Versionshistorie

| Version | Änderung |
|---|---|
| 1.9 | Ursprüngliche Fassung |
| 1.10 | `REPO_URL` konsistent auf `AtalayaLabs/OxiCloud` (inkl. GitHub-API-Aufruf in `resolve_target_ref()`); systemd-Hardening ergänzt (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths`); Kommentar zur `Requires=` vs. `Wants=`-Entscheidung bei `postgresql.service` |
| 1.11 | Drei Fixes nach Review, siehe Abschnitt „Fixes in 1.11" unten: (1) `set -e`-Fallstrick bei der Node.js-LTS-Ermittlung, (2) DB-Passwort wird jetzt bei jedem Lauf durchgesetzt statt nur beim Erstanlegen, (3) DB-Passwort steht nicht mehr im world-readable systemd-Unit-File |
| 1.12 | Fix nach fehlgeschlagenem Testlauf in einem LXC-Container, siehe Abschnitt „Fix in 1.12" unten: `sudo` fehlte in der Preflight-Paketliste und war auf einem minimalen LXC-Template nicht vorinstalliert — Script brach beim ersten `sudo -u ...`-Aufruf mit `command not found` ab |
| 1.13 | Sieben Robustheits-Verbesserungen, siehe Abschnitt „Neuerungen in 1.13" unten: automatisches Health-Check-Rollback, DB-Backup vor jeder Migration, Log-Rotation fürs Install-Log, `git fetch`+`reset --hard` statt `pull`, harter Abbruch bei kritisch wenig Diskspace, Firewall-Hinweis bei `0.0.0.0`/`::`, optionale Fehler-Benachrichtigung per Webhook |
| 1.14 | Aufbewahrungsgrenze für die generischen Zeitstempel-Backups (`.env`, systemd-Unit, `/etc/fstab`), siehe Abschnitt „Neuerung in 1.14" unten: `backup_file()` bereinigte bisher nie, wuchs also unbegrenzt — besonders relevant, da `.env` pro Lauf potenziell zweimal gesichert wird |

---

## Grundidee

Ein einziges Script übernimmt Erstinstallation **und** spätere Updates:
einfach erneut ausführen. Es ist vollständig idempotent — ein zweiter Lauf
erkennt selbst, ob sich seit dem letzten Mal etwas geändert hat (neuer
Commit, neue Rust-Toolchain, geänderte Build-Features), und baut nur dann
neu.

**Wichtig:** Dieses Script und das separate Prebuilt-Tooling
(`build-package.sh`/`install.sh`/`update.sh`) schließen sich gegenseitig
aus. Nicht beide gegen dasselbe `/opt/oxicloud` laufen lassen — entweder
der Server baut sich selbst (dieses Script), oder er bekommt ein fertiges
Paket von außen (Prebuilt-Tooling), nicht beides gemischt.

---

## Neuerung in 1.14

### Aufbewahrungsgrenze für generische Datei-Backups

`backup_file()` — genutzt für `/etc/oxicloud/.env`, `/etc/systemd/system/oxicloud.service`
und `/etc/fstab` (beim Swapfile-Handling) — legte bei jedem Aufruf eine
weitere Zeitstempel-Kopie unter `<verzeichnis>/backups/` an, bereinigte
aber nie etwas. Im Unterschied zu `DB_BACKUP_KEEP` (Abschnitt 1.13) und
`KEEP_RELEASES` wuchs dieses Verzeichnis damit unbegrenzt — besonders
relevant bei `.env`, die pro Lauf potenziell **zweimal** gesichert wird
(einmal beim Ergänzen neuer Variablen aus `example.env`, einmal direkt
danach vor dem Setzen von `DATABASE_URL` etc.).

Jetzt bereinigt `backup_file()` nach jedem Aufruf automatisch auf die
neuesten `GENERIC_BACKUP_KEEP` Stände **pro Datei** (Standard `10`).
Zusätzlich gibt es jetzt einen Kollisionsschutz: Fallen zwei Backups
derselben Datei in dieselbe Sekunde (Zeitstempel hat nur
Sekundenauflösung — genau der Fall bei den zwei `.env`-Backups pro Lauf),
wird die PID an den Dateinamen angehängt (`.env.<timestamp>-<pid>.bak`),
statt dass der zweite Aufruf den ersten Backup-Stand stillschweigend
überschreibt.

### Alle Schwellwerte jetzt zentral im Konfigurationsblock

Zusätzlich wurden `DISK_ABORT_THRESHOLD_GB`, `DB_BACKUP_KEEP` und
`HEALTH_RETRIES` (alle drei aus 1.13) sowie das neue `GENERIC_BACKUP_KEEP`
aus ihren bisherigen Positionen direkt über der jeweiligen Codestelle in
den zentralen Konfigurationsblock am Scriptanfang verschoben. Der Grund:
Es gibt keinen guten inhaltlichen Grund, warum diese vier anders behandelt
werden sollten als z. B. `KEEP_RELEASES`, das von Anfang an dort stand —
alle anpassbaren Werte sollten an einer Stelle einsehbar sein, statt
teils verstreut im Code zu stehen.

---

## Neuerungen in 1.13

Sieben Verbesserungen nach einem Review des bisherigen Stands — alle
zielen darauf ab, Fehler früher abzufangen bzw. automatisch zu behandeln,
statt sie erst später kryptisch auffallen zu lassen.

### 1. Automatisches Health-Check-Rollback

Bisher (siehe „Versionierte Releases & manuelles Rollback" weiter unten in
der alten Fassung) war Rollback ein rein manueller Schritt — obwohl das
Script mit den nach Git-Commit-Hash versionierten Binaries unter
`releases/` und dem `current`-Symlink die Infrastruktur dafür längst hatte.

Jetzt gilt: Nach einem Rebuild + Neustart prüft das Script bis zu 10x im
Abstand von 2 Sekunden, ob der Dienst aktiv ist **und** auf
`http://127.0.0.1:${OXICLOUD_PORT}/` antwortet. Schlägt das fehl:

```
FEHLER: Dienst antwortet nach 10 Versuchen (je 2s) nicht auf Port 8086.
    Prüfe: journalctl -u oxicloud -n 50 --no-pager
    Rolle automatisch zurück auf vorheriges Release: /opt/oxicloud/releases/oxicloud-<alter-hash>
    Rollback erfolgreich, Dienst läuft wieder mit /opt/oxicloud/releases/oxicloud-<alter-hash>.
```

`current` wird automatisch auf das vorherige Release zurückgesetzt, der
Dienst erneut gestartet, und das Script beendet sich danach trotzdem mit
Exit-Code 1 (damit ein automatisierter/Cron-Lauf den Fehlschlag als
solchen erkennt — siehe Punkt 7). Gibt es kein vorheriges Release (erster
Lauf überhaupt) oder scheitert auch der Rollback-Neustart, wird das
deutlich ausgegeben — dann ist manueller Eingriff nötig.

### 2. Automatisches DB-Backup vor jeder Migration

`cargo sqlx migrate run` lief bisher bei jedem Lauf ohne vorheriges
Backup. Jetzt läuft direkt davor:

```bash
sudo -u postgres pg_dump "${DB_NAME}" | gzip > /etc/oxicloud/db-backups/oxicloud-<timestamp>.sql.gz
```

mit `chmod 600` und automatischer Bereinigung auf die letzten 10 Stände
(`DB_BACKUP_KEEP`, hartkodiert direkt über der entsprechenden Codestelle,
nicht im Konfigurationsblock am Scriptanfang). Schlägt das Backup selbst
fehl, bricht das Script **vor** der Migration ab, statt eine potenziell
riskante Migration ohne Sicherheitsnetz laufen zu lassen.

### 3. Log-Rotation für das Install-Log

`/var/log/oxicloud-install.log` wuchs bisher unbegrenzt (`tee -a` bei
jedem Lauf). Sofern `logrotate` auf dem System vorhanden ist, legt das
Script jetzt bei jedem Lauf idempotent `/etc/logrotate.d/oxicloud-install`
an (wöchentliche Rotation, 8 Generationen, komprimiert,
`copytruncate` — wichtig, da das Log während des Laufs offen gehalten
wird).

### 4. `git fetch` + `reset --hard origin/main` statt `git pull`

Passend zur bereits bestehenden Philosophie, dass `/opt/oxicloud`
ausschließlich vom Script verwaltet wird (siehe Patch-Backup lokaler
Änderungen weiter unten): `git pull origin main` konnte an einem
divergierten main scheitern, z. B. nach einem Force-Push upstream im
Repository. `git fetch origin main` + `git reset --hard origin/main`
erzwingt stattdessen immer exakt den Stand von `origin/main`, unabhängig
von der lokalen Historie. Betrifft nur den Fall, dass kein
`OXICLOUD_VERSION_PIN` gesetzt ist (also dem `main`-Branch gefolgt wird) —
bei einem festen Tag/Release lief es schon vorher über `git checkout`.

### 5. Harter Abbruch bei kritisch wenig Diskspace

Bisher gab es nur eine Warnung, falls weniger als die empfohlenen ~20 GB
frei waren; der Build lief trotzdem an und scheiterte im ungünstigsten
Fall erst mitten in `cargo build --release`. Jetzt bricht das Script
**vor** dem Build hart ab, wenn weniger als `DISK_ABORT_THRESHOLD_GB=5`
GB frei sind (Wert hartkodiert direkt über der entsprechenden Codestelle
im Ressourcen-Abschnitt, nicht im Konfigurationsblock), mit Hinweisen, wo
sich am ehesten Platz freiräumen lässt (alte Releases, alte DB-Backups,
`apt-get clean`).

### 6. Firewall-Hinweis bei `0.0.0.0`/`::`

Wird `ENV_OVERRIDE_SERVER_HOST` auf `0.0.0.0` oder `::` gesetzt (Dienst
lauscht auf allen Interfaces), prüft das Script — falls `ufw` vorhanden
ist — ob der Port dort freigegeben ist, und gibt andernfalls einen
deutlichen Hinweis aus, das selbst zu prüfen (Portweiterleitung,
Cloud-Security-Group, `ufw allow ${OXICLOUD_PORT}/tcp` falls gewünscht).
Ist `ufw` nicht vorhanden, erfolgt ein allgemeinerer Hinweis, das über
`nftables`/`iptables`/Cloud-Firewall manuell zu prüfen.

### 7. Optionale Fehler-Benachrichtigung per Webhook

Neue Konfigurationsvariable `NOTIFY_WEBHOOK_URL` (leer = deaktiviert,
Standard). Ein `trap` auf `EXIT` sorgt dafür, dass bei **jedem**
Fehlschlag des Scripts (Exit-Code ≠ 0, unabhängig an welcher Stelle) eine
kurze POST-Anfrage mit `{"text": "..."}` an die konfigurierte URL
geschickt wird (kompatibel zu Slack-/Mattermost-Incoming-Webhooks).
Relevant vor allem, falls das Script unbeaufsichtigt per Cron läuft — ohne
das fällt ein fehlgeschlagener Auto-Update-Lauf sonst erst auf, wenn der
Dienst schon länger down ist. Die Benachrichtigung selbst ist bewusst
fehlertolerant (`|| true`, 10s Timeout) und verändert nie den eigentlichen
Exit-Code des Scripts.

---

## Fix in 1.12

Entstanden aus einem echten fehlgeschlagenen Testlauf: Installation in
einem **LXC-Container** (Proxmox, Debian Trixie) brach mitten in der
PostgreSQL-Rolle-Anlage ab, während dieselbe Script-Version auf einer
vollwertigen VM (DietPi, x86) anstandslos durchlief.

### `sudo` fehlte in der Preflight-Paketliste

Ursache im Install-Log:
```
==> Lege PostgreSQL-Rolle und Datenbank an (falls noch nicht vorhanden)...
./install-oxicloud.sh: line 306: sudo: command not found
```

Viele minimale LXC-Templates (insbesondere die offiziellen
Proxmox-Debian-Templates) bringen `sudo` **nicht** vorinstalliert mit — im
Gegensatz zu vollwertigen VMs oder Images wie DietPi, wo es praktisch immer
vorhanden ist. Root zu sein (der `EUID`-Check am Scriptanfang) garantiert
nicht, dass der Befehl `sudo` selbst existiert. Das Script verlässt sich
aber an sehr vielen Stellen auf `sudo -u ...` — DB-Rolle anlegen,
Repo klonen, Rust/Cargo-Aufrufe, `npm run build`, uvm. — daher scheiterte
der Lauf beim allerersten `sudo`-Aufruf.

Vorher:
```bash
REQUIRED_APT_PACKAGES=(git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
```

Jetzt:
```bash
REQUIRED_APT_PACKAGES=(sudo git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
```

Der bestehende Preflight-Mechanismus (fehlende Pakete automatisch per
`apt-get install` nachziehen) deckt `sudo` damit von Anfang an mit ab,
noch bevor der erste `sudo -u ...`-Aufruf im Script erreicht wird.

**Falls du bereits einen fehlgeschlagenen Lauf mit einer älteren Version
in einem solchen Container hattest:** einfach `apt-get install -y sudo`
manuell nachholen oder das Script erneut mit Version 1.12 (oder neuer)
ausführen — Idempotenz sorgt dafür, dass der Rest des vorherigen
(Teil-)Laufs sauber fortgesetzt wird.

---

## Fixes in 1.11

Entstanden aus einem Code-Review, nicht aus einem konkreten Vorfall bei
diesem Script — aber alle drei Muster waren real bei anderen Skripten des
Projekts aufgetreten (siehe `migrate-nextcloud-direct.sh`-Changelog).

### 1. `set -e`-Fallstrick bei der Node.js-LTS-Ermittlung

```bash
LATEST_LTS_MAJOR="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '...' | sed '...' | cut -d. -f1)"
```

Das war eine plain Command-Substitution mit Pipe unter `set -e -o pipefail`
**ohne** Absicherung. Schlug `curl` fehl (nodejs.org nicht erreichbar,
Netzwerk-Hänger), beendete sich das **ganze Script sofort und
stillschweigend** an dieser Zeile — der direkt darunterstehende Fallback
(`LATEST_LTS_MAJOR=24`) wurde **nie erreicht**. Jetzt mit `|| true`
abgesichert:

```bash
LATEST_LTS_MAJOR="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | jq -r '...' 2>/dev/null | sed '...' | cut -d. -f1)" || true
```

`LATEST_LTS_MAJOR` bleibt bei einem Fehlschlag einfach leer, der
nachfolgende `if [[ -z "${LATEST_LTS_MAJOR}" ]]`-Fallback greift dann wie
ursprünglich vorgesehen.

### 2. DB-Passwort wurde nur beim Erstanlegen der Rolle gesetzt

Vorher:
```bash
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';"
```
Existierte die Rolle bereits — z. B. nach einem abgebrochenen vorherigen
Lauf oder einer aus einem Backup wiederhergestellten Datenbank — mit einem
**anderen** Passwort als in `/etc/oxicloud/.db_password` gespeichert, blieb
das unbemerkt, bis `sqlx migrate run` oder der Dienst selbst mit einem
kryptischen Auth-Fehler scheiterte.

Jetzt läuft bei **jedem** Lauf zusätzlich:
```bash
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';"
```
(idempotent, harmlos falls das Passwort ohnehin schon übereinstimmt), plus
direkt danach ein echter Verbindungstest:
```bash
PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;"
```
Schlägt der Test fehl, bricht das Script mit einer konkreten Fehlermeldung
ab (inkl. Hinweis auf `pg_hba.conf`), statt erst später kryptisch zu
scheitern.

### 3. DB-Passwort stand im Klartext im systemd-Unit-File

Vorher enthielt die generierte `oxicloud.service` diese Zeile:
```ini
Environment=DATABASE_URL=postgres://oxicloud:<klartext-passwort>@localhost:5432/oxicloud
```
Unit-Files unter `/etc/systemd/system/` sind standardmäßig `644` — **für
alle lokalen User lesbar**. Das stand damit im Widerspruch zur sonst
vorbildlich restriktiven Rechtevergabe des Scripts (`.env` mit `640`,
`.db_password` mit `600`).

Jetzt wird `DATABASE_URL` stattdessen zusätzlich in die (weiterhin `640`,
`root:oxicloud`) `.env` geschrieben:
```bash
set_env_var "DATABASE_URL" "${DATABASE_URL}" "${CONFIG_DIR}/.env"
```
und die Unit lädt sie ausschließlich über `EnvironmentFile=/etc/oxicloud/.env`
— die `Environment=DATABASE_URL=...`-Zeile im Unit-File ist komplett
entfernt.

**Falls du eine ältere Installation (vor 1.11) hast**: Nach dem Update mit
diesem Script einmal prüfen, ob das alte Unit-File noch die Klartext-Zeile
enthält, und ggf. manuell bereinigen:
```bash
grep -n "DATABASE_URL" /etc/systemd/system/oxicloud.service
```
Ein erneuter Lauf von `install-oxicloud.sh` schreibt die Unit ohnehin neu
(mit vorherigem Backup unter `/etc/systemd/system/backups/`).

---

## Voraussetzungen

- Debian/Ubuntu mit systemd
- root-Zugriff (bzw. `sudo` — wird seit 1.12 falls nötig selbst
  nachinstalliert, siehe „Fix in 1.12" oben; **auf minimalen LXC-Templates
  vorher trotzdem sinnvoll, einmal manuell zu prüfen, ob es schon da ist**)
- Internetzugang auf dem Zielserver (für `apt`, GitHub, crates.io, npm-Registry, rustup, NodeSource, optional den Webhook-Endpunkt aus `NOTIFY_WEBHOOK_URL`)
- Ausreichend Ressourcen zum Kompilieren — siehe Abschnitt „Ressourcenbedarf" unten. Fehlt genug RAM, legt das Script selbst einen temporären Swapfile an. Seit 1.13 bricht das Script bei kritisch wenig Diskspace vor dem Build hart ab, statt nur zu warnen (siehe „Neuerungen in 1.13", Punkt 5).
- `logrotate` (optional): falls vorhanden, richtet das Script seit 1.13 automatisch eine Rotation für `/var/log/oxicloud-install.log` ein
- `curl` erreichbar auf `127.0.0.1:${OXICLOUD_PORT}` (für den seit 1.13 vorhandenen Health-Check nach jedem Rebuild)

Wird **auf dem Zielserver selbst** installiert:
- Rust (via `rustup`, Benutzer-lokal)
- Node.js (via NodeSource, systemweit)
- PostgreSQL (via `apt`)
- `sqlx-cli` (für Datenbank-Migrationen)

---

## Aufruf

```bash
sudo bash install-oxicloud.sh
```

Kein Parameter nötig — alle Einstellungen erfolgen über den
Konfigurationsblock am Scriptanfang (siehe unten) oder durch erneutes
Ausführen mit geänderten Werten dort.

---

## Konfigurationsblock (Kopf des Scripts)

| Variable | Standard | Bedeutung |
|---|---|---|
| `OXICLOUD_USER` | `oxicloud` | Systemuser, unter dem geklont/gebaut/betrieben wird |
| `OXICLOUD_HOME` | `/opt/oxicloud` | Git-Working-Copy **und** Installationsort — wird ausschließlich vom Script verwaltet |
| `OXICLOUD_PORT` | `8086` | Anzeige-URL am Ende **und** seit 1.13 Ziel des automatischen Health-Checks nach jedem Rebuild |
| `DB_NAME` / `DB_USER` | `oxicloud` | Name von Datenbank und Postgres-Rolle |
| `REPO_URL` | `https://github.com/AtalayaLabs/OxiCloud.git` | Woher geklont wird — siehe Hinweis im Script zur Doppel-Existenz von `DioCrafts/OxiCloud` und `AtalayaLabs/OxiCloud` |
| `KEEP_RELEASES` | `5` | Wie viele alte versionierte Binaries behalten werden; `0` = nichts löschen |
| `NODE_VERSION_PIN` | leer | Leer = immer neueste LTS-Major-Version; sonst z. B. `"22"` |
| `RUST_VERSION_PIN` | leer | Leer = immer `rustup update stable`; sonst z. B. `"1.82.0"` |
| `ENV_OVERRIDE_SERVER_HOST` | leer | Überschreibt `OXICLOUD_SERVER_HOST` in der `.env`, z. B. `"0.0.0.0"` — seit 1.13 mit Firewall-Hinweis bei `0.0.0.0`/`::` |
| `ENV_OVERRIDE_BASE_URL` | leer | Überschreibt `OXICLOUD_BASE_URL` in der `.env`, z. B. `"https://cloud.example.com"` |
| `OXICLOUD_VERSION_PIN` | leer | Leer = folgt `main`-Branch; `"latest"` = neuestes GitHub-Release; `"vX.Y.Z"` = fester Tag |
| `ENABLE_PLUGINS` | `false` | `true` baut mit Cargo-Feature `plugins` (WASM-Runtime via Extism) und setzt `OXICLOUD_ENABLE_PLUGINS=true` |
| `NOTIFY_WEBHOOK_URL` *(neu in 1.13)* | leer | Leer = keine Benachrichtigung; sonst Slack-/Mattermost-kompatible Webhook-URL, die bei jedem fehlgeschlagenen Lauf (Exit-Code ≠ 0) einen POST mit `{"text": "..."}` erhält |
| `GENERIC_BACKUP_KEEP` *(neu in 1.14)* | `10` | Wie viele Zeitstempel-Backups **pro Datei** in den jeweiligen `backups/`-Unterordnern behalten werden (`.env`, systemd-Unit, `/etc/fstab`); `0` = keine Bereinigung |
| `DB_BACKUP_KEEP` *(neu in 1.13, seit 1.14 zentral)* | `10` | Wie viele DB-Backups unter `/etc/oxicloud/db-backups` behalten werden; `0` = keine Bereinigung |
| `DISK_ABORT_THRESHOLD_GB` *(neu in 1.13, seit 1.14 zentral)* | `5` | Unterhalb dieser freien GB im Ressourcen-Check bricht das Script vor dem Build hart ab |
| `HEALTH_RETRIES` *(neu in 1.13, seit 1.14 zentral)* | `10` | Wie oft (im 2-Sekunden-Abstand) der Health-Check nach einem Rebuild versucht wird, bevor ein Rollback ausgelöst wird |

Alle `ENV_OVERRIDE_*`-Variablen greifen nur, wenn nicht leer — leer lassen
heißt: Standardwert aus `example.env` bleibt unangetastet.

Seit 1.14 stehen **alle** anpassbaren Werte gesammelt im
Konfigurationsblock am Scriptanfang — in 1.13 waren `DISK_ABORT_THRESHOLD_GB`,
`DB_BACKUP_KEEP` und `HEALTH_RETRIES` noch direkt über ihrer jeweiligen
Codestelle verstreut. Das war unnötig inkonsistent, da sie sich vom
Charakter her nicht von z. B. `KEEP_RELEASES` unterscheiden (siehe
Abschnitt „Neuerung in 1.14" unten).

---

## Ablauf im Detail

1. **Preflight-Check**: `sudo`, `git`, `curl`, `jq`, `openssl`,
   `postgresql`, `postgresql-contrib`, `build-essential`, `pkg-config`,
   `libssl-dev`, `ca-certificates` werden geprüft und fehlende per `apt`
   nachinstalliert. Seit 1.12 gehört `sudo` mit zur Liste (siehe „Fix in
   1.12" oben) — vorher fehlte es hier, obwohl das Script ab Schritt 3 an
   vielen Stellen darauf angewiesen ist. Seit 1.13 wird außerdem, falls
   `logrotate` vorhanden ist, automatisch eine Rotation für
   `/var/log/oxicloud-install.log` eingerichtet, und bei kritisch wenig
   freiem Diskspace (< `DISK_ABORT_THRESHOLD_GB`) bricht das Script an
   dieser Stelle bereits hart ab.
2. **Node.js & Rust**: werden installiert bzw. aktualisiert (oder auf die
   gepinnte Version gebracht, falls `NODE_VERSION_PIN`/`RUST_VERSION_PIN`
   gesetzt sind). Ein Versionswechsel bei einem der beiden löst automatisch
   einen Rebuild aus. Die Node.js-LTS-Ermittlung ist seit 1.11 gegen einen
   stillen Script-Abbruch bei Netzwerkproblemen abgesichert (siehe oben).
3. **Systemuser + PostgreSQL-Rolle/Datenbank**: werden angelegt, falls noch
   nicht vorhanden. `OXICLOUD_HOME` wird bei jedem Lauf rekursiv auf
   `oxicloud:oxicloud` zurückgesetzt (Selbstheilung). Seit 1.11 wird das
   DB-Passwort zusätzlich bei **jedem** Lauf per `ALTER ROLE` durchgesetzt
   und die Verbindung direkt verifiziert (siehe oben).
4. **Klonen/Aktualisieren**: `git clone` bei Erstlauf; danach, sofern kein
   `OXICLOUD_VERSION_PIN` gesetzt ist, seit 1.13 `git fetch` + `git reset
   --hard origin/main` statt `git pull origin main` (siehe „Neuerungen in
   1.13", Punkt 4). Lokale, nicht committete Änderungen an getrackten
   Dateien werden weiterhin vorher als Patch unter
   `local-changes-backup/` gesichert und dann verworfen.
5. **`.env` erzeugen/ergänzen**: Bei Erstlauf wird `example.env` kopiert.
   Bei bereits bestehender `.env` werden nur **fehlende** Variablen aus
   einer neueren `example.env` automatisch angehängt — vorhandene Werte
   bleiben unverändert. Seit 1.11 landet `DATABASE_URL` ebenfalls in der
   `.env` (statt im systemd-Unit-File, siehe oben). Wird
   `ENV_OVERRIDE_SERVER_HOST` auf `0.0.0.0`/`::` gesetzt, gibt das Script
   seit 1.13 zusätzlich einen Firewall-Hinweis aus.
6. **DB-Backup + Migrationen**: Seit 1.13 läuft direkt vor der Migration
   ein `pg_dump`-Backup nach `/etc/oxicloud/db-backups` (siehe „Neuerungen
   in 1.13", Punkt 2); schlägt das Backup fehl, wird die Migration gar
   nicht erst versucht. Danach läuft `cargo sqlx migrate run` wie bisher
   bei **jedem** Lauf (idempotent, wendet nur ausstehende Migrationen an).
7. **Rebuild** (nur falls nötig): Frontend (`npm run build`) und Backend
   (`cargo build --release --locked`) werden neu gebaut. Die entstehende
   Binary wird nach ihrem Git-Commit-Hash versioniert unter `releases/`
   abgelegt; der Symlink `current` zeigt danach darauf.
8. **systemd**: Unit wird (neu) geschrieben (weiterhin ohne `DATABASE_URL`
   im Klartext, siehe oben), Dienst bei Bedarf neu gestartet.
9. **Health-Check + automatisches Rollback** *(neu in 1.13)*: Nur falls
   gerade neu gebaut/gestartet wurde. Antwortet der Dienst nicht
   fristgerecht, wird automatisch auf das vorherige Release
   zurückgerollt (siehe „Neuerungen in 1.13", Punkt 1). Bei jedem
   Fehlschlag des gesamten Laufs (Exit-Code ≠ 0) wird, falls
   `NOTIFY_WEBHOOK_URL` gesetzt ist, zusätzlich eine Benachrichtigung
   verschickt (siehe Punkt 7 dort).

---

## Was garantiert erhalten bleibt (idempotent über mehrere Läufe)

| Was | Mechanismus |
|---|---|
| DB-Passwort | Persistiert in `/etc/oxicloud/.db_password` (`chmod 600`), wiederverwendet statt neu generiert — **und seit 1.11 bei jedem Lauf aktiv gegen die Datenbank durchgesetzt** (`ALTER ROLE`), nicht nur beim Erstanlegen vorausgesetzt |
| Bestehende `.env`-Werte | Nur fehlende Variablen werden ergänzt, nichts wird überschrieben |
| Lokale, nicht committete Änderungen in `OXICLOUD_HOME` | Werden vor jedem Pull/Reset als Patch unter `local-changes-backup/` gesichert (dann verworfen, da das Verzeichnis ausschließlich vom Script verwaltet werden soll) |
| `.env`, systemd-Unit, `/etc/fstab` | Vor jedem Überschreiben wird eine Zeitstempel-Kopie in einem `backups/`-Unterordner neben der jeweiligen Datei angelegt — seit 1.14 begrenzt auf die neuesten `GENERIC_BACKUP_KEEP` Stände pro Datei, vorher unbegrenztes Wachstum |
| Alte Releases | Über `KEEP_RELEASES` gesteuert; die aktive Version wird nie automatisch gelöscht |
| DB-Backups *(neu in 1.13)* | Unter `/etc/oxicloud/db-backups`, über `DB_BACKUP_KEEP` (Standard 10) gesteuert |

---

## Sicherheit: Datei-Rechte im Überblick

| Datei | Rechte | Enthält |
|---|---|---|
| `/etc/oxicloud/.env` | `640`, `root:oxicloud` | `DATABASE_URL`, `OXICLOUD_DB_CONNECTION_STRING`, weitere `.env`-Werte |
| `/etc/oxicloud/.db_password` | `600`, root | DB-Passwort im Klartext |
| `/etc/oxicloud/db-backups/*.sql.gz` *(neu in 1.13)* | `600`, root | Vollständiger Datenbank-Dump (potenziell sensible Nutzdaten) |
| `/etc/systemd/system/oxicloud.service` | `644` (systemd-Standard, für alle lesbar) | **Seit 1.11 kein Passwort mehr** — vorher enthielt es `DATABASE_URL` im Klartext |

---

## Versionierte Releases & Rollback

Jede gebaute Binary landet unter `${OXICLOUD_HOME}/releases/oxicloud-<git-hash>`,
`current` ist ein Symlink darauf.

**Automatisch (seit 1.13):** Antwortet der Dienst nach einem Rebuild nicht
innerhalb von `HEALTH_RETRIES` × 2 Sekunden auf
`http://127.0.0.1:${OXICLOUD_PORT}/`, rollt das Script selbstständig auf
das zuletzt funktionierende Release zurück und startet den Dienst damit
neu (siehe „Neuerungen in 1.13", Punkt 1). Das Script beendet sich in
diesem Fall trotzdem mit Exit-Code 1, damit der Fehlschlag sichtbar bleibt
(z. B. für die Webhook-Benachrichtigung oder einen Cron-Job-Status).

**Manuell** (z. B. um gezielt auf ein älteres, nicht das direkt vorherige
Release zu wechseln):

```bash
sudo ln -sfn /opt/oxicloud/releases/oxicloud-<alter-hash> /opt/oxicloud/current
sudo systemctl restart oxicloud
```

---

## Ressourcenbedarf beim Kompilieren

`cargo build --release` mit LTO ist speicherhungrig. Das Script gibt dazu
eine Einschätzung aus (empfohlen: 4+ CPU-Kerne, 16+ GB RAM, ~20 GB freier
Speicher) und legt bei zu wenig RAM **automatisch** einen 8-GB-Swapfile an
(`/swapfile`, dauerhaft in `/etc/fstab` eingetragen) — und entfernt ihn nach
erfolgreichem Build wieder vollständig, inklusive `/etc/fstab`-Eintrag.

Seit 1.13 gilt zusätzlich: Sinkt der freie Speicherplatz unter
`DISK_ABORT_THRESHOLD_GB` (Standard 5 GB), bricht das Script **vor** dem
Build hart ab, statt erst mitten in `cargo build` an voller Platte zu
scheitern.

Falls das automatische Swap-Verhalten nicht gewünscht ist: manuell vorab
mehr RAM bereitstellen, oder den Swapfile-Block im Script deaktivieren.

---

## Versions-Pinning

Standardmäßig läuft alles auf dem jeweils neuesten Stand:
- OxiCloud: `main`-Branch (seit 1.13 via `git fetch` + `reset --hard
  origin/main`, siehe „Neuerungen in 1.13", Punkt 4)
- Node.js: neueste LTS-Major-Version
- Rust: `rustup update stable`

Für reproduzierbare/stabile Deployments können alle drei über
`OXICLOUD_VERSION_PIN`, `NODE_VERSION_PIN`, `RUST_VERSION_PIN` festgenagelt
werden. Ein Wechsel eines Pins (z. B. neues `OXICLOUD_VERSION_PIN`) löst
automatisch einen Rebuild aus, sobald sich dadurch etwas ändert.

---

## Logs

```bash
journalctl -u oxicloud -f          # Dienst-Logs (laufender Betrieb)
tail -f /var/log/oxicloud-install.log   # Install-/Update-Läufe des Scripts
```

Jeder Lauf des Scripts hängt zusätzlich an `/var/log/oxicloud-install.log`
an. Seit 1.13 richtet das Script (sofern `logrotate` verfügbar ist)
automatisch `/etc/logrotate.d/oxicloud-install` ein (wöchentlich, 8
Generationen, komprimiert), damit dieses Log bei wiederholten/
automatisierten Läufen nicht unbegrenzt wächst.

---

## Troubleshooting

**`./install-oxicloud.sh: line N: sudo: command not found` (behoben seit 1.12):**
Trat vor allem in minimalen LXC-Containern auf (z. B. offizielle
Proxmox-Debian-Templates), die `sudo` standardmäßig nicht mitbringen — im
Gegensatz zu vollwertigen VMs/Images. Seit Version 1.12 installiert der
Preflight-Check `sudo` automatisch mit, falls es fehlt (siehe „Fix in
1.12" oben). Bei einer älteren Script-Version: `apt-get install -y sudo`
manuell ausführen und das Script erneut starten — dank Idempotenz setzt es
sauber dort fort, wo es abgebrochen war.

**Build bricht mit `signal: 9, SIGKILL` ab:**
Fast immer OOM (zu wenig RAM). Das Script versucht das per Auto-Swapfile
abzufangen, aber bei sehr kleinen VMs (z. B. 1–2 GB RAM) kann selbst das
nicht reichen — mehr RAM bereitstellen oder auf das Prebuilt-Tooling
umsteigen (Build auf einer stärkeren separaten Maschine).

**Script bricht mit „Nur noch ca. X GB frei ... Breche vor dem Build ab" ab (neu in 1.13):**
Kein Fehler, sondern beabsichtigt: weniger als `DISK_ABORT_THRESHOLD_GB`
(Standard 5 GB) frei unter `${OXICLOUD_HOME%/*}`. Zuerst Speicherplatz
freigeben — Kandidaten laut Fehlermeldung: alte Releases unter
`releases/` (über `KEEP_RELEASES` steuerbar), alte DB-Backups unter
`/etc/oxicloud/db-backups` (über `DB_BACKUP_KEEP` steuerbar),
`apt-get clean` — dann erneut ausführen.

**„Dienst antwortet nach 10 Versuchen (je 2s) nicht ... Rolle automatisch zurück auf vorheriges Release" (neu in 1.13):**
Der Health-Check nach einem Rebuild ist fehlgeschlagen, das Script hat
automatisch auf das vorherige, zuletzt funktionierende Release
zurückgerollt (siehe „Neuerungen in 1.13", Punkt 1, und „Versionierte
Releases & Rollback" oben). Ursache im **neuen** Release liegt meist an
einem Laufzeitfehler oder einer fehlgeschlagenen Migration — dazu die
mitausgegebenen letzten 50 Zeilen aus `journalctl -u oxicloud` prüfen,
bzw. erneut per `journalctl -u oxicloud -n 100 --no-pager` nachsehen.
Erst nach Behebung der Ursache erneut versuchen; bis dahin läuft der
Dienst stabil mit dem zurückgerollten, vorherigen Release weiter.

**„ACHTUNG: Auch das vorherige Release startet nicht sauber. Manueller Eingriff nötig!" (neu in 1.13):**
Sowohl das neue als auch das automatisch zurückgerollte vorherige Release
starten nicht sauber — deutet meist auf ein externes Problem hin, das
nicht am Release selbst liegt (z. B. PostgreSQL down, `.env` fehlerhaft,
Port bereits belegt). `systemctl status oxicloud` und
`journalctl -u oxicloud -n 100 --no-pager` prüfen, Ursache beheben, dann
manuell `systemctl restart oxicloud`.

**Kein DB-Backup gefunden, obwohl ein Lauf durchgelaufen ist:**
Backups landen unter `/etc/oxicloud/db-backups/${DB_NAME}-<timestamp>.sql.gz`.
Prüfen, ob genug Diskspace für `pg_dump` vorhanden war — schlägt das
Backup fehl, bricht das Script bewusst **vor** der Migration ab (siehe
„Neuerungen in 1.13", Punkt 2), es gäbe also ohnehin keinen weitergehenden
Lauf ohne Backup.

**Webhook-Benachrichtigung kommt nicht an (neu in 1.13):**
`NOTIFY_WEBHOOK_URL` muss gesetzt und vom Zielserver aus erreichbar sein
(ausgehender Zugriff, ggf. Firewall/Proxy). Die Benachrichtigung selbst
ist bewusst fehlertolerant (`curl ... || true`, 10s Timeout) und wird
niemals selbst laut fehlschlagen — im Zweifel manuell testen:
```bash
curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
  -d '{"text":"Testnachricht"}' "<eure NOTIFY_WEBHOOK_URL>"
```

**„Ein anderer Lauf dieses Scripts ist bereits aktiv":**
`flock` auf `/var/run/oxicloud-install.lock` verhindert parallele Läufe
(z. B. zwei gleichzeitige SSH-Sessions). Prüfen, ob wirklich noch ein Lauf
aktiv ist (`ps aux | grep install-oxicloud`), sonst Lock-Datei manuell
entfernen.

**Tag/Referenz aus `OXICLOUD_VERSION_PIN` existiert nicht:**
Script bricht bewusst hart ab (`git checkout` schlägt fehl) statt
stillschweigend auf `main` zurückzufallen — Tag-Namen im Repo prüfen.

**Repo-URL unsicher:**
`DioCrafts/OxiCloud` und `AtalayaLabs/OxiCloud` sind aktuell beide aktiv
mit identischem Release-Stand. Siehe Kommentar direkt über `REPO_URL` im
Script — einmal selbst verifizieren, welcher Remote für euch verbindlich
sein soll.

**„Konnte aktuelle Node.js-Version nicht ermitteln, falle zurück auf Node 24" (neu sichtbar seit 1.11):**
Normales, beabsichtigtes Verhalten bei Netzwerkproblemen zu nodejs.org.
Vor 1.11 hätte genau dieser Fall das Script stattdessen stillschweigend
komplett beendet, ohne dass diese Meldung je erschienen wäre — sie war
zwar im Code vorgesehen, aber durch den `set -e`-Fallstrick unerreichbar.
Kein Handlungsbedarf, außer eine bestimmte Node-Version wird zwingend
benötigt (`NODE_VERSION_PIN` setzen).

**„Verbindung zur Datenbank ... schlägt fehl, obwohl Rolle/Datenbank/
Passwort gerade eben gesetzt wurden" (neu in 1.11):**
Meist eine `pg_hba.conf`-Authentifizierungsmethode, die kein
Passwort-Login für `localhost` erlaubt (z. B. `peer` statt `md5`/
`scram-sha-256`). Prüfen:
```bash
cat /etc/postgresql/*/main/pg_hba.conf | grep -v '^#'
```
Zeile für `host ... 127.0.0.1/32 ...` bzw. `local` auf `md5` oder
`scram-sha-256` umstellen, danach `systemctl restart postgresql`.

---

Lizenz: **MIT**
