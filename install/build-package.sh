#!/usr/bin/env bash
#
# build-package.sh
#
# Version: 2.0
# Lizenz:  MIT
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

# ─── Eigener Standort (für install.sh/update.sh, unabhängig vom cwd) ──────
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

VERSION="${2:-$(cd "${SOURCE_DIR}" && git describe --tags --always 2>/dev/null || echo dev)}"
ARCH="$(uname -m)"
DIST_NAME="oxicloud-${VERSION}-linux-${ARCH}"
STAGE="${OUTPUT_DIR}/${DIST_NAME}"

echo "Quellcode:  ${SOURCE_DIR}"
echo "Tooling:    ${TOOL_DIR}"
echo "Version:    ${VERSION}"
echo "Ausgabe:    ${STAGE}.tar.gz"
echo ""

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
