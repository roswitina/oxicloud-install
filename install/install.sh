#!/usr/bin/env bash
#
# install.sh
#
# Version: 1.4
# Lizenz:  MIT
#
# Installiert ein entpacktes OxiCloud-Release-Paket auf dem System.
# Ab Version 2: versionierte Releases unter releases/<version>/ mit einem
# "current"-Symlink darauf (analog zum Vorbild-Script des Nutzers) - das
# ermöglicht update.sh ein sauberes Rollback bei fehlgeschlagenem Update.
# Ab Version 1.3: PostgreSQL-Handling.
#   - Erreichbarkeit der in .env hinterlegten DB wird IMMER geprüft
#     (TCP-Check per /dev/tcp, zusätzlich echter Auth-Check falls psql
#     verfügbar ist) - nur eine Warnung, kein harter Abbruch.
#   - Mit --with-local-postgres wird PostgreSQL zusätzlich OPTIONAL lokal
#     installiert, Rolle+Datenbank angelegt und (nur bei frisch erzeugter
#     .env) automatisch in OXICLOUD_DB_CONNECTION_STRING eingetragen.
# Ab Version 1.4: Backup-Helfer - die systemd-Unit wird vor jedem
#   Überschreiben als Zeitstempel-Kopie unter .../backups/ gesichert,
#   damit manuelle Anpassungen bei einem erneuten Lauf nicht verloren gehen.
#
#   - legt einen dedizierten Systemuser/-gruppe "oxicloud" an
#   - installiert bin/ und static/ nach /opt/oxicloud/releases/<version>/
#   - setzt den Symlink /opt/oxicloud/current darauf
#   - legt /etc/oxicloud an und platziert dort die .env (aus example.env)
#   - legt ein Datenverzeichnis für Uploads/Storage an
#   - setzt Dateirechte
#   - installiert und aktiviert eine systemd-Unit
#
# Aufruf (als root, im entpackten Paket-Verzeichnis):
#   sudo ./install.sh
#   sudo ./install.sh --with-local-postgres

set -euo pipefail

# ─── Argumente ─────────────────────────────────────────────────────────────
WITH_LOCAL_POSTGRES=0
for arg in "$@"; do
  case "${arg}" in
    --with-local-postgres) WITH_LOCAL_POSTGRES=1 ;;
    *) echo "Unbekannte Option: ${arg}" >&2; exit 1 ;;
  esac
done

# ─── Konfiguration ────────────────────────────────────────────────────────
APP_USER="oxicloud"
APP_GROUP="oxicloud"
INSTALL_DIR="/opt/oxicloud"
RELEASES_DIR="${INSTALL_DIR}/releases"
CURRENT_LINK="${INSTALL_DIR}/current"
CONFIG_DIR="/etc/oxicloud"
DATA_DIR="/var/lib/oxicloud"
STORAGE_DIR="${DATA_DIR}/storage"
SERVICE_FILE="/etc/systemd/system/oxicloud.service"
ENV_FILE="${CONFIG_DIR}/.env"
KEEP_RELEASES=5   # 0 = keine Bereinigung, alle Releases dauerhaft behalten

# Nur relevant bei --with-local-postgres
PG_DB_NAME="oxicloud"
PG_DB_USER="oxicloud"
PG_PASS_FILE="${CONFIG_DIR}/.db_password"

# Verzeichnis, in dem dieses Script liegt (= entpacktes Release-Paket)
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Backup-Helfer: legt vor jedem Überschreiben eine Zeitstempel-Kopie an ─
# Schützt v.a. die systemd-Unit vor stillschweigendem Verlust manueller
# Anpassungen bei einem erneuten install.sh-Lauf (z.B. für eine neue Version).
backup_file() {
  local file="$1"
  if [ -f "${file}" ]; then
    local backup_dir
    backup_dir="$(dirname "${file}")/backups"
    mkdir -p "${backup_dir}"
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    local backup_path="${backup_dir}/$(basename "${file}").${ts}.bak"
    cp -p "${file}" "${backup_path}"
    echo "    Backup angelegt: ${backup_path}"
  fi
}

# ─── Vorprüfungen ─────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen (z.B. mit sudo)." >&2
  exit 1
fi

for f in "bin/oxicloud" "static" "example.env" "update.sh"; do
  if [ ! -e "${PKG_DIR}/${f}" ]; then
    echo "Erwartete Datei/Ordner fehlt im Paket: ${f}" >&2
    exit 1
  fi
done

# VERSION-Datei wird von build-package.sh erzeugt. Fallback: Zeitstempel,
# falls ein älter geschnürtes Paket ohne VERSION-Datei installiert wird.
if [ -f "${PKG_DIR}/VERSION" ]; then
  VERSION="$(cat "${PKG_DIR}/VERSION")"
else
  VERSION="local-$(date '+%Y%m%d-%H%M%S')"
  echo "Hinweis: keine VERSION-Datei im Paket gefunden, verwende '${VERSION}'." >&2
fi
RELEASE_DIR="${RELEASES_DIR}/${VERSION}"

# ─── 1. Systemuser & -gruppe ──────────────────────────────────────────────
if ! getent group "${APP_GROUP}" >/dev/null; then
  echo "==> Lege Gruppe ${APP_GROUP} an"
  groupadd --system "${APP_GROUP}"
fi

if ! id "${APP_USER}" >/dev/null 2>&1; then
  echo "==> Lege Systemuser ${APP_USER} an"
  useradd --system \
          --gid "${APP_GROUP}" \
          --home-dir "${DATA_DIR}" \
          --no-create-home \
          --shell /usr/sbin/nologin \
          "${APP_USER}"
fi

# ─── 2. Verzeichnisse anlegen ─────────────────────────────────────────────
echo "==> Lege Verzeichnisse an (Release: ${VERSION})"
if [ -e "${RELEASE_DIR}" ]; then
  echo "Release ${VERSION} ist bereits unter ${RELEASE_DIR} installiert." >&2
  echo "Für ein Update bitte update.sh verwenden, nicht install.sh erneut." >&2
  exit 1
fi
mkdir -p "${RELEASE_DIR}/bin" "${RELEASE_DIR}/static"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${STORAGE_DIR}"

# ─── 2b. PostgreSQL optional lokal installieren (--with-local-postgres) ───
LOCAL_DATABASE_URL=""
if [ "${WITH_LOCAL_POSTGRES}" -eq 1 ]; then
  echo "==> --with-local-postgres gesetzt: prüfe/installiere PostgreSQL lokal"

  REQUIRED_PG_PACKAGES=(postgresql postgresql-contrib)
  MISSING_PG_PACKAGES=()
  for pkg in "${REQUIRED_PG_PACKAGES[@]}"; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || MISSING_PG_PACKAGES+=("${pkg}")
  done

  if [ "${#MISSING_PG_PACKAGES[@]}" -gt 0 ]; then
    echo "    Installiere fehlende Pakete: ${MISSING_PG_PACKAGES[*]}"
    apt-get update -y
    apt-get install -y "${MISSING_PG_PACKAGES[@]}"
  else
    echo "    PostgreSQL-Pakete bereits vorhanden."
  fi

  echo "    Stelle sicher, dass PostgreSQL läuft..."
  systemctl enable --now postgresql

  if [ -f "${PG_PASS_FILE}" ]; then
    PG_DB_PASS="$(cat "${PG_PASS_FILE}")"
    PG_PASS_IS_NEW=0
  else
    if command -v openssl >/dev/null 2>&1; then
      PG_DB_PASS="$(openssl rand -hex 16)"
    else
      PG_DB_PASS="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    PG_PASS_IS_NEW=1
  fi

  echo "    Lege Rolle '${PG_DB_USER}' an (falls noch nicht vorhanden)..."
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${PG_DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE ${PG_DB_USER} WITH LOGIN PASSWORD '${PG_DB_PASS}';"

  echo "    Lege Datenbank '${PG_DB_NAME}' an (falls noch nicht vorhanden)..."
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${PG_DB_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${PG_DB_NAME} OWNER ${PG_DB_USER};"

  if [ "${PG_PASS_IS_NEW}" -eq 1 ]; then
    echo -n "${PG_DB_PASS}" > "${PG_PASS_FILE}"
    chmod 600 "${PG_PASS_FILE}"
  fi

  LOCAL_DATABASE_URL="postgres://${PG_DB_USER}:${PG_DB_PASS}@localhost:5432/${PG_DB_NAME}"
  echo "    Lokale PostgreSQL-Instanz bereit. DB: ${PG_DB_NAME}, User: ${PG_DB_USER}"
  echo "    Passwort (auch gespeichert in ${PG_PASS_FILE}): ${PG_DB_PASS}"
fi

# ─── 3. Dateien kopieren ──────────────────────────────────────────────────
echo "==> Kopiere Binary und Static-Assets nach ${RELEASE_DIR}"
install -m 750 -o root -g "${APP_GROUP}" "${PKG_DIR}/bin/oxicloud" "${RELEASE_DIR}/bin/oxicloud"
cp -r "${PKG_DIR}/static" "${RELEASE_DIR}/static"

if [ -d "${PKG_DIR}/migrations" ]; then
  cp -r "${PKG_DIR}/migrations" "${RELEASE_DIR}/migrations"
fi

echo "==> Setze Symlink ${CURRENT_LINK} -> ${RELEASE_DIR}"
ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}"

# ─── 4. .env anlegen (ohne bestehende Config zu überschreiben) ────────────
if [ -f "${ENV_FILE}" ]; then
  echo "==> ${ENV_FILE} existiert bereits – wird NICHT überschrieben."
  echo "    Neue Beispielwerte liegen zum Vergleich unter ${CONFIG_DIR}/example.env"
  cp "${PKG_DIR}/example.env" "${CONFIG_DIR}/example.env"
  if [ -n "${LOCAL_DATABASE_URL}" ]; then
    echo "    Hinweis: --with-local-postgres wurde gesetzt, aber die bestehende"
    echo "    .env bleibt unangetastet. Trage die Connection-String bei Bedarf"
    echo "    manuell ein: ${LOCAL_DATABASE_URL}"
  fi
else
  echo "==> Lege ${ENV_FILE} aus example.env an"
  cp "${PKG_DIR}/example.env" "${ENV_FILE}"
  if [ -n "${LOCAL_DATABASE_URL}" ]; then
    if grep -q '^OXICLOUD_DB_CONNECTION_STRING=' "${ENV_FILE}"; then
      sed -i "s#^OXICLOUD_DB_CONNECTION_STRING=.*#OXICLOUD_DB_CONNECTION_STRING=${LOCAL_DATABASE_URL}#" "${ENV_FILE}"
    else
      echo "OXICLOUD_DB_CONNECTION_STRING=${LOCAL_DATABASE_URL}" >> "${ENV_FILE}"
    fi
    echo "    OXICLOUD_DB_CONNECTION_STRING automatisch auf die lokale PostgreSQL-Instanz gesetzt."
  else
    echo "    WICHTIG: ${ENV_FILE} vor dem ersten Start anpassen"
    echo "    (OXICLOUD_DB_CONNECTION_STRING, OXICLOUD_BASE_URL, Secrets, ...)"
  fi
fi

# ─── 5. Rechte setzen ─────────────────────────────────────────────────────
echo "==> Setze Dateirechte"

# Binary: root:oxicloud, nur von root beschreibbar, von der Gruppe ausführbar
chown root:"${APP_GROUP}" "${RELEASE_DIR}/bin/oxicloud"
chmod 750 "${RELEASE_DIR}/bin/oxicloud"

# Static-Assets: nur lesbar, niemand braucht Schreibzugriff zur Laufzeit
chown -R root:"${APP_GROUP}" "${RELEASE_DIR}/static"
find "${RELEASE_DIR}/static" -type d -exec chmod 755 {} \;
find "${RELEASE_DIR}/static" -type f -exec chmod 644 {} \;

# releases/ und der current-Symlink selbst müssen für root:oxicloud
# durchsuchbar/lesbar sein (Symlink-Ziel liegt außerhalb von /etc, /var)
chown -R root:"${APP_GROUP}" "${INSTALL_DIR}"
find "${RELEASES_DIR}" -maxdepth 1 -type d -exec chmod 755 {} \;

# Config: enthält u.U. Secrets -> restriktiv
chown root:"${APP_GROUP}" "${CONFIG_DIR}"
chmod 750 "${CONFIG_DIR}"
chown root:"${APP_GROUP}" "${ENV_FILE}"
chmod 640 "${ENV_FILE}"

# ─── 5b. PostgreSQL-Erreichbarkeit prüfen (immer, unabhängig vom Flag) ────
echo "==> Prüfe Erreichbarkeit der Datenbank aus ${ENV_FILE}"
DB_URL_CHECK="$(grep -E '^OXICLOUD_DB_CONNECTION_STRING=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"

# Hinweis: enthält das Passwort selbst ein "@", schlägt das Parsen fehl -
# der Check wird dann sauber übersprungen (Warnung unten), kein Abbruch.
if [ -z "${DB_URL_CHECK}" ]; then
  echo "    WARNUNG: OXICLOUD_DB_CONNECTION_STRING ist in ${ENV_FILE} nicht gesetzt - übersprungen."
elif [[ "${DB_URL_CHECK}" =~ ^postgres(ql)?://[^@]*@([^:/]+)(:([0-9]+))?/ ]]; then
  DB_HOST="${BASH_REMATCH[2]}"
  DB_PORT="${BASH_REMATCH[4]:-5432}"

  TCP_OK=0
  if (exec 3<>"/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; then
    TCP_OK=1
    exec 3<&- 3>&- 2>/dev/null || true
  fi

  if [ "${TCP_OK}" -eq 1 ]; then
    echo "    TCP-Verbindung zu ${DB_HOST}:${DB_PORT} erfolgreich."
    if command -v psql >/dev/null 2>&1; then
      if psql "${DB_URL_CHECK}" -c '\q' >/dev/null 2>&1; then
        echo "    Auth-Check erfolgreich (Benutzer/Passwort/Datenbank stimmen)."
      else
        echo "    WARNUNG: TCP erreichbar, aber Anmeldung an der Datenbank fehlgeschlagen."
        echo "    Bitte Zugangsdaten in ${ENV_FILE} prüfen."
      fi
    else
      echo "    Hinweis: 'psql' nicht installiert, nur TCP-Erreichbarkeit geprüft (keine Auth-Prüfung)."
    fi
  else
    echo "    WARNUNG: ${DB_HOST}:${DB_PORT} ist nicht erreichbar."
    echo "    OxiCloud wird ohne funktionierende Datenbank nicht starten können."
  fi
else
  echo "    WARNUNG: Konnte Host/Port nicht aus OXICLOUD_DB_CONNECTION_STRING parsen - übersprungen."
fi

# Datenverzeichnis: dem Service-User gehörend, da er hier schreibt
chown -R "${APP_USER}":"${APP_GROUP}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

# ─── 6. systemd-Unit anlegen ──────────────────────────────────────────────
echo "==> Installiere systemd-Unit ${SERVICE_FILE}"
backup_file "${SERVICE_FILE}"
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OxiCloud - selbst-gehostete Cloud (Files/CalDAV/CardDAV)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${CURRENT_LINK}
EnvironmentFile=${ENV_FILE}
ExecStart=${CURRENT_LINK}/bin/oxicloud
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "${SERVICE_FILE}"

# ─── 7. systemd neu einlesen ──────────────────────────────────────────────
echo "==> systemd neu laden und Service aktivieren (aber nicht starten)"
systemctl daemon-reload
systemctl enable oxicloud.service

# ─── 8. update.sh systemweit verfügbar machen ─────────────────────────────
# Damit du künftig nicht das jeweils zuletzt entpackte Paketverzeichnis
# wiederfinden musst: update.sh landet fest unter /usr/local/sbin und kann
# von überall mit "sudo oxicloud-update /pfad/zum/neuen/paket" aufgerufen
# werden. Es wird bei jeder install.sh-/erneuten Installation aktualisiert.
UPDATE_WRAPPER="/usr/local/sbin/oxicloud-update"
echo "==> Installiere Update-Wrapper: ${UPDATE_WRAPPER}"
install -m 750 -o root -g "${APP_GROUP}" "${PKG_DIR}/update.sh" "${UPDATE_WRAPPER}"

echo ""
echo "Installation abgeschlossen."
echo "Installiertes Release: ${VERSION}  (${RELEASE_DIR})"
echo "current -> $(readlink -f "${CURRENT_LINK}")"
if [ -n "${LOCAL_DATABASE_URL}" ]; then
  echo "PostgreSQL: lokal installiert und eingerichtet (DB: ${PG_DB_NAME}, User: ${PG_DB_USER})"
fi
echo ""
echo "Nächste Schritte:"
echo "  1. ${ENV_FILE} anpassen (Base-URL, Secrets, ggf. DB-Connection)"
echo "  2. Erreichbarkeit von PostgreSQL wurde oben geprüft - Warnungen beachten"
echo "  3. Dienst starten:   systemctl start oxicloud"
echo "  4. Status prüfen:    systemctl status oxicloud"
echo "  5. Logs ansehen:     journalctl -u oxicloud -f"
echo ""
echo "Verwaltung: systemctl [start|stop|restart|status] oxicloud"
echo "Updates künftig mit:  sudo oxicloud-update /pfad/zum/neuen/paket"
