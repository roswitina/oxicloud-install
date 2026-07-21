#!/usr/bin/env bash
#
# build-package.sh
#
# Version: 2.2
# Lizenz:  MIT
#
# Changelog:
#   2.2 - Optionale Selbstprüfung auf neuere Script-Version (CHECK_FOR_UPDATES,
#         analog install-oxicloud.sh 1.16), rein informativ und fehlertolerant.
#         Cache liegt neben dem Script selbst (TOOL_DIR), nicht unter
#         /etc/oxicloud - das Script läuft ja typischerweise NICHT auf dem
#         OxiCloud-Zielserver, sondern auf einer separaten Build-Maschine/CI.
#   2.1 - Angeglichen an das Robustheits-Niveau von install-oxicloud.sh:
#         1) Preflight-Check auf benötigte Tools (cargo, npm, tar,
#            sha256sum, git) mit klarer Fehlermeldung VOR dem Build, statt
#            eines kryptischen "command not found" mitten im Build.
#         2) Lock-Datei (flock) pro Output-Verzeichnis verhindert, dass
#            zwei parallele Läufe (z.B. zwei CI-Jobs) sich gegenseitig ins
#            selbe Staging-Verzeichnis schreiben.
#         3) Warnung, falls das Ziel-Tarball (gleiche Version+Arch) bereits
#            existiert und gleich überschrieben wird - vorher stillschweigend.
#
# Baut OxiCloud (Backend + Frontend) aus einem beliebigen Checkout und
# schnürt daraus ein selbst-enthaltenes tar.gz-Release-Paket:
#   oxicloud-<version>-linux-<arch>.tar.gz
#     ├── bin/oxicloud        # Release-Binary
#     ├── static/             # Vite-Build des Svelte-Frontends
#     ├── migrations/         # nur falls NICHT in die Binary eingebettet
#     ├── example.env         # Vorlage für die spätere .env
#     ├── install.sh          # Installer (aus diesem Tooling-Ordner)
#     ├── update.sh           # Update-Script (aus diesem Tooling-Ordner)
#     └── VERSION             # Versionsstring, von install.sh/update.sh gelesen
#
# WICHTIG (seit Version 2.0): Dieses Script liegt bewusst NICHT im
# OxiCloud-Repo, sondern in einem eigenen Tooling-Ordner zusammen mit
# install.sh und update.sh. Der Quellcode-Checkout wird als Parameter
# übergeben - so bleibt der Ordner "/opt/oxicloud" (falls per Git-Pull-
# Script verwaltet) ausschließlich vom Upstream-Repo bestimmt, ohne
# Namenskollisionen oder Merge-Konflikte durch Deployment-Tooling.
#
# Aufruf:
#   ./build-package.sh <pfad-zum-oxicloud-checkout> [version] [output-dir]
#
# Beispiele:
#   ./build-package.sh ~/src/OxiCloud
#   ./build-package.sh ~/src/OxiCloud v0.8.1
#   ./build-package.sh ~/src/OxiCloud v0.8.1 /srv/oxicloud-packages
#
# version:    optional, Standard: "git describe --tags --always" im Checkout
# output-dir: optional, Standard: ./dist neben diesem Script (Tooling-Ordner)

set -euo pipefail

# Eigene Versionsnummer dieses Scripts (NICHT zu verwechseln mit VERSION
# weiter unten - das ist die Version des zu bauenden OxiCloud-Pakets).
SCRIPT_VERSION="2.2"

# Selbstprüfung auf neuere Script-Version (rein informativ, siehe unten).
CHECK_FOR_UPDATES=true
UPDATE_CHECK_REPO="roswitina/oxicloud-install"
UPDATE_CHECK_BRANCH="main"
UPDATE_CHECK_INTERVAL_HOURS=24

# ─── Eigener Standort (für install.sh/update.sh, unabhängig vom cwd) ──────
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UPDATE_CHECK_CACHE="${TOOL_DIR}/.update-check-cache"

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
      "https://raw.githubusercontent.com/${UPDATE_CHECK_REPO}/${UPDATE_CHECK_BRANCH}/build-package.sh" 2>/dev/null || true)"
    if [ -n "${REMOTE_RAW_SCRIPT}" ]; then
      REMOTE_SCRIPT_VERSION="$(printf '%s\n' "${REMOTE_RAW_SCRIPT}" | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"
      if [ -n "${REMOTE_SCRIPT_VERSION}" ] && [ "${REMOTE_SCRIPT_VERSION}" != "${SCRIPT_VERSION}" ]; then
        echo ""
        echo "Hinweis: Auf GitHub liegt eine andere Version von build-package.sh"
        echo "         (lokal: ${SCRIPT_VERSION}, dort auf '${UPDATE_CHECK_BRANCH}': ${REMOTE_SCRIPT_VERSION})."
        echo "         https://github.com/${UPDATE_CHECK_REPO}"
        echo ""
      fi
    fi
    date +%s > "${UPDATE_CHECK_CACHE}" 2>/dev/null || true
  fi
fi

# ─── Argumente ─────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
  echo "Aufruf: $0 <pfad-zum-oxicloud-checkout> [version] [output-dir]" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$1" && pwd)"
OUTPUT_DIR="${3:-${TOOL_DIR}/dist}"

if [ ! -f "${SOURCE_DIR}/Cargo.toml" ]; then
  echo "Fehler: ${SOURCE_DIR} sieht nicht wie ein OxiCloud-Checkout aus (Cargo.toml fehlt)." >&2
  exit 1
fi

for f in install.sh update.sh; do
  if [ ! -f "${TOOL_DIR}/${f}" ]; then
    echo "Fehler: ${f} fehlt neben build-package.sh in ${TOOL_DIR}." >&2
    exit 1
  fi
done

# ─── Preflight: benötigte Tools prüfen ─────────────────────────────────────
# Ohne diesen Check würde ein fehlendes Tool erst mitten im Build (z.B. nach
# mehreren Minuten "cargo build") mit einem kryptischen "command not found"
# auffallen. Lieber sofort und mit klarer Meldung abbrechen.
REQUIRED_TOOLS=(cargo npm tar sha256sum git)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  command -v "${tool}" &>/dev/null || MISSING_TOOLS+=("${tool}")
done
if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
  echo "Fehler: Folgende benötigte Tools fehlen auf dieser Build-Maschine: ${MISSING_TOOLS[*]}" >&2
  echo "Bitte nachinstallieren (Rust via rustup, Node.js via NodeSource o.ä.) und erneut versuchen." >&2
  exit 1
fi

# ─── Verhindert parallele Läufe ins selbe Output-Verzeichnis ───────────────
mkdir -p "${OUTPUT_DIR}"
LOCK_FILE="${OUTPUT_DIR}/.build-package.lock"
exec 201>"${LOCK_FILE}"
if ! flock -n 201; then
  echo "Fehler: Ein anderer build-package.sh-Lauf für ${OUTPUT_DIR} ist bereits aktiv." >&2
  exit 1
fi

VERSION="${2:-$(cd "${SOURCE_DIR}" && git describe --tags --always 2>/dev/null || echo dev)}"
ARCH="$(uname -m)"
DIST_NAME="oxicloud-${VERSION}-linux-${ARCH}"
STAGE="${OUTPUT_DIR}/${DIST_NAME}"

echo "Quellcode:  ${SOURCE_DIR}"
echo "Tooling:    ${TOOL_DIR}"
echo "Version:    ${VERSION}"
echo "Ausgabe:    ${STAGE}.tar.gz"
echo ""

if [ -e "${OUTPUT_DIR}/${DIST_NAME}.tar.gz" ]; then
  echo "Hinweis: ${OUTPUT_DIR}/${DIST_NAME}.tar.gz existiert bereits und wird" >&2
  echo "am Ende überschrieben (gleiche Version '${VERSION}' + Architektur '${ARCH}')." >&2
  echo ""
fi

echo "==> Baue Backend (release)"
( cd "${SOURCE_DIR}" && cargo build --release )

echo "==> Baue Frontend (Vite)"
# Pfad ggf. anpassen, falls das Svelte-Projekt in einem anderen
# Unterordner liegt (im Repo z.B. "frontend/").
(
  cd "${SOURCE_DIR}/frontend"
  npm ci
  npm run build   # erzeugt laut build.rs standardmäßig static-dist/ im Repo-Root
)

echo "==> Staging-Verzeichnis vorbereiten: ${STAGE}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/static"

cp "${SOURCE_DIR}/target/release/oxicloud"  "${STAGE}/bin/oxicloud"
cp -r "${SOURCE_DIR}/static-dist/."         "${STAGE}/static/"
cp "${SOURCE_DIR}/example.env"              "${STAGE}/example.env"
cp "${TOOL_DIR}/install.sh"                 "${STAGE}/install.sh"
cp "${TOOL_DIR}/update.sh"                  "${STAGE}/update.sh"
chmod +x "${STAGE}/install.sh" "${STAGE}/update.sh"
chmod 755 "${STAGE}/bin/oxicloud"

echo "${VERSION}" > "${STAGE}/VERSION"

# Falls DB-Migrationen zur Laufzeit vom Dateisystem gelesen werden
# (statt zur Compile-Zeit per sqlx::migrate!/include_str! eingebettet
# zu sein), hier mitpacken. Im Zweifel einfach mitkopieren - schadet nicht.
if [ -d "${SOURCE_DIR}/migrations" ]; then
  cp -r "${SOURCE_DIR}/migrations" "${STAGE}/migrations"
fi

echo "==> Packe tar.gz"
mkdir -p "${OUTPUT_DIR}"
tar -C "${OUTPUT_DIR}" -czf "${OUTPUT_DIR}/${DIST_NAME}.tar.gz" "${DIST_NAME}"
sha256sum "${OUTPUT_DIR}/${DIST_NAME}.tar.gz" > "${OUTPUT_DIR}/${DIST_NAME}.tar.gz.sha256"

echo ""
echo "Fertig: ${OUTPUT_DIR}/${DIST_NAME}.tar.gz"
echo "Prüfsumme: ${OUTPUT_DIR}/${DIST_NAME}.tar.gz.sha256"
