#!/usr/bin/env bash
#
# Native (non-container) install script for OxiCloud
# https://github.com/AtalayaLabs/OxiCloud
#
# Version:          1.12
# Lizenz:           MIT
#
# Changelog 1.12:
#   - Fix: "sudo" wurde nicht als benötigtes Paket geführt. Auf minimalen
#     LXC-Templates (z.B. Proxmox-Debian) ist es oft nicht vorinstalliert,
#     wodurch das Script beim ersten "sudo -u ..."-Aufruf mit
#     "command not found" abbrach (Preflight prüfte es bislang nicht mit).
#
set -euo pipefail

### ---- Configuration (adjust as needed) ------------------------------------
OXICLOUD_USER="oxicloud"
OXICLOUD_HOME="/opt/oxicloud"
OXICLOUD_PORT="8086"
DB_NAME="oxicloud"
DB_USER="oxicloud"
REPO_URL="https://github.com/AtalayaLabs/OxiCloud.git"
SCRIPT_VERSION="1.12"
RELEASES_DIR="${OXICLOUD_HOME}/releases"
CURRENT_LINK="${OXICLOUD_HOME}/current"
KEEP_RELEASES=5
NODE_VERSION_PIN=""
RUST_VERSION_PIN=""
ENV_OVERRIDE_SERVER_HOST=""
ENV_OVERRIDE_BASE_URL=""
OXICLOUD_VERSION_PIN=""
ENABLE_PLUGINS=false
### ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root bzw. mit sudo ausführen." >&2
  exit 1
fi

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
echo "======================================================================"
echo ""

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
fi

echo "==> Preflight-Check: prüfe Basis-Pakete und installiere fehlende nach..."
# Fix (1.12): Minimale LXC-Templates (z.B. offizielle Proxmox-Debian-Templates)
# bringen "sudo" oft NICHT vorinstalliert mit - im Gegensatz zu vollwertigen
# VMs/Images wie DietPi. Root zu sein (siehe Check oben) heißt nicht, dass der
# Befehl "sudo" existiert; das Script nutzt "sudo -u ..." aber an sehr vielen
# Stellen (DB-Rolle anlegen, Repo klonen, Rust/Cargo, npm build, ...). Ohne
# dieses Paket schlägt der erste "sudo"-Aufruf mit "command not found" fehl,
# und zwar erst mitten im Lauf (Preflight prüft ja nur die Pakete unten, die
# noch keine "sudo"-Aufrufe brauchen) - daher hier ganz vorne mit aufnehmen.
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
  LATEST_LTS_MAJOR="${NODE_VERSION_PIN}"
else
  echo "==> Ermittle aktuelle Node.js LTS-Version..."
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

echo "==> Stelle sicher, dass das DB-Passwort mit ${DB_PASS_FILE} übereinstimmt..."
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null

if [[ "${DB_PASS_IS_NEW}" -eq 1 ]]; then
  echo -n "${DB_PASS}" > "${DB_PASS_FILE}"
  chmod 600 "${DB_PASS_FILE}"
fi

DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}"

echo "==> Teste Datenbankverbindung mit den ermittelten Zugangsdaten..."
if ! PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
  echo "FEHLER: Verbindung zur Datenbank '${DB_NAME}' als '${DB_USER}' schlägt fehl," >&2
  exit 1
fi
echo "    Datenbankverbindung erfolgreich verifiziert."

echo "==> Lege Systembenutzer '${OXICLOUD_USER}' an..."
id -u "${OXICLOUD_USER}" &>/dev/null || useradd -r -M -d "${OXICLOUD_HOME}" -s /usr/sbin/nologin "${OXICLOUD_USER}"

mkdir -p "${OXICLOUD_HOME}"
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
      echo "Fehler: Konnte neuestes GitHub-Release nicht ermitteln." >&2
      return 1
    fi
    echo "${tag}"
  else
    echo "${OXICLOUD_VERSION_PIN}"
  fi
}

TARGET_REF="$(resolve_target_ref)" || exit 1

if [[ ! -d "${OXICLOUD_HOME}/.git" ]]; then
  if [[ -n "$(ls -A "${OXICLOUD_HOME}" 2>/dev/null)" ]]; then
    find "${OXICLOUD_HOME}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
  sudo -u "${OXICLOUD_USER}" git clone "${REPO_URL}" "${OXICLOUD_HOME}"
  OLD_REV="none"
else
  OLD_REV="$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" rev-parse HEAD)"
  sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" fetch --tags --force origin

  if [[ -n "$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" status --porcelain --untracked-files=no)" ]]; then
    PATCH_DIR="${OXICLOUD_HOME}/local-changes-backup"
    mkdir -p "${PATCH_DIR}"
    chown "${OXICLOUD_USER}:${OXICLOUD_USER}" "${PATCH_DIR}"
    PATCH_FILE="${PATCH_DIR}/discarded-$(date '+%Y%m%d-%H%M%S').patch"
    sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" diff > "${PATCH_FILE}"
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
  NEED_BUILD=1
fi

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
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && rustup toolchain install ${RUST_VERSION_PIN} && rustup default ${RUST_VERSION_PIN}"
else
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && rustup update stable && rustup default stable"
fi

NEW_RUST_VERSION="$(sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo --version")"

if [[ "${OLD_RUST_VERSION}" != "${NEW_RUST_VERSION}" ]]; then
  NEED_BUILD=1
fi

echo "==> Prüfe, ob sqlx-cli (für Datenbank-Migrationen) installiert ist..."
if ! sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && command -v sqlx" &>/dev/null; then
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo install sqlx-cli --no-default-features --features rustls,postgres"
fi

BUILD_FEATURES=""
if [[ "${ENABLE_PLUGINS}" == "true" ]]; then
  BUILD_FEATURES="--features plugins"
fi

FEATURES_STATE_FILE="/etc/oxicloud/.build_features"
mkdir -p /etc/oxicloud
PREV_FEATURES="$(cat "${FEATURES_STATE_FILE}" 2>/dev/null || echo "")"
if [[ "${BUILD_FEATURES}" != "${PREV_FEATURES}" ]]; then
  NEED_BUILD=1
fi

BUILD_MARKER_FILE="/etc/oxicloud/.last_build_ok"
EXPECTED_MARKER="${NEW_REV}|${BUILD_FEATURES}"
LAST_BUILD_OK="$(cat "${BUILD_MARKER_FILE}" 2>/dev/null || echo "")"
if [[ "${LAST_BUILD_OK}" != "${EXPECTED_MARKER}" ]]; then
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
  fi
fi

mkdir -p "${STORAGE_DIR}"
chown -R "${OXICLOUD_USER}:${OXICLOUD_USER}" "${STORAGE_DIR}"

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
set_env_var "DATABASE_URL" "${DATABASE_URL}" "${CONFIG_DIR}/.env"
set_env_var "OXICLOUD_STORAGE_PATH" "${STORAGE_DIR}" "${CONFIG_DIR}/.env"
set_env_var "OXICLOUD_STATIC_PATH" "${STATIC_DIR}" "${CONFIG_DIR}/.env"

if [[ "${ENABLE_PLUGINS}" == "true" ]]; then
  set_env_var "OXICLOUD_ENABLE_PLUGINS" "true" "${CONFIG_DIR}/.env"
fi

if [[ -n "${ENV_OVERRIDE_SERVER_HOST}" ]]; then
  set_env_var "OXICLOUD_SERVER_HOST" "${ENV_OVERRIDE_SERVER_HOST}" "${CONFIG_DIR}/.env"
fi

if [[ -n "${ENV_OVERRIDE_BASE_URL}" ]]; then
  set_env_var "OXICLOUD_BASE_URL" "${ENV_OVERRIDE_BASE_URL}" "${CONFIG_DIR}/.env"
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

  GIT_HASH_SHORT="$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" rev-parse --short HEAD)"
  RELEASE_BIN="${RELEASES_DIR}/oxicloud-${GIT_HASH_SHORT}"

  sudo -u "${OXICLOUD_USER}" mkdir -p "${RELEASES_DIR}"
  sudo -u "${OXICLOUD_USER}" cp "${OXICLOUD_HOME}/target/release/oxicloud" "${RELEASE_BIN}"
  chmod 755 "${RELEASE_BIN}"
  sudo -u "${OXICLOUD_USER}" ln -sfn "${RELEASE_BIN}" "${CURRENT_LINK}"

  echo -n "${NEW_REV}|${BUILD_FEATURES}" > "${BUILD_MARKER_FILE}"

  if [[ "${KEEP_RELEASES}" -gt 0 ]]; then
    ACTIVE_RELEASE="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || echo "")"
    RELEASE_COUNT="$(find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' | wc -l)"
    if [[ "${RELEASE_COUNT}" -gt "${KEEP_RELEASES}" ]]; then
      find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' -printf '%T@ %p\n' \
        | sort -rn | tail -n +"$((KEEP_RELEASES + 1))" | cut -d' ' -f2- \
        | while IFS= read -r old_release; do
            [[ "${old_release}" == "${ACTIVE_RELEASE}" ]] && continue
            rm -f "${old_release}"
          done
    fi
  fi
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
Requires=postgresql.service

[Service]
Type=simple
User=${OXICLOUD_USER}
WorkingDirectory=${OXICLOUD_HOME}
EnvironmentFile=/etc/oxicloud/.env
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=5

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
else
  systemctl enable --now oxicloud
fi

echo ""
echo "======================================================================"
echo " OxiCloud wurde installiert und gestartet."
echo " (Script-Version: ${SCRIPT_VERSION})"
echo " URL:               http://$(hostname -I | awk '{print $1}'):${OXICLOUD_PORT}"
echo " Installationspfad: ${OXICLOUD_HOME}"
echo " Konfiguration:     /etc/oxicloud/.env"
echo " DB-Passwort:       ${DB_PASS}"
echo "======================================================================"

if [[ "${SWAP_AUTO_CREATED}" -eq 1 ]]; then
  swapoff "${SWAP_FILE}"
  rm -f "${SWAP_FILE}"
  backup_file "/etc/fstab"
  sed -i "\#^${SWAP_FILE} #d" /etc/fstab
fi
