#!/usr/bin/env bash
#
# Native (non-container) install script for OxiCloud
# https://github.com/AtalayaLabs/OxiCloud
#
# Version:          1.13
# Lizenz:           MIT
# Erstellt am:      2026-07-13 15:59 UTC
# Zuletzt geändert: 2026-07-20 UTC (Health-Check/Rollback, DB-Backup, u.a.)
#
# Changelog:
#   1.13 - Sieben Robustheits-Verbesserungen nach Review:
#          1) Health-Check nach Neustart + automatisches Rollback: schlägt
#             der Health-Check (systemd aktiv + HTTP-Antwort auf dem
#             konfigurierten Port) nach einem Rebuild fehl, wird "current"
#             automatisch auf das vorherige Release unter releases/
#             zurückgesetzt und der Dienst erneut gestartet, statt einfach
#             auf dem defekten Release stehen zu bleiben.
#          2) Automatisches DB-Backup (pg_dump, gzip) direkt vor jeder
#             Migration unter /etc/oxicloud/db-backups, inkl. Aufbewahrung
#             der letzten DB_BACKUP_KEEP Stände. Schlägt das Backup fehl,
#             wird die Migration gar nicht erst versucht.
#          3) Logrotate-Konfiguration für /var/log/oxicloud-install.log wird
#             automatisch angelegt (falls logrotate verfügbar ist), damit
#             das Log bei wiederholten/automatisierten Läufen nicht
#             unbegrenzt wächst.
#          4) "git pull origin main" durch "git fetch" + "reset --hard
#             origin/main" ersetzt, damit ein divergierter main (z.B. nach
#             einem Force-Push upstream) den Lauf nicht mehr scheitern
#             lässt - konsistent zur bestehenden Philosophie, dass
#             /opt/oxicloud exklusiv vom Script verwaltet wird.
#          5) Harter Abbruch VOR dem Build, falls weniger als
#             DISK_ABORT_THRESHOLD_GB frei sind, statt nur einer Warnung -
#             vermeidet einen mittendrin abgebrochenen "cargo build" durch
#             währenddessen vollgelaufene Platte.
#          6) Hinweis/Prüfung auf offene Firewall-Regeln, falls
#             ENV_OVERRIDE_SERVER_HOST auf 0.0.0.0 (bzw. ::) gesetzt wird,
#             damit der Port nicht versehentlich offen ins Internet zeigt.
#          7) Optionale Fehler-Benachrichtigung per Webhook (NOTIFY_WEBHOOK_URL):
#             bei jedem Lauf mit Exit-Code != 0 wird, falls konfiguriert,
#             eine kurze Meldung per POST verschickt - wichtig, falls das
#             Script unbeaufsichtigt per Cron läuft.
#   1.12 - Fix nach fehlgeschlagenem Testlauf in einem LXC-Container
#          (Proxmox, Debian Trixie): "sudo" fehlte in der Preflight-
#          Paketliste. Minimale LXC-Templates bringen "sudo" oft NICHT
#          vorinstalliert mit (im Gegensatz zu vollwertigen VMs/Images wie
#          DietPi) - root zu sein (siehe EUID-Check unten) garantiert nicht,
#          dass der Befehl "sudo" selbst existiert. Das Script verlässt sich
#          aber an sehr vielen Stellen auf "sudo -u ..." (DB-Rolle anlegen,
#          Repo klonen, Rust/Cargo, npm build, ...), wodurch der Lauf beim
#          allerersten "sudo"-Aufruf mit "command not found" scheiterte.
#          Jetzt wird "sudo" mit in REQUIRED_APT_PACKAGES aufgenommen und
#          vom bestehenden Preflight-Mechanismus automatisch nachinstalliert.
#   1.11 - Drei Fixes nach Review:
#          1) Node.js-LTS-Ermittlung war eine plain Command-Substitution
#             mit Pipe unter "set -e -o pipefail" - schlug curl fehl (z.B.
#             nodejs.org nicht erreichbar), beendete sich das GANZE Skript
#             sofort und stillschweigend an dieser Stelle, der direkt
#             darunterstehende Fallback (LATEST_LTS_MAJOR=24) wurde nie
#             erreicht. Jetzt mit "|| true" abgesichert, Fallback greift.
#          2) DB-Passwort wurde nur beim ERSTMALIGEN Anlegen der Rolle
#             gesetzt ("CREATE ROLE ... || true"-Logik) - existierte die
#             Rolle bereits (z.B. nach einem abgebrochenen Lauf oder einer
#             wiederhergestellten DB) mit einem ANDEREN Passwort als in
#             /etc/oxicloud/.db_password gespeichert, blieb das unbemerkt,
#             bis sqlx/der Dienst selbst mit einem kryptischen Auth-Fehler
#             scheiterte. Jetzt: "ALTER ROLE ... WITH PASSWORD" läuft bei
#             JEDEM Lauf, garantiert Übereinstimmung; zusätzlich ein
#             expliziter Verbindungstest mit klarer Fehlermeldung.
#          3) Das DB-Passwort stand im Klartext direkt im systemd-Unit-File
#             ("Environment=DATABASE_URL=..."), das standardmäßig für ALLE
#             lokalen User lesbar ist (644) - im Gegensatz zur bewusst
#             restriktiv geschützten .env (640)/.db_password (600). Jetzt
#             wird DATABASE_URL stattdessen in die .env geschrieben und nur
#             noch über "EnvironmentFile=" geladen, nicht mehr inline im
#             Unit-File.
#
# Tested target: Debian/Ubuntu with systemd
# Requires: root privileges (or sudo)
#
# What this script does:
#   1. Preflight-Check: prüft benötigte Programme (git, curl, jq, openssl,
#      PostgreSQL, Node.js, Rust/cargo) und installiert/aktualisiert fehlende
#   2. Installs/updates Rust (rustup) and Node.js to the latest version
#      (or to a pinned version, see NODE_VERSION_PIN / RUST_VERSION_PIN below)
#   3. Creates a dedicated system user + PostgreSQL role/database. Stellt bei
#      jedem Lauf per rekursivem chown sicher, dass ${OXICLOUD_HOME}
#      durchgängig oxicloud:oxicloud gehört (Selbstheilung, falls z.B. durch
#      manuelle root-Eingriffe versehentlich root-eigene Dateien entstanden).
#   4. Clones/updates OxiCloud, configures /etc/oxicloud/.env. Bei bereits
#      bestehender .env werden fehlende Variablen aus einer neueren
#      example.env automatisch ergänzt (angehängt), ohne vorhandene Werte
#      zu überschreiben. Standardmäßig wird immer der main-Branch verfolgt;
#      via OXICLOUD_VERSION_PIN kann stattdessen ein festes Release/Tag
#      verwendet werden (siehe Konfigurationsblock unten). Lokale, nicht
#      committete Änderungen an getrackten Dateien in /opt/oxicloud (die dort
#      nicht hingehören) werden vor jedem Pull automatisch als Patch unter
#      local-changes-backup/ gesichert und dann verworfen, damit Pull/Checkout
#      nicht an einem Merge-Konflikt scheitern. sqlx-cli wird bei Bedarf
#      installiert; "cargo sqlx migrate run" wird bei JEDEM Lauf ausgeführt
#      (idempotent, wendet nur ausstehende Migrationen an).
#   5. Rebuilds frontend + release binary only if something actually changed
#      (new commits, new Rust toolchain, missing binary, changed Plugin-
#      Feature, ODER falls der letzte Build-Versuch nicht vollständig
#      erfolgreich war - siehe .last_build_ok Marker). Jede gebaute Binary
#      wird nach ihrem Git-Commit-Hash versioniert unter releases/ abgelegt;
#      ein Symlink "current" zeigt auf die jeweils aktive Version.
#   6. Installs a systemd unit and (re)starts the service if needed
#
# Idempotent: safe to re-run. DB password and .env values persist across runs.
# Vor jedem Überschreiben von .env, der systemd-Unit oder /etc/fstab wird
# automatisch eine Zeitstempel-Kopie in einem "backups"-Unterordner neben
# der jeweiligen Datei angelegt (z.B. /etc/oxicloud/backups/.env.<timestamp>.bak).
#
# Version pinning: by default Node.js and Rust are always kept at the latest
# version. To pin them to a fixed version instead, set NODE_VERSION_PIN and/or
# RUST_VERSION_PIN in the configuration block below.
#
# Netzwerk/.env: ENV_OVERRIDE_SERVER_HOST (z.B. "0.0.0.0") und
# ENV_OVERRIDE_BASE_URL (z.B. "https://cloud.example.com") können optional
# gesetzt werden, um die gleichnamigen Werte (ohne ENV_OVERRIDE_-Präfix) in
# /etc/oxicloud/.env zu überschreiben. Leer lassen = Standardwert aus
# example.env bleibt unangetastet.
#
# ENABLE_PLUGINS=true baut mit dem Cargo-Feature "plugins" (WASM-Plugin-
# Runtime via Extism) und setzt OXICLOUD_ENABLE_PLUGINS=true in der .env.
# Ein Wechsel dieses Schalters löst automatisch einen Rebuild aus.
#
# Alle Ausgaben werden zusätzlich (anhängend) protokolliert in:
#   /var/log/oxicloud-install.log
#
# Run as: sudo bash install-oxicloud.sh
#
set -euo pipefail

### ---- Configuration (adjust as needed) ------------------------------------
OXICLOUD_USER="oxicloud"
OXICLOUD_HOME="/opt/oxicloud"
OXICLOUD_PORT="8086"
DB_NAME="oxicloud"
DB_USER="oxicloud"
# HINWEIS: DioCrafts/OxiCloud und AtalayaLabs/OxiCloud sind aktuell beide
# aktiv und mit identischem Release-Stand (z.B. gleicher Changelog für
# v0.6.0). DioCrafts scheint der ursprüngliche Autor zu sein, der jetzt
# (auch) unter der Organisation AtalayaLabs veröffentlicht; welcher Remote
# für euch "der kanonische" ist, bitte einmal selbst verifizieren, bevor
# ihr produktiv darauf setzt. Standardmäßig auf AtalayaLabs umgestellt.
REPO_URL="https://github.com/AtalayaLabs/OxiCloud.git"

# Script-Version (siehe Header-Kommentar oben für Erstelldatum)
SCRIPT_VERSION="1.13"

# Versionierte Binaries: nach jedem Build wird die Binary nach ihrem
# Git-Commit-Hash benannt und unter releases/ abgelegt. "current" ist ein
# Symlink auf die jeweils aktuelle Binary - systemd startet immer über
# diesen stabilen Pfad, egal welcher Commit dahinter steckt.
RELEASES_DIR="${OXICLOUD_HOME}/releases"
CURRENT_LINK="${OXICLOUD_HOME}/current"

# Wie viele alte Releases behalten werden (für schnelles manuelles Rollback).
# 0 = keine Bereinigung, alle Releases werden dauerhaft behalten.
KEEP_RELEASES=5

# Versionen festnageln (optional). Leer lassen ("") = jeweils automatisch neueste Version verwenden.
# NODE_VERSION_PIN Beispiel: "22"        (nur Major-Version, z.B. "20", "22", "24")
# RUST_VERSION_PIN Beispiel: "1.82.0"    (exakte Toolchain-Version, wie von "rustup toolchain install" akzeptiert)
NODE_VERSION_PIN=""
RUST_VERSION_PIN=""

# .env-Werte gezielt überschreiben (optional). Leer lassen ("") = den Wert
# aus example.env unverändert übernehmen, nichts wird überschrieben.
# Bewusst NICHT "OXICLOUD_SERVER_HOST_PIN" o.ä. genannt, um Verwechslung mit
# der tatsächlichen .env-Variable OXICLOUD_SERVER_HOST zu vermeiden.
# ENV_OVERRIDE_SERVER_HOST Beispiel: "0.0.0.0"   (lauscht auf allen Interfaces statt nur localhost)
# ENV_OVERRIDE_BASE_URL Beispiel: "https://cloud.example.com"  (wichtig bei Domain/Reverse-Proxy/HTTPS)
ENV_OVERRIDE_SERVER_HOST=""
ENV_OVERRIDE_BASE_URL=""

# OxiCloud-Version festnageln (optional). Leer lassen ("") = immer der
# neueste Stand des main-Branches (wie bisher, Entwicklungsversion).
# OXICLOUD_VERSION_PIN Beispiel: "latest"  = neuestes veröffentlichtes
#   GitHub-Release (z.B. aktuell v0.8.3), wird automatisch ermittelt.
# OXICLOUD_VERSION_PIN Beispiel: "v0.8.3"  = exakt dieser Tag/dieses Release.
# Ein Wechsel des Pins (z.B. von "" auf "v0.8.3", oder auf ein neueres Release)
# löst automatisch einen Rebuild aus, sobald sich dadurch der Commit ändert.
OXICLOUD_VERSION_PIN=""

# WASM-Plugin-Runtime (Extism) aktivieren. Erfordert das Cargo-Feature
# "plugins" beim Bauen; ohne dieses Feature ist OXICLOUD_ENABLE_PLUGINS in
# der .env wirkungslos. Untrusted Plugins laufen laut Doku sandboxed (kein
# Dateisystem-/Netzwerkzugriff, begrenzter Speicher, Timeout pro Aufruf).
# false (Standard) = wie bisher, kein Plugin-Feature, .env bleibt unangetastet.
# true = baut mit "--features plugins" und setzt OXICLOUD_ENABLE_PLUGINS=true.
ENABLE_PLUGINS=false

# Optionaler Webhook, der bei einem fehlgeschlagenen Lauf (Exit-Code != 0)
# aufgerufen wird - wichtig, falls das Script unbeaufsichtigt per Cron läuft,
# damit ein Fehlschlag nicht erst auffällt, wenn der Dienst schon lange down
# ist. Es wird ein simpler JSON-POST-Body gesendet: {"text": "..."}. Leer
# lassen ("") = keine Benachrichtigung (Standard).
# Beispiel (Slack/Mattermost-kompatibler Incoming-Webhook):
#   NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
NOTIFY_WEBHOOK_URL=""
### ---------------------------------------------------------------------------

# ---- Fehler-Benachrichtigung (optional) ------------------------------------
# Läuft das Script unbeaufsichtigt per Cron (Auto-Update), fällt ein
# fehlgeschlagener Lauf sonst erst auf, wenn der Dienst schon länger down
# ist. Bei Exit-Code != 0 und gesetztem NOTIFY_WEBHOOK_URL wird eine kurze
# Meldung per POST an den Webhook geschickt. Absichtlich robust gegen
# eigene Fehler (kein "set -e"-Effekt hier, "|| true" überall), damit die
# Benachrichtigung selbst niemals den eigentlichen Exit-Code verschluckt.
notify_on_failure() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 && -n "${NOTIFY_WEBHOOK_URL}" ]]; then
    local host
    host="$(hostname 2>/dev/null || echo unknown)"
    local msg="OxiCloud install/update auf '${host}' fehlgeschlagen (Exit-Code ${exit_code}). Log: ${LOG_FILE:-/var/log/oxicloud-install.log}"
    curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
      -d "$(printf '{"text":"%s"}' "${msg//\"/\\\"}")" \
      "${NOTIFY_WEBHOOK_URL}" >/dev/null 2>&1 || true
  fi
  return "${exit_code}"
}
trap notify_on_failure EXIT

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root bzw. mit sudo ausführen." >&2
  exit 1
fi

# ---- Verhindert parallele Läufe (z.B. zwei SSH-Sessions gleichzeitig) ------
LOCK_FILE="/var/run/oxicloud-install.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  echo "Fehler: Ein anderer Lauf dieses Scripts ist bereits aktiv (Lock: ${LOCK_FILE})." >&2
  exit 1
fi

LOG_FILE="/var/log/oxicloud-install.log"
mkdir -p "$(dirname "${LOG_FILE}")"

# ---- Log-Rotation für das Install-Log --------------------------------------
# ${LOG_FILE} wächst bei jedem Lauf per "tee -a" unbegrenzt weiter, vor allem
# bei regelmäßigen automatisierten Läufen (Cron). logrotate übernimmt das,
# falls verfügbar; die Konfiguration wird bei jedem Lauf idempotent angelegt.
if command -v logrotate &>/dev/null; then
  cat > /etc/logrotate.d/oxicloud-install <<'EOF'
/var/log/oxicloud-install.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  copytruncate
}
EOF
fi

exec > >(tee -a "${LOG_FILE}") 2>&1
echo ""
echo "===== Install-Lauf gestartet: $(date '+%Y-%m-%d %H:%M:%S') (Script-Version ${SCRIPT_VERSION}) ====="

# ---- Backup-Helfer: legt vor jedem Überschreiben eine Zeitstempel-Kopie an -
backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    local backup_dir="$(dirname "${file}")/backups"
    mkdir -p "${backup_dir}"
    local ts="$(date '+%Y%m%d-%H%M%S')"
    local backup_path="${backup_dir}/$(basename "${file}").${ts}.bak"
    cp -p "${file}" "${backup_path}"
    echo "    Backup angelegt: ${backup_path}"
  fi
}

# ---- Ressourcen-Hinweis für den Kompiliervorgang ---------------------------
RECOMMENDED_BUILD_CPUS=4
RECOMMENDED_BUILD_RAM_GB=16
RECOMMENDED_BUILD_DISK_GB=20
ACTUAL_CPUS="$(nproc)"
ACTUAL_RAM_GB="$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024))"
ACTUAL_DISK_GB="$(df --output=avail -BG "${OXICLOUD_HOME%/*}" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"

echo "======================================================================"
echo " Ressourcenbedarf zum Kompilieren (Rust LTO + Node/Vite-Frontend-Build):"
echo "   Empfohlen: ${RECOMMENDED_BUILD_CPUS}+ CPU-Kerne, ${RECOMMENDED_BUILD_RAM_GB}+ GB RAM, ~${RECOMMENDED_BUILD_DISK_GB} GB freier Speicher"
echo "   Erkannt:   ${ACTUAL_CPUS} CPU-Kern(e), ca. ${ACTUAL_RAM_GB} GB RAM, ca. ${ACTUAL_DISK_GB} GB frei unter ${OXICLOUD_HOME%/*}"
echo ""
echo "   Grund: 'cargo build --release' mit LTO + codegen-units=1 + target-cpu=native"
echo "   ist die speicherhungrigste Kompilier-Konfiguration, v.a. wegen des"
echo "   umfangreichen Dependency-Sets (AWS/Azure SDKs, Tantivy, Bildverarbeitung)."
echo "   Zu wenig RAM führt typischerweise zu einem vom OOM-Killer abgebrochenen"
echo "   Build (Fehler: 'signal: 9, SIGKILL')."
echo ""
echo "   Nach erfolgreichem Build können CPU/RAM wieder auf den für den reinen"
echo "   Betrieb nötigen Umfang zurückgestellt werden (z.B. 2 CPU-Kerne / 3 GB RAM)."
if [[ "${ACTUAL_CPUS}" -lt "${RECOMMENDED_BUILD_CPUS}" || "${ACTUAL_RAM_GB}" -lt "${RECOMMENDED_BUILD_RAM_GB}" || "${ACTUAL_DISK_GB}" -lt "${RECOMMENDED_BUILD_DISK_GB}" ]]; then
  echo ""
  echo "   ACHTUNG: Aktuelle Ressourcen liegen unter der Empfehlung - der Build"
  echo "   könnte fehlschlagen (v.a. bei RAM oder Speicherplatz)."
fi
echo "======================================================================"
echo ""

# ---- Harter Abbruch bei kritisch wenig Diskspace ---------------------------
# Bisher gab es nur die Warnung oben, der Build lief trotzdem an und scheiterte
# dann oft erst mitten in "cargo build" (schlechtester Zeitpunkt: viel Zeit
# investiert, Log unübersichtlich). Ein harter Schwellwert deutlich unter der
# Empfehlung bricht stattdessen sofort und mit klarer Meldung ab.
DISK_ABORT_THRESHOLD_GB=5
if [[ "${ACTUAL_DISK_GB}" -lt "${DISK_ABORT_THRESHOLD_GB}" ]]; then
  echo "FEHLER: Nur noch ca. ${ACTUAL_DISK_GB} GB frei unter ${OXICLOUD_HOME%/*}" >&2
  echo "(kritischer Schwellwert: ${DISK_ABORT_THRESHOLD_GB} GB). Breche vor dem Build ab," >&2
  echo "um einen mittendrin abgebrochenen 'cargo build' durch vollgelaufene Platte zu vermeiden." >&2
  echo "Bitte zuerst Speicherplatz freigeben (z.B. alte Releases unter ${RELEASES_DIR}," >&2
  echo "alte DB-Backups unter /etc/oxicloud/db-backups, apt-get clean) und erneut versuchen." >&2
  exit 1
fi

# ---- Automatischer Swapfile als OOM-Schutz, falls nötig --------------------
SWAP_FILE="/swapfile"
SWAP_SIZE_GB=8
SWAP_AUTO_CREATED=0

if [[ "${ACTUAL_RAM_GB}" -lt "${RECOMMENDED_BUILD_RAM_GB}" ]] && ! swapon --show | grep -q .; then
  echo "==> Wenig RAM erkannt und kein Swap aktiv: lege automatisch einen ${SWAP_SIZE_GB} GB Swapfile an (${SWAP_FILE})..."
  if [[ -f "${SWAP_FILE}" ]]; then
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}" &>/dev/null || true
    swapon "${SWAP_FILE}"
  else
    fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}"
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
    swapon "${SWAP_FILE}"
  fi
  grep -q "^${SWAP_FILE} " /etc/fstab 2>/dev/null || { backup_file "/etc/fstab"; echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab; }
  SWAP_AUTO_CREATED=1
  echo "    >>> WICHTIG: Swapfile wurde automatisch angelegt und aktiviert (als OOM-Schutz beim Kompilieren)."
  echo "    >>> Er wurde auch dauerhaft in /etc/fstab eingetragen, übersteht also einen Neustart."
  echo "    >>> Entfernen, falls nicht gewünscht: swapoff ${SWAP_FILE} && rm ${SWAP_FILE}"
  echo "    >>> und die entsprechende Zeile aus /etc/fstab löschen."
  echo ""
fi

echo "==> Preflight-Check: prüfe Basis-Pakete und installiere fehlende nach..."
# Fix (1.12): "sudo" gehörte bisher NICHT zu dieser Liste, obwohl das Script
# ab dem PostgreSQL-Abschnitt weiter unten durchgängig "sudo -u ..." nutzt.
# Auf minimalen LXC-Templates (z.B. offizielle Proxmox-Debian-Templates) ist
# "sudo" oft nicht vorinstalliert - der erste "sudo"-Aufruf scheiterte dort
# bislang mit "command not found". Jetzt wird es hier mit installiert, noch
# bevor es das erste Mal gebraucht wird.
REQUIRED_APT_PACKAGES=(sudo git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
MISSING_PACKAGES=()
for pkg in "${REQUIRED_APT_PACKAGES[@]}"; do
  dpkg -s "${pkg}" &>/dev/null || MISSING_PACKAGES+=("${pkg}")
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
  echo "    Fehlende Pakete werden installiert: ${MISSING_PACKAGES[*]}"
  apt-get update -y
  apt-get install -y "${MISSING_PACKAGES[@]}"
else
  echo "    Alle benötigten Basis-Pakete sind bereits installiert."
fi

if [[ -n "${NODE_VERSION_PIN}" ]]; then
  echo "==> Node.js-Version ist festgenagelt auf ${NODE_VERSION_PIN}.x"
  LATEST_LTS_MAJOR="${NODE_VERSION_PIN}"
else
  echo "==> Ermittle aktuelle Node.js LTS-Version..."
  # Fix (1.11): war eine plain Command-Substitution mit Pipe unter
  # "set -e -o pipefail" OHNE Absicherung - schlug curl fehl, beendete sich
  # das GANZE Skript sofort und stillschweigend an dieser Zeile, der
  # Fallback direkt darunter wurde nie erreicht. "|| true" am Ende erzwingt
  # einen Exit-Code 0 für die gesamte Pipe, LATEST_LTS_MAJOR bleibt dann
  # einfach leer und der folgende Fallback greift wie vorgesehen.
  LATEST_LTS_MAJOR="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | jq -r '[.[] | select(.lts != false)][0].version' 2>/dev/null | sed 's/^v//' | cut -d. -f1)" || true

  if [[ -z "${LATEST_LTS_MAJOR}" ]]; then
    echo "    Konnte aktuelle Node.js-Version nicht ermitteln, falle zurück auf Node 24." >&2
    LATEST_LTS_MAJOR=24
  fi
fi

CURRENT_NODE_MAJOR="0"
if command -v node &>/dev/null; then
  CURRENT_NODE_MAJOR="$(node -v | sed 's/v//;s/\..*//')"
fi

if [[ "${CURRENT_NODE_MAJOR}" -ne "${LATEST_LTS_MAJOR}" ]]; then
  echo "    Installiere Node.js ${LATEST_LTS_MAJOR}.x (aktuell: ${CURRENT_NODE_MAJOR:-keine})..."
  curl -fsSL "https://deb.nodesource.com/setup_${LATEST_LTS_MAJOR}.x" | bash -
  apt-get install -y nodejs
else
  echo "    Node.js ${CURRENT_NODE_MAJOR}.x ist bereits die aktuelle LTS-Major-Version, prüfe auf Patch-Updates..."
  apt-get update -y
  apt-get install --only-upgrade -y nodejs
fi

echo "==> Stelle sicher, dass PostgreSQL läuft..."
systemctl enable --now postgresql

echo "==> Ermittle/erzeuge DB-Passwort (bleibt über mehrere Läufe hinweg stabil)..."
DB_PASS_FILE="/etc/oxicloud/.db_password"
mkdir -p /etc/oxicloud
if [[ -f "${DB_PASS_FILE}" ]]; then
  DB_PASS="$(cat "${DB_PASS_FILE}")"
  DB_PASS_IS_NEW=0
else
  DB_PASS="$(openssl rand -hex 16)"
  DB_PASS_IS_NEW=1
fi

echo "==> Lege PostgreSQL-Rolle und Datenbank an (falls noch nicht vorhanden)..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

# Fix (1.11): Passwort bei JEDEM Lauf durchsetzen, nicht nur beim erstmaligen
# Anlegen der Rolle. Ohne das konnte die Rolle bereits mit einem ANDEREN
# Passwort existieren (z.B. nach einem abgebrochenen vorherigen Lauf oder
# einer wiederhergestellten Datenbank) als in .db_password gespeichert -
# das fiel dann erst bei sqlx/dem laufenden Dienst mit einem kryptischen
# Auth-Fehler auf. ALTER ROLE ist idempotent und stört nicht, falls das
# Passwort ohnehin schon übereinstimmt.
echo "==> Stelle sicher, dass das DB-Passwort mit ${DB_PASS_FILE} übereinstimmt..."
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null

if [[ "${DB_PASS_IS_NEW}" -eq 1 ]]; then
  echo -n "${DB_PASS}" > "${DB_PASS_FILE}"
  chmod 600 "${DB_PASS_FILE}"
fi

DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}"

# Fix (1.11): expliziter Verbindungstest MIT der tatsächlichen Ziel-DB und
# dem Passwort aus DATABASE_URL - fängt Auth-/Netzwerkprobleme sofort mit
# klarer Meldung ab, statt erst beim späteren "sqlx migrate run" oder beim
# Dienststart kryptisch zu scheitern.
echo "==> Teste Datenbankverbindung mit den ermittelten Zugangsdaten..."
if ! PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
  echo "FEHLER: Verbindung zur Datenbank '${DB_NAME}' als '${DB_USER}' schlägt fehl," >&2
  echo "obwohl Rolle/Datenbank/Passwort gerade eben gesetzt wurden." >&2
  echo "Mögliche Ursachen: PostgreSQL-Authentifizierungsmethode in pg_hba.conf" >&2
  echo "erlaubt kein Passwort-Login für 'localhost' (z.B. 'peer' statt 'md5'/'scram-sha-256')." >&2
  echo "Prüfen: cat /etc/postgresql/*/main/pg_hba.conf | grep -v '^#'" >&2
  exit 1
fi
echo "    Datenbankverbindung erfolgreich verifiziert."

echo "==> Lege Systembenutzer '${OXICLOUD_USER}' an..."
id -u "${OXICLOUD_USER}" &>/dev/null || useradd -r -M -d "${OXICLOUD_HOME}" -s /usr/sbin/nologin "${OXICLOUD_USER}"

mkdir -p "${OXICLOUD_HOME}"
echo "==> Stelle sicher, dass ${OXICLOUD_HOME} durchgängig ${OXICLOUD_USER}:${OXICLOUD_USER} gehört..."
chown -R "${OXICLOUD_USER}:${OXICLOUD_USER}" "${OXICLOUD_HOME}"

echo "==> Klone/aktualisiere OxiCloud in ${OXICLOUD_HOME}..."
NEED_BUILD=0

resolve_target_ref() {
  if [[ -z "${OXICLOUD_VERSION_PIN}" ]]; then
    echo "main"
  elif [[ "${OXICLOUD_VERSION_PIN}" == "latest" ]]; then
    local tag
    tag="$(curl -fsSL https://api.github.com/repos/AtalayaLabs/OxiCloud/releases/latest | jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
      echo "Fehler: Konnte neuestes GitHub-Release nicht ermitteln (API nicht erreichbar oder keine Releases vorhanden)." >&2
      return 1
    fi
    echo "${tag}"
  else
    echo "${OXICLOUD_VERSION_PIN}"
  fi
}

TARGET_REF="$(resolve_target_ref)" || exit 1
if [[ "${OXICLOUD_VERSION_PIN}" == "latest" ]]; then
  echo "    OXICLOUD_VERSION_PIN=latest -> aktuell aufgelöst zu Release: ${TARGET_REF}"
elif [[ -n "${OXICLOUD_VERSION_PIN}" ]]; then
  echo "    OXICLOUD_VERSION_PIN gesetzt auf festen Tag: ${TARGET_REF}"
else
  echo "    Kein Pin gesetzt, folge dem main-Branch (Entwicklungsversion)."
fi

if [[ ! -d "${OXICLOUD_HOME}/.git" ]]; then
  if [[ -n "$(ls -A "${OXICLOUD_HOME}" 2>/dev/null)" ]]; then
    echo "    Verzeichnis ${OXICLOUD_HOME} ist nicht leer, aber noch kein Git-Repo - leere es vor dem Klonen..."
    find "${OXICLOUD_HOME}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
  sudo -u "${OXICLOUD_USER}" git clone "${REPO_URL}" "${OXICLOUD_HOME}"
  OLD_REV="none"
else
  OLD_REV="$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" rev-parse HEAD)"
  echo "    Repo existiert bereits, hole Updates (inkl. Tags)..."
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" fetch --tags --force origin

  if [[ -n "$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" status --porcelain --untracked-files=no)" ]]; then
    echo "    WARNUNG: Lokale, nicht committete Änderungen an getrackten Dateien gefunden."
    echo "    /opt/oxicloud soll ausschließlich vom Script verwaltet werden - sichere die"
    echo "    Änderungen als Patch und verwerfe sie, damit Checkout/Pull sauber laufen kann."
    PATCH_DIR="${OXICLOUD_HOME}/local-changes-backup"
    mkdir -p "${PATCH_DIR}"
    chown "${OXICLOUD_USER}:${OXICLOUD_USER}" "${PATCH_DIR}"
    PATCH_FILE="${PATCH_DIR}/discarded-$(date '+%Y%m%d-%H%M%S').patch"
    sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" diff > "${PATCH_FILE}"
    echo "    Patch gesichert unter: ${PATCH_FILE}"
    sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" reset --hard HEAD
  fi
fi

if [[ "${TARGET_REF}" == "main" ]]; then
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" checkout main
  # Statt "git pull origin main": passend zur Philosophie weiter oben, dass
  # /opt/oxicloud ausschließlich vom Script verwaltet wird, hier konsequent
  # "fetch + reset --hard" statt "pull". "pull" kann an einem divergierten
  # main scheitern (z.B. nach einem Force-Push upstream); "reset --hard"
  # erzwingt immer den exakten Stand von origin/main, unabhängig von der
  # lokalen Historie.
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" fetch origin main
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" reset --hard origin/main
else
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" checkout "${TARGET_REF}" \
    || { echo "Fehler: Tag/Referenz '${TARGET_REF}' existiert nicht im Repository." >&2; exit 1; }
fi

NEW_REV="$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" rev-parse HEAD)"
if [[ "${OLD_REV}" != "${NEW_REV}" ]]; then
  echo "    Änderung erkannt (${OLD_REV:0:8} -> ${NEW_REV:0:8}), Rebuild erforderlich."
  NEED_BUILD=1
else
  echo "    Keine Änderung gegenüber letztem Lauf, überspringe Rebuild."
fi

# Falls die aktuelle Binary fehlt (z.B. vorheriger Build abgebrochen), trotzdem bauen
if [[ ! -e "${CURRENT_LINK}" ]]; then
  NEED_BUILD=1
fi

echo "==> Installiere/aktualisiere Rust (rustup) für Benutzer ${OXICLOUD_USER}..."
if ! sudo -u "${OXICLOUD_USER}" bash -c 'command -v cargo' &>/dev/null; then
  sudo -u "${OXICLOUD_USER}" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
fi
RUSTUP_ENV="${OXICLOUD_HOME}/.cargo/env"

OLD_RUST_VERSION="$(sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo --version" 2>/dev/null || echo "none")"

if [[ -n "${RUST_VERSION_PIN}" ]]; then
  echo "    Rust-Version ist festgenagelt auf ${RUST_VERSION_PIN}"
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && rustup toolchain install ${RUST_VERSION_PIN} && rustup default ${RUST_VERSION_PIN}"
else
  echo "    Prüfe auf Rust-Updates (rustup update stable)..."
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && rustup update stable && rustup default stable"
fi

NEW_RUST_VERSION="$(sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo --version")"

if [[ "${OLD_RUST_VERSION}" != "${NEW_RUST_VERSION}" ]]; then
  echo "    Rust-Toolchain hat sich geändert (${OLD_RUST_VERSION} -> ${NEW_RUST_VERSION}), Rebuild erforderlich."
  NEED_BUILD=1
fi

echo "==> Prüfe, ob sqlx-cli (für Datenbank-Migrationen) installiert ist..."
if ! sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && command -v sqlx" &>/dev/null; then
  echo "    sqlx-cli nicht gefunden, installiere es (kann einige Minuten dauern)..."
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo install sqlx-cli --no-default-features --features rustls,postgres"
else
  echo "    sqlx-cli ist bereits installiert."
fi

# ---- Build-Features (z.B. Plugins) - Änderung erfordert Rebuild -----------
BUILD_FEATURES=""
if [[ "${ENABLE_PLUGINS}" == "true" ]]; then
  BUILD_FEATURES="--features plugins"
fi

FEATURES_STATE_FILE="/etc/oxicloud/.build_features"
mkdir -p /etc/oxicloud
PREV_FEATURES="$(cat "${FEATURES_STATE_FILE}" 2>/dev/null || echo "")"
if [[ "${BUILD_FEATURES}" != "${PREV_FEATURES}" ]]; then
  echo "    Build-Features geändert ('${PREV_FEATURES}' -> '${BUILD_FEATURES}'), Rebuild erforderlich."
  NEED_BUILD=1
fi

# ---- Build-Erfolgs-Marker: erkennt fehlgeschlagene/unterbrochene Builds ----
# Wird NUR geschrieben, wenn Frontend+Rust-Build vollständig durchgelaufen sind.
# Falls ein vorheriger Lauf mittendrin abgebrochen ist (z.B. EACCES beim
# Frontend-Build), aber sich Commit/Toolchain/Features seither nicht mehr
# geändert haben, würde das Script sonst fälschlich "keine Änderung" melden
# und den (fehlenden oder veralteten) Build überspringen.
BUILD_MARKER_FILE="/etc/oxicloud/.last_build_ok"
EXPECTED_MARKER="${NEW_REV}|${BUILD_FEATURES}"
LAST_BUILD_OK="$(cat "${BUILD_MARKER_FILE}" 2>/dev/null || echo "")"
if [[ "${LAST_BUILD_OK}" != "${EXPECTED_MARKER}" ]]; then
  echo "    Letzter erfolgreicher Build passt nicht zum aktuellen Stand (Commit/Features), Rebuild erforderlich."
  NEED_BUILD=1
fi

echo "==> Erzeuge Konfigurationsverzeichnis /etc/oxicloud und .env..."
CONFIG_DIR="/etc/oxicloud"
STORAGE_DIR="/mnt/oxicloud-data/storage"
STATIC_DIR="${OXICLOUD_HOME}/static"

mkdir -p "${CONFIG_DIR}"
if [[ ! -f "${CONFIG_DIR}/.env" ]]; then
  cp "${OXICLOUD_HOME}/example.env" "${CONFIG_DIR}/.env"
else
  echo "    Prüfe example.env auf neue Variablen, die in der bestehenden .env noch fehlen..."
  ADDED_KEYS=()
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    [[ -z "${key}" || "${key}" == "${line}" ]] && continue
    if ! grep -q "^${key}=" "${CONFIG_DIR}/.env"; then
      ADDED_KEYS+=("${key}=${line#*=}")
    fi
  done < "${OXICLOUD_HOME}/example.env"

  if [[ ${#ADDED_KEYS[@]} -gt 0 ]]; then
    backup_file "${CONFIG_DIR}/.env"
    {
      echo ""
      echo "# --- Automatisch ergänzt aus example.env am $(date '+%Y-%m-%d %H:%M:%S') ---"
      printf '%s\n' "${ADDED_KEYS[@]}"
    } >> "${CONFIG_DIR}/.env"
    echo "    Neue Variablen ergänzt (${#ADDED_KEYS[@]}): $(printf '%s ' "${ADDED_KEYS[@]%%=*}")"
  else
    echo "    Keine neuen Variablen gefunden, .env bereits vollständig."
  fi
fi

mkdir -p "${STORAGE_DIR}"
chown -R "${OXICLOUD_USER}:${OXICLOUD_USER}" "${STORAGE_DIR}"

if ! mountpoint -q /mnt; then
  echo "    Hinweis: /mnt scheint kein eigener Mountpoint (keine separate Platte/Partition) zu sein."
  echo "    ${STORAGE_DIR} liegt damit trotz Trennung im Verzeichnisbaum physisch auf derselben Platte wie das OS."
  echo "    Falls gewünscht: separate Platte/Partition vorher unter /mnt einhängen (z.B. via /etc/fstab), dann Script erneut ausführen."
fi

# Setze/ersetze relevante Variablen in .env (DB, Storage- und Static-Pfad absolut machen)
set_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

backup_file "${CONFIG_DIR}/.env"
set_env_var "OXICLOUD_DB_CONNECTION_STRING" "${DATABASE_URL}" "${CONFIG_DIR}/.env"
# Fix (1.11): DATABASE_URL zusätzlich in die (chmod 640, root:oxicloud
# geschützte) .env schreiben, statt sie später im systemd-Unit-File inline
# als "Environment=DATABASE_URL=..." abzulegen. Unit-Files unter
# /etc/systemd/system/ sind standardmäßig 644 (für ALLE lokalen User
# lesbar) - das Passwort wäre damit trivial auslesbar gewesen
# ("cat /etc/systemd/system/oxicloud.service" bzw. "systemctl show").
set_env_var "DATABASE_URL" "${DATABASE_URL}" "${CONFIG_DIR}/.env"
set_env_var "OXICLOUD_STORAGE_PATH" "${STORAGE_DIR}" "${CONFIG_DIR}/.env"
set_env_var "OXICLOUD_STATIC_PATH" "${STATIC_DIR}" "${CONFIG_DIR}/.env"

if [[ "${ENABLE_PLUGINS}" == "true" ]]; then
  set_env_var "OXICLOUD_ENABLE_PLUGINS" "true" "${CONFIG_DIR}/.env"
  echo "    OXICLOUD_ENABLE_PLUGINS gesetzt auf: true (Cargo-Feature 'plugins' wurde/wird mitgebaut)"
else
  echo "    Plugins deaktiviert (Standard) - OXICLOUD_ENABLE_PLUGINS unverändert gelassen"
fi

if [[ -n "${ENV_OVERRIDE_SERVER_HOST}" ]]; then
  set_env_var "OXICLOUD_SERVER_HOST" "${ENV_OVERRIDE_SERVER_HOST}" "${CONFIG_DIR}/.env"
  echo "    OXICLOUD_SERVER_HOST gesetzt auf: ${ENV_OVERRIDE_SERVER_HOST}"

  if [[ "${ENV_OVERRIDE_SERVER_HOST}" == "0.0.0.0" || "${ENV_OVERRIDE_SERVER_HOST}" == "::" ]]; then
    echo "    HINWEIS: Dienst lauscht auf allen Interfaces (${ENV_OVERRIDE_SERVER_HOST}:${OXICLOUD_PORT})."
    if command -v ufw &>/dev/null; then
      if ! ufw status | grep -qE "^${OXICLOUD_PORT}(/tcp)?[[:space:]]+ALLOW"; then
        echo "    ACHTUNG: ufw ist aktiv, aber Port ${OXICLOUD_PORT}/tcp scheint dort nicht"
        echo "    freigegeben zu sein. Ohne separate Freigabe sollte der Port also NICHT von"
        echo "    außen erreichbar sein - falls du das aber (z.B. übers LAN) doch willst:"
        echo "    'ufw allow ${OXICLOUD_PORT}/tcp'. Falls du NICHT willst, dass der Port offen"
        echo "    ins Internet zeigt, jetzt prüfen (z.B. Router-Portweiterleitung, Cloud-"
        echo "    Security-Group), dass er wirklich nur intern erreichbar ist."
      fi
    else
      echo "    Konnte 'ufw' nicht finden, um die Firewall-Regeln zu prüfen. Bitte manuell"
      echo "    sicherstellen (z.B. über nftables/iptables oder Cloud-Security-Group), dass"
      echo "    Port ${OXICLOUD_PORT}/tcp nicht versehentlich offen ins Internet zeigt."
    fi
  fi
else
  echo "    OXICLOUD_SERVER_HOST unverändert gelassen (Standardwert aus example.env)"
fi

if [[ -n "${ENV_OVERRIDE_BASE_URL}" ]]; then
  set_env_var "OXICLOUD_BASE_URL" "${ENV_OVERRIDE_BASE_URL}" "${CONFIG_DIR}/.env"
  echo "    OXICLOUD_BASE_URL gesetzt auf: ${ENV_OVERRIDE_BASE_URL}"
else
  echo "    OXICLOUD_BASE_URL unverändert gelassen (Standardwert aus example.env)"
fi

chown root:"${OXICLOUD_USER}" "${CONFIG_DIR}/.env"
chmod 640 "${CONFIG_DIR}/.env"

echo "==> Erstelle Datenbank-Backup vor der Migration..."
# "cargo sqlx migrate run" lief bisher bei JEDEM Lauf ohne vorheriges Backup -
# eine schlecht getestete Migration (z.B. aus einem neuen Release) kann sonst
# Daten unwiederbringlich zerstören. Ein Dump direkt davor macht das reversibel.
DB_BACKUP_DIR="/etc/oxicloud/db-backups"
DB_BACKUP_KEEP=10
mkdir -p "${DB_BACKUP_DIR}"
DB_BACKUP_FILE="${DB_BACKUP_DIR}/${DB_NAME}-$(date '+%Y%m%d-%H%M%S').sql.gz"
if sudo -u postgres pg_dump "${DB_NAME}" | gzip > "${DB_BACKUP_FILE}"; then
  chmod 600 "${DB_BACKUP_FILE}"
  echo "    Backup angelegt: ${DB_BACKUP_FILE}"
else
  echo "FEHLER: Datenbank-Backup ist fehlgeschlagen, breche vor der Migration sicherheitshalber ab." >&2
  rm -f "${DB_BACKUP_FILE}"
  exit 1
fi

if [[ "${DB_BACKUP_KEEP}" -gt 0 ]]; then
  BACKUP_COUNT="$(find "${DB_BACKUP_DIR}" -maxdepth 1 -type f -name "${DB_NAME}-*.sql.gz" | wc -l)"
  if [[ "${BACKUP_COUNT}" -gt "${DB_BACKUP_KEEP}" ]]; then
    echo "    Bereinige alte DB-Backups (behalte die neuesten ${DB_BACKUP_KEEP})..."
    find "${DB_BACKUP_DIR}" -maxdepth 1 -type f -name "${DB_NAME}-*.sql.gz" -printf '%T@ %p\n' \
      | sort -rn | tail -n +"$((DB_BACKUP_KEEP + 1))" | cut -d' ' -f2- \
      | while IFS= read -r old_backup; do rm -f "${old_backup}"; done
  fi
fi

echo "==> Führe ausstehende Datenbank-Migrationen aus (sqlx migrate run)..."
sudo -u "${OXICLOUD_USER}" bash -c "
  source '${RUSTUP_ENV}'
  cd '${OXICLOUD_HOME}'
  export DATABASE_URL='${DATABASE_URL}'
  cargo sqlx migrate run
"

echo "==> Verifiziere, dass alle benötigten Programme tatsächlich verfügbar sind..."
for cmd in git curl jq openssl psql; do
  command -v "${cmd}" &>/dev/null || { echo "Fehler: '${cmd}' ist trotz Installationsversuch nicht verfügbar." >&2; exit 1; }
done
command -v node &>/dev/null || { echo "Fehler: 'node' ist nicht verfügbar." >&2; exit 1; }
command -v npm  &>/dev/null || { echo "Fehler: 'npm' ist nicht verfügbar." >&2; exit 1; }
sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && command -v cargo" &>/dev/null \
  || { echo "Fehler: 'cargo' ist für Benutzer ${OXICLOUD_USER} nicht verfügbar." >&2; exit 1; }
echo "    Alle Abhängigkeiten sind vorhanden."

if [[ "${NEED_BUILD}" -eq 1 ]]; then
  echo "==> Baue das Frontend (npm)..."
  sudo -u "${OXICLOUD_USER}" bash -c "
    cd '${OXICLOUD_HOME}/frontend'
    npm ci
    npm run build
  "

  echo "==> Baue OxiCloud im Release-Modus (das kann einige Minuten dauern)..."
  sudo -u "${OXICLOUD_USER}" bash -c "
    source '${RUSTUP_ENV}'
    cd '${OXICLOUD_HOME}'
    export DATABASE_URL='${DATABASE_URL}'
    cargo build --release --locked ${BUILD_FEATURES}
  "

  echo -n "${BUILD_FEATURES}" > "${FEATURES_STATE_FILE}"

  echo "==> Versioniere Binary nach Git-Commit-Hash..."
  GIT_HASH_SHORT="$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" rev-parse --short HEAD)"
  RELEASE_BIN="${RELEASES_DIR}/oxicloud-${GIT_HASH_SHORT}"

  sudo -u "${OXICLOUD_USER}" mkdir -p "${RELEASES_DIR}"
  sudo -u "${OXICLOUD_USER}" cp "${OXICLOUD_HOME}/target/release/oxicloud" "${RELEASE_BIN}"
  chmod 755 "${RELEASE_BIN}"
  sudo -u "${OXICLOUD_USER}" ln -sfn "${RELEASE_BIN}" "${CURRENT_LINK}"
  echo "    Neue Binary: ${RELEASE_BIN}"
  echo "    'current' zeigt jetzt darauf: ${CURRENT_LINK} -> ${RELEASE_BIN}"

  echo -n "${NEW_REV}|${BUILD_FEATURES}" > "${BUILD_MARKER_FILE}"

  if [[ "${KEEP_RELEASES}" -gt 0 ]]; then
    ACTIVE_RELEASE="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || echo "")"
    RELEASE_COUNT="$(find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' | wc -l)"
    if [[ "${RELEASE_COUNT}" -gt "${KEEP_RELEASES}" ]]; then
      echo "    Bereinige alte Releases (behalte die neuesten ${KEEP_RELEASES}, aktive Version bleibt immer erhalten)..."
      find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' -printf '%T@ %p\n' \
        | sort -rn | tail -n +"$((KEEP_RELEASES + 1))" | cut -d' ' -f2- \
        | while IFS= read -r old_release; do
            [[ "${old_release}" == "${ACTIVE_RELEASE}" ]] && continue
            rm -f "${old_release}"
          done
    fi
  fi
else
  echo "==> Überspringe Frontend- und Release-Build (keine Änderungen seit letztem Lauf)."
fi

BIN_PATH="${CURRENT_LINK}"
if [[ ! -e "${BIN_PATH}" ]]; then
  echo "Fehler: Binary wurde nicht unter ${BIN_PATH} gefunden. Build vermutlich fehlgeschlagen." >&2
  exit 1
fi

echo "==> Richte systemd-Service ein..."
backup_file "/etc/systemd/system/oxicloud.service"
cat > /etc/systemd/system/oxicloud.service <<EOF
[Unit]
Description=OxiCloud - self-hosted cloud storage
After=network.target postgresql.service
# Requires= (statt Wants=) ist eine bewusste harte Abhängigkeit: startet
# Postgres nicht/bricht ab, startet OxiCloud ebenfalls nicht. Falls euch das
# zu strikt ist (z.B. Postgres läuft auf einem anderen Host und ist beim
# Boot kurzzeitig noch nicht erreichbar), auf "Wants=" umstellen.
Requires=postgresql.service

[Service]
Type=simple
User=${OXICLOUD_USER}
WorkingDirectory=${OXICLOUD_HOME}
EnvironmentFile=/etc/oxicloud/.env
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=5

# Hardening: OXICLOUD_HOME liegt unter /opt, ProtectHome betrifft nur
# /home, /root, /run/user und bleibt daher hier ohne Nebenwirkung.
# ReadWritePaths deckt Storage sowie releases/ + current-Symlink ab, falls
# die Anwendung selbst noch etwas dort ablegt (z.B. Cache/Thumbnails).
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${STORAGE_DIR} ${OXICLOUD_HOME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if [[ "${NEED_BUILD}" -eq 1 ]]; then
  systemctl enable oxicloud
  systemctl restart oxicloud
  echo "    Dienst wurde neu gestartet (neues Binary)."
else
  systemctl enable --now oxicloud
  echo "    Dienst läuft bereits / wurde gestartet, kein Neustart nötig."
fi

# ---- Health-Check + automatisches Rollback ---------------------------------
# Ihr versioniert Releases zwar sauber unter releases/ mit "current"-Symlink,
# aber bislang wird das nie genutzt: crasht der Dienst nach einem Rebuild
# (kaputte Migration, Laufzeitfehler, fehlende Datei), blieb "current" bisher
# einfach auf dem defekten Release stehen. Nur relevant, wenn gerade neu
# gebaut/gestartet wurde UND es überhaupt ein vorheriges Release gibt, auf
# das zurückgerollt werden könnte.
if [[ "${NEED_BUILD}" -eq 1 && "${OLD_REV}" != "none" ]]; then
  echo "==> Prüfe, ob der Dienst nach dem Neustart tatsächlich läuft und antwortet..."
  HEALTH_RETRIES=10
  HEALTH_OK=0
  for i in $(seq 1 "${HEALTH_RETRIES}"); do
    sleep 2
    if systemctl is-active --quiet oxicloud && \
       curl -fsS "http://127.0.0.1:${OXICLOUD_PORT}/" >/dev/null 2>&1; then
      HEALTH_OK=1
      break
    fi
  done

  if [[ "${HEALTH_OK}" -eq 1 ]]; then
    echo "    Health-Check erfolgreich, Dienst antwortet auf Port ${OXICLOUD_PORT}."
  else
    echo "FEHLER: Dienst antwortet nach ${HEALTH_RETRIES} Versuchen (je 2s) nicht auf Port ${OXICLOUD_PORT}." >&2
    echo "    Prüfe: journalctl -u oxicloud -n 50 --no-pager" >&2
    journalctl -u oxicloud -n 50 --no-pager >&2 || true

    PREV_BIN="$(find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' \
      ! -name "oxicloud-${GIT_HASH_SHORT}" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"

    if [[ -n "${PREV_BIN}" ]]; then
      echo "    Rolle automatisch zurück auf vorheriges Release: ${PREV_BIN}" >&2
      ln -sfn "${PREV_BIN}" "${CURRENT_LINK}"
      systemctl restart oxicloud
      sleep 3
      if systemctl is-active --quiet oxicloud; then
        echo "    Rollback erfolgreich, Dienst läuft wieder mit ${PREV_BIN}." >&2
      else
        echo "    ACHTUNG: Auch das vorherige Release startet nicht sauber. Manueller Eingriff nötig!" >&2
      fi
    else
      echo "    Kein vorheriges Release zum Zurückrollen gefunden. Manueller Eingriff nötig!" >&2
    fi
    ROLLBACK_TRIGGERED=1
    exit 1
  fi
fi

echo ""
echo "======================================================================"
echo " OxiCloud wurde installiert und gestartet."
echo " (Script-Version: ${SCRIPT_VERSION})"
echo ""
echo " URL:               http://$(hostname -I | awk '{print $1}'):${OXICLOUD_PORT}"
echo " Installationspfad: ${OXICLOUD_HOME}"
echo " Konfiguration:     /etc/oxicloud/.env"
echo " Aktives Release:   $(readlink -f "${CURRENT_LINK}" 2>/dev/null || echo "unbekannt")"
echo " OxiCloud-Version:  $( [[ -z "${OXICLOUD_VERSION_PIN}" ]] && echo "main-Branch (${NEW_REV:0:8})" || echo "${TARGET_REF} (${NEW_REV:0:8})" )"
echo " Plugins:           $( [[ "${ENABLE_PLUGINS}" == "true" ]] && echo "aktiviert (--features plugins)" || echo "deaktiviert (Standard)" )"
echo " Storage-Pfad:      ${STORAGE_DIR}"
echo " Server-Host:       $( [[ -n "${ENV_OVERRIDE_SERVER_HOST}" ]] && echo "${ENV_OVERRIDE_SERVER_HOST}" || echo "Standard aus example.env" )"
echo " Base-URL:          $( [[ -n "${ENV_OVERRIDE_BASE_URL}" ]] && echo "${ENV_OVERRIDE_BASE_URL}" || echo "Standard aus example.env" )"
echo " Node.js:           $( [[ -n "${NODE_VERSION_PIN}" ]] && echo "gepinnt auf ${NODE_VERSION_PIN}.x" || echo "automatisch neueste LTS (${LATEST_LTS_MAJOR}.x)" )"
echo " Rust:              $( [[ -n "${RUST_VERSION_PIN}" ]] && echo "gepinnt auf ${RUST_VERSION_PIN}" || echo "automatisch neueste stable (${NEW_RUST_VERSION})" )"
echo " Datenbank:         ${DB_NAME} (User: ${DB_USER})"
echo " DB-Passwort:       ${DB_PASS}"
echo ""
echo " (Das Passwort bleibt bei erneuter Ausführung unverändert, gespeichert in ${DB_PASS_FILE})"
echo " Service-Status:    systemctl status oxicloud"
echo " Logs (Service):    journalctl -u oxicloud -f"
echo " Logs (Installation): ${LOG_FILE}"
echo "======================================================================"

if [[ "${NEED_BUILD}" -eq 1 ]]; then
  echo ""
  echo "Hinweis: Der Build ist abgeschlossen. Falls du CPU/RAM für den Build"
  echo "hochgesetzt hattest, kannst du sie jetzt für den reinen Betrieb wieder"
  echo "zurückstellen (Empfehlung: 2 CPU-Kerne / 3 GB RAM genügen zum Laufenlassen)."
fi

if [[ "${SWAP_AUTO_CREATED}" -eq 1 ]]; then
  echo ""
  echo "==> Build erfolgreich abgeschlossen, deaktiviere den automatisch angelegten Swapfile wieder..."
  swapoff "${SWAP_FILE}"
  rm -f "${SWAP_FILE}"
  backup_file "/etc/fstab"
  sed -i "\#^${SWAP_FILE} #d" /etc/fstab
  echo "    Swapfile ${SWAP_FILE} wurde deaktiviert, gelöscht und aus /etc/fstab entfernt."
fi
