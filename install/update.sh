#!/usr/bin/env bash
#
# update.sh
#
# Version: 1.2
# Lizenz:  MIT
#
# Changelog:
#   1.2 - Optionale Selbstprüfung auf neuere Script-Version (CHECK_FOR_UPDATES,
#         analog install-oxicloud.sh 1.16), rein informativ und fehlertolerant.
#   1.1 - Angeglichen an das Robustheits-Niveau von install-oxicloud.sh:
#         1) Lock-Datei (flock) verhindert zwei parallele Updates.
#         2) logrotate-Konfiguration für /var/log/oxicloud-update.log
#            (falls logrotate verfügbar ist), damit das Log bei
#            wiederholten Updates nicht unbegrenzt wächst.
#         3) Optionale Fehler-Benachrichtigung per Webhook
#            (NOTIFY_WEBHOOK_URL), inkl. Hinweis ob ein Rollback erfolgte.
#         4) Wird ein bereits vorhandenes Release-Verzeichnis wiederverwendet
#            (${NEW_RELEASE_DIR} existiert schon), prüft das Script jetzt,
#            ob die Binary darin tatsächlich vorhanden ist - vorher hätte
#            ein Release-Verzeichnis aus einem vorherigen ABGEBROCHENEN
#            Lauf (z.B. Absturz mitten im "cp") stillschweigend als
#            vollständig gegolten und das Umschalten wäre mit einer
#            fehlenden/kaputten Binary fehlgeschlagen.
#
# Aktualisiert eine bereits per install.sh installierte OxiCloud-Instanz auf
# ein neues Release, ohne Konfiguration (.env, systemd-Unit) anzufassen.
#
# Ablauf:
#   1. Neues Release nach releases/<version>/ kopieren (altes bleibt liegen)
#   2. Dienst stoppen, "current"-Symlink auf das neue Release umschalten
#   3. Dienst starten, Health-Check gegen den lokalen /health-Endpunkt
#   4. Bei Erfolg: fertig, alte Releases über KEEP_RELEASES bereinigen
#      Bei Fehlschlag: Symlink automatisch zurück auf das alte Release,
#      Dienst neu starten, Script bricht mit Fehler ab
#
# Aufruf (als root):
#   sudo ./update.sh /pfad/zum/entpackten/neuen/paket
#
# Das neue Paket muss dieselbe Struktur haben wie das von build-package.sh
# erzeugte Release-Paket (bin/, static/, VERSION, ggf. migrations/).

set -euo pipefail

# ─── Konfiguration ────────────────────────────────────────────────────────
# Eigene Versionsnummer dieses Scripts (NICHT zu verwechseln mit
# NEW_VERSION/PREVIOUS_VERSION weiter unten - das sind OxiCloud-Paketversionen).
SCRIPT_VERSION="1.2"

APP_USER="oxicloud"
APP_GROUP="oxicloud"
INSTALL_DIR="/opt/oxicloud"
RELEASES_DIR="${INSTALL_DIR}/releases"
CURRENT_LINK="${INSTALL_DIR}/current"
CONFIG_DIR="/etc/oxicloud"
ENV_FILE="${CONFIG_DIR}/.env"
SERVICE_NAME="oxicloud"
KEEP_RELEASES=5   # 0 = keine Bereinigung, alle Releases dauerhaft behalten

# Health-Check-Endpunkt und Port aus der .env lesen, mit Fallback auf 8086.
# (Passe HEALTH_PATH an, falls eure Version einen anderen Pfad nutzt -
#  laut Dockerfile/Compose sind /health bzw. /ready gängige Kandidaten.)
HEALTH_PATH="/health"
HEALTH_RETRIES=15
HEALTH_INTERVAL=2

# Optionaler Webhook (Slack-/Mattermost-kompatibel), der bei einem
# fehlgeschlagenen Lauf (Exit-Code != 0) einen POST mit {"text": "..."}
# erhält. Leer lassen ("") = keine Benachrichtigung (Standard).
NOTIFY_WEBHOOK_URL=""

# Selbstprüfung auf neuere Script-Version (rein informativ, siehe unten).
CHECK_FOR_UPDATES=true
UPDATE_CHECK_REPO="roswitina/oxicloud-install"
UPDATE_CHECK_BRANCH="main"
UPDATE_CHECK_INTERVAL_HOURS=24
UPDATE_CHECK_CACHE="/etc/oxicloud/.update-check-update"

# ─── Verhindert parallele Updates ------------------------------------------
LOCK_FILE="/var/run/oxicloud-update.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  echo "Fehler: Ein anderer Update-Lauf ist bereits aktiv (Lock: ${LOCK_FILE})." >&2
  exit 1
fi

LOG_FILE="/var/log/oxicloud-update.log"
mkdir -p "$(dirname "${LOG_FILE}")"

# ─── Log-Rotation für das Update-Log ---------------------------------------
if command -v logrotate &>/dev/null; then
  cat > /etc/logrotate.d/oxicloud-update <<'EOF'
/var/log/oxicloud-update.log {
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
echo "===== Update-Lauf gestartet: $(date '+%Y-%m-%d %H:%M:%S') ====="

# ─── Fehler-Benachrichtigung per Webhook (optional) ------------------------
UPDATE_ROLLBACK_STATUS=""
notify_on_failure() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 && -n "${NOTIFY_WEBHOOK_URL}" ]]; then
    local host
    host="$(hostname 2>/dev/null || echo unknown)"
    local msg="OxiCloud update.sh auf '${host}' fehlgeschlagen (Exit-Code ${exit_code})."
    [[ -n "${UPDATE_ROLLBACK_STATUS}" ]] && msg="${msg} ${UPDATE_ROLLBACK_STATUS}"
    msg="${msg} Log: ${LOG_FILE}"
    curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
      -d "$(printf '{"text":"%s"}' "${msg//\"/\\\"}")" \
      "${NOTIFY_WEBHOOK_URL}" >/dev/null 2>&1 || true
  fi
  return "${exit_code}"
}
trap notify_on_failure EXIT

# ─── Vorprüfungen ─────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen (z.B. mit sudo)." >&2
  exit 1
fi

# ─── Selbstprüfung auf neuere Script-Version (rein informativ) ────────────
if [ "${CHECK_FOR_UPDATES}" = "true" ] && command -v curl >/dev/null 2>&1; then
  DO_UPDATE_CHECK=1
  if [ -f "${UPDATE_CHECK_CACHE}" ]; then
    LAST_CHECK_EPOCH="$(cat "${UPDATE_CHECK_CACHE}" 2>/dev/null || echo 0)"
    NOW_EPOCH="$(date +%s)"
    AGE_HOURS=$(( (NOW_EPOCH - LAST_CHECK_EPOCH) / 3600 ))
    [ "${AGE_HOURS}" -lt "${UPDATE_CHECK_INTERVAL_HOURS}" ] && DO_UPDATE_CHECK=0
  fi

  if [ "${DO_UPDATE_CHECK}" -eq 1 ]; then
    REMOTE_RAW_SCRIPT="$(curl -fsS -m 5 \
      "https://raw.githubusercontent.com/${UPDATE_CHECK_REPO}/${UPDATE_CHECK_BRANCH}/update.sh" 2>/dev/null || true)"
    if [ -n "${REMOTE_RAW_SCRIPT}" ]; then
      REMOTE_SCRIPT_VERSION="$(printf '%s\n' "${REMOTE_RAW_SCRIPT}" | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"
      if [ -n "${REMOTE_SCRIPT_VERSION}" ] && [ "${REMOTE_SCRIPT_VERSION}" != "${SCRIPT_VERSION}" ]; then
        echo ""
        echo "Hinweis: Auf GitHub liegt eine andere Version von update.sh"
        echo "         (lokal: ${SCRIPT_VERSION}, dort auf '${UPDATE_CHECK_BRANCH}': ${REMOTE_SCRIPT_VERSION})."
        echo "         https://github.com/${UPDATE_CHECK_REPO}"
        echo ""
      fi
    fi
    mkdir -p "$(dirname "${UPDATE_CHECK_CACHE}")" 2>/dev/null || true
    date +%s > "${UPDATE_CHECK_CACHE}" 2>/dev/null || true
  fi
fi

if [ $# -ne 1 ]; then
  echo "Aufruf: sudo ./update.sh /pfad/zum/entpackten/neuen/paket" >&2
  exit 1
fi
NEW_PKG_DIR="$(cd "$1" && pwd)"

if [ ! -e "${CURRENT_LINK}" ]; then
  echo "Fehler: ${CURRENT_LINK} existiert nicht - ist OxiCloud überhaupt per install.sh installiert?" >&2
  exit 1
fi

for f in "bin/oxicloud" "static" "VERSION"; do
  if [ ! -e "${NEW_PKG_DIR}/${f}" ]; then
    echo "Erwartete Datei/Ordner fehlt im neuen Paket: ${f}" >&2
    exit 1
  fi
done

NEW_VERSION="$(cat "${NEW_PKG_DIR}/VERSION")"
NEW_RELEASE_DIR="${RELEASES_DIR}/${NEW_VERSION}"
PREVIOUS_RELEASE_DIR="$(readlink -f "${CURRENT_LINK}")"
PREVIOUS_VERSION="$(basename "${PREVIOUS_RELEASE_DIR}")"

echo "Aktuell aktiv: ${PREVIOUS_VERSION}"
echo "Neues Release: ${NEW_VERSION}"

if [ "${NEW_VERSION}" = "${PREVIOUS_VERSION}" ]; then
  echo "Version ${NEW_VERSION} ist bereits aktiv - nichts zu tun." >&2
  exit 0
fi

if [ -e "${NEW_RELEASE_DIR}" ] && [ -x "${NEW_RELEASE_DIR}/bin/oxicloud" ]; then
  echo "Release ${NEW_VERSION} liegt bereits vollständig unter ${NEW_RELEASE_DIR} - wird erneut verwendet."
else
  if [ -e "${NEW_RELEASE_DIR}" ]; then
    # Fix (1.1): Verzeichnis existiert, aber die Binary fehlt/ist nicht
    # ausführbar - vermutlich Rest eines vorherigen, mittendrin abgebrochenen
    # Update-Laufs (z.B. Absturz während "cp"). Statt das fälschlich als
    # vollständig zu behandeln und erst beim Umschalten zu scheitern, wird
    # der Rest hier verworfen und sauber neu kopiert.
    echo "==> Unvollständiges Release-Verzeichnis ${NEW_RELEASE_DIR} gefunden (Binary fehlt), räume auf und kopiere neu..." >&2
    rm -rf "${NEW_RELEASE_DIR}"
  fi
  # ─── 1. Neues Release installieren (alter bleibt unangetastet) ──────────
  echo "==> Kopiere neues Release nach ${NEW_RELEASE_DIR}"
  mkdir -p "${NEW_RELEASE_DIR}/bin" "${NEW_RELEASE_DIR}/static"
  install -m 750 -o root -g "${APP_GROUP}" "${NEW_PKG_DIR}/bin/oxicloud" "${NEW_RELEASE_DIR}/bin/oxicloud"
  cp -r "${NEW_PKG_DIR}/static" "${NEW_RELEASE_DIR}/static"
  [ -d "${NEW_PKG_DIR}/migrations" ] && cp -r "${NEW_PKG_DIR}/migrations" "${NEW_RELEASE_DIR}/migrations"

  chown -R root:"${APP_GROUP}" "${NEW_RELEASE_DIR}"
  chmod 750 "${NEW_RELEASE_DIR}/bin/oxicloud"
  find "${NEW_RELEASE_DIR}/static" -type d -exec chmod 755 {} \;
  find "${NEW_RELEASE_DIR}/static" -type f -exec chmod 644 {} \;
  chmod 755 "${NEW_RELEASE_DIR}"
fi

# Hinweis Datenbank-Migrationen: falls OxiCloud Migrationen NICHT automatisch
# beim Start ausführt (z.B. via sqlx::migrate! zur Compile-Zeit eingebettet),
# müssten sie hier vor dem Umschalten manuell angewendet werden. Bitte prüfen,
# wie es sich in eurer Version verhält - das Script geht aktuell davon aus,
# dass die Binary das selbst beim Start erledigt.

# ─── 2. Umschalten ────────────────────────────────────────────────────────
echo "==> Stoppe ${SERVICE_NAME}"
systemctl stop "${SERVICE_NAME}"

echo "==> Schalte current -> ${NEW_RELEASE_DIR}"
ln -sfn "${NEW_RELEASE_DIR}" "${CURRENT_LINK}"

echo "==> Starte ${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

# ─── 3. Health-Check ──────────────────────────────────────────────────────
rollback() {
  echo "!!! Health-Check fehlgeschlagen - rolle zurück auf ${PREVIOUS_VERSION}" >&2
  systemctl stop "${SERVICE_NAME}" || true
  ln -sfn "${PREVIOUS_RELEASE_DIR}" "${CURRENT_LINK}"
  systemctl start "${SERVICE_NAME}" || true
  echo "Rollback durchgeführt. current zeigt wieder auf ${PREVIOUS_VERSION}." >&2
  UPDATE_ROLLBACK_STATUS="Health-Check für ${NEW_VERSION} fehlgeschlagen, automatisches Rollback auf ${PREVIOUS_VERSION} durchgeführt."
  exit 1
}

# Port aus der .env lesen (Fallback 8086), um lokal gegen den Health-Endpunkt zu prüfen
PORT="$(grep -E '^OXICLOUD_SERVER_PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || true)"
PORT="${PORT:-8086}"

echo "==> Prüfe Gesundheit unter http://127.0.0.1:${PORT}${HEALTH_PATH}"
ok=0
for i in $(seq 1 "${HEALTH_RETRIES}"); do
  if curl -fsS "http://127.0.0.1:${PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep "${HEALTH_INTERVAL}"
done

if [ "${ok}" -ne 1 ]; then
  rollback
fi

echo "==> Health-Check erfolgreich, Update auf ${NEW_VERSION} abgeschlossen."

# ─── 4. Alte Releases aufräumen ───────────────────────────────────────────
if [ "${KEEP_RELEASES}" -gt 0 ]; then
  ACTIVE="$(readlink -f "${CURRENT_LINK}")"
  mapfile -t OLD_RELEASES < <(
    find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
      | sort -rn | cut -d' ' -f2- | tail -n +"$((KEEP_RELEASES + 1))"
  )
  for old in "${OLD_RELEASES[@]:-}"; do
    [ -z "${old}" ] && continue
    [ "${old}" = "${ACTIVE}" ] && continue
    echo "==> Entferne altes Release: ${old}"
    rm -rf "${old}"
  done
fi

echo ""
echo "Aktives Release: ${NEW_VERSION}"
echo "Rollback bei Bedarf: sudo ./update.sh <alter-paket-ordner>  # oder manuell current umbiegen:"
echo "  sudo ln -sfn ${PREVIOUS_RELEASE_DIR} ${CURRENT_LINK} && sudo systemctl restart ${SERVICE_NAME}"
