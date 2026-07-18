#!/usr/bin/env bash
#
# Native (non-container) install script for OxiCloud
# https://github.com/AtalayaLabs/OxiCloud
#
# Version:          1.11
# Lizenz:           MIT
# Erstellt am:      2026-07-13 15:59 UTC
# Zuletzt geändert: 2026-07-19 UTC (drei Fixes, siehe Changelog)
#
# Changelog:
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
SCRIPT_VERSION="1.11"

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
### ---------------------------------------------------------------------------

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
REQUIRED_APT_PACKAGES=(git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
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
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" pull origin main
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
