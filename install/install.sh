#!/usr/bin/env bash
#
# install.sh
#
# Version: 1.2
# Lizenz:  MIT
#
# Installiert ein entpacktes OxiCloud-Release-Paket auf dem System.
# Ab Version 2: versionierte Releases unter releases/<version>/ mit einem
# "current"-Symlink darauf (analog zum Vorbild-Script des Nutzers) - das
# ermöglicht update.sh ein sauberes Rollback bei fehlgeschlagenem Update.
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

set -euo pipefail

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

# Verzeichnis, in dem dieses Script liegt (= entpacktes Release-Paket)
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
else
  echo "==> Lege ${ENV_FILE} aus example.env an"
  cp "${PKG_DIR}/example.env" "${ENV_FILE}"
  echo "    WICHTIG: ${ENV_FILE} vor dem ersten Start anpassen"
  echo "    (OXICLOUD_DB_CONNECTION_STRING, OXICLOUD_BASE_URL, Secrets, ...)"
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

# Datenverzeichnis: dem Service-User gehörend, da er hier schreibt
chown -R "${APP_USER}":"${APP_GROUP}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

# ─── 6. systemd-Unit anlegen ──────────────────────────────────────────────
echo "==> Installiere systemd-Unit ${SERVICE_FILE}"
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
echo ""
echo "Nächste Schritte:"
echo "  1. ${ENV_FILE} anpassen (DB-Connection, Base-URL, Secrets)"
echo "  2. Erreichbarkeit von PostgreSQL sicherstellen"
echo "  3. Dienst starten:   systemctl start oxicloud"
echo "  4. Status prüfen:    systemctl status oxicloud"
echo "  5. Logs ansehen:     journalctl -u oxicloud -f"
echo ""
echo "Verwaltung: systemctl [start|stop|restart|status] oxicloud"
echo "Updates künftig mit:  sudo oxicloud-update /pfad/zum/neuen/paket"
