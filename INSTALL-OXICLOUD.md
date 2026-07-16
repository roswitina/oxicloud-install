# install-oxicloud.sh — Anleitung

Native (Nicht-Container-)Installation von OxiCloud, die den Quellcode
**direkt auf dem Zielserver** klont, kompiliert und als systemd-Dienst
betreibt — im Gegensatz zum separaten Prebuilt-Tooling
(`build-package.sh`/`install.sh`/`update.sh`), das auf einer separaten
Build-Maschine kompiliert und ein fertiges `.tar.gz` verteilt.

Version: 1.10
Lizenz: MIT

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

## Voraussetzungen

- Debian/Ubuntu mit systemd
- root-Zugriff (bzw. `sudo`)
- Internetzugang auf dem Zielserver (für `apt`, GitHub, crates.io, npm-Registry, rustup, NodeSource)
- Ausreichend Ressourcen zum Kompilieren — siehe Abschnitt „Ressourcenbedarf" unten. Fehlt genug RAM, legt das Script selbst einen temporären Swapfile an.

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
| `OXICLOUD_PORT` | `8086` | Nur für die Abschluss-Ausgabe (Anzeige-URL), keine funktionale Wirkung |
| `DB_NAME` / `DB_USER` | `oxicloud` | Name von Datenbank und Postgres-Rolle |
| `REPO_URL` | `https://github.com/AtalayaLabs/OxiCloud.git` | Woher geklont wird — siehe Hinweis im Script zur Doppel-Existenz von `DioCrafts/OxiCloud` und `AtalayaLabs/OxiCloud` |
| `KEEP_RELEASES` | `5` | Wie viele alte versionierte Binaries behalten werden; `0` = nichts löschen |
| `NODE_VERSION_PIN` | leer | Leer = immer neueste LTS-Major-Version; sonst z. B. `"22"` |
| `RUST_VERSION_PIN` | leer | Leer = immer `rustup update stable`; sonst z. B. `"1.82.0"` |
| `ENV_OVERRIDE_SERVER_HOST` | leer | Überschreibt `OXICLOUD_SERVER_HOST` in der `.env`, z. B. `"0.0.0.0"` |
| `ENV_OVERRIDE_BASE_URL` | leer | Überschreibt `OXICLOUD_BASE_URL` in der `.env`, z. B. `"https://cloud.example.com"` |
| `OXICLOUD_VERSION_PIN` | leer | Leer = folgt `main`-Branch; `"latest"` = neuestes GitHub-Release; `"vX.Y.Z"` = fester Tag |
| `ENABLE_PLUGINS` | `false` | `true` baut mit Cargo-Feature `plugins` (WASM-Runtime via Extism) und setzt `OXICLOUD_ENABLE_PLUGINS=true` |

Alle `ENV_OVERRIDE_*`-Variablen greifen nur, wenn nicht leer — leer lassen
heißt: Standardwert aus `example.env` bleibt unangetastet.

---

## Ablauf im Detail

1. **Preflight-Check**: `git`, `curl`, `jq`, `openssl`, `postgresql`,
   `postgresql-contrib`, `build-essential`, `pkg-config`, `libssl-dev`,
   `ca-certificates` werden geprüft und fehlende per `apt` nachinstalliert.
2. **Node.js & Rust**: werden installiert bzw. aktualisiert (oder auf die
   gepinnte Version gebracht, falls `NODE_VERSION_PIN`/`RUST_VERSION_PIN`
   gesetzt sind). Ein Versionswechsel bei einem der beiden löst automatisch
   einen Rebuild aus.
3. **Systemuser + PostgreSQL-Rolle/Datenbank**: werden angelegt, falls noch
   nicht vorhanden. `OXICLOUD_HOME` wird bei jedem Lauf rekursiv auf
   `oxicloud:oxicloud` zurückgesetzt (Selbstheilung).
4. **Klonen/Aktualisieren**: `git clone`/`git pull` in `OXICLOUD_HOME`.
   Lokale, nicht committete Änderungen an getrackten Dateien werden vor
   jedem Pull als Patch unter `local-changes-backup/` gesichert und dann
   verworfen, damit der Pull nicht an einem Merge-Konflikt scheitert.
5. **`.env` erzeugen/ergänzen**: Bei Erstlauf wird `example.env` kopiert.
   Bei bereits bestehender `.env` werden nur **fehlende** Variablen aus
   einer neueren `example.env` automatisch angehängt — vorhandene Werte
   bleiben unverändert.
6. **Migrationen**: `cargo sqlx migrate run` läuft bei **jedem** Lauf
   (idempotent, wendet nur ausstehende Migrationen an).
7. **Rebuild** (nur falls nötig): Frontend (`npm run build`) und Backend
   (`cargo build --release --locked`) werden neu gebaut. Die entstehende
   Binary wird nach ihrem Git-Commit-Hash versioniert unter `releases/`
   abgelegt; der Symlink `current` zeigt danach darauf.
8. **systemd**: Unit wird (neu) geschrieben, Dienst bei Bedarf neu
   gestartet.

---

## Was garantiert erhalten bleibt (idempotent über mehrere Läufe)

| Was | Mechanismus |
|---|---|
| DB-Passwort | Persistiert in `/etc/oxicloud/.db_password` (`chmod 600`), wiederverwendet statt neu generiert |
| Bestehende `.env`-Werte | Nur fehlende Variablen werden ergänzt, nichts wird überschrieben |
| Lokale, nicht committete Änderungen in `OXICLOUD_HOME` | Werden vor jedem Pull als Patch unter `local-changes-backup/` gesichert (dann verworfen, da das Verzeichnis ausschließlich vom Script verwaltet werden soll) |
| `.env`, systemd-Unit, `/etc/fstab` | Vor jedem Überschreiben wird eine Zeitstempel-Kopie in einem `backups/`-Unterordner neben der jeweiligen Datei angelegt |
| Alte Releases | Über `KEEP_RELEASES` gesteuert; die aktive Version wird nie automatisch gelöscht |

---

## Versionierte Releases & manuelles Rollback

Jede gebaute Binary landet unter `${OXICLOUD_HOME}/releases/oxicloud-<git-hash>`,
`current` ist ein Symlink darauf. Rollback auf eine ältere, noch vorhandene
Version:

```bash
sudo ln -sfn /opt/oxicloud/releases/oxicloud-<alter-hash> /opt/oxicloud/current
sudo systemctl restart oxicloud
```

(Kein automatischer Health-Check-Rollback wie beim Prebuilt-`update.sh` —
hier ist Rollback ein manueller Schritt.)

---

## Ressourcenbedarf beim Kompilieren

`cargo build --release` mit LTO ist speicherhungrig. Das Script gibt dazu
eine Einschätzung aus (empfohlen: 4+ CPU-Kerne, 16+ GB RAM, ~20 GB freier
Speicher) und legt bei zu wenig RAM **automatisch** einen 8-GB-Swapfile an
(`/swapfile`, dauerhaft in `/etc/fstab` eingetragen) — und entfernt ihn nach
erfolgreichem Build wieder vollständig, inklusive `/etc/fstab`-Eintrag.

Falls das nicht gewünscht ist: manuell vorab mehr RAM bereitstellen, oder
den Swapfile-Block im Script deaktivieren.

---

## Versions-Pinning

Standardmäßig läuft alles auf dem jeweils neuesten Stand:
- OxiCloud: `main`-Branch
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

Jeder Lauf des Scripts hängt zusätzlich an `/var/log/oxicloud-install.log` an.

---

## Troubleshooting

**Build bricht mit `signal: 9, SIGKILL` ab:**
Fast immer OOM (zu wenig RAM). Das Script versucht das per Auto-Swapfile
abzufangen, aber bei sehr kleinen VMs (z. B. 1–2 GB RAM) kann selbst das
nicht reichen — mehr RAM bereitstellen oder auf das Prebuilt-Tooling
umsteigen (Build auf einer stärkeren separaten Maschine).

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

---

## Versionshistorie

| Version | Änderung |
|---|---|
| 1.9 | Ursprüngliche Fassung |
| 1.10 | `REPO_URL` konsistent auf `AtalayaLabs/OxiCloud` (inkl. GitHub-API-Aufruf in `resolve_target_ref()`); systemd-Hardening ergänzt (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths`); Kommentar zur `Requires=` vs. `Wants=`-Entscheidung bei `postgresql.service` |

Lizenz: **MIT**
