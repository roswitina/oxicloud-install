#!/usr/bin/env bash
#
# build-package.sh
#
# Baut OxiCloud (Backend + Frontend) und schnürt daraus ein
# selbst-enthaltenes tar.gz-Release-Paket:
#   oxicloud-<version>-linux-<arch>.tar.gz
#     ├── bin/oxicloud        # Release-Binary
#     ├── static/             # Vite-Build des Svelte-Frontends
#     ├── migrations/         # nur falls NICHT in die Binary eingebettet
#     ├── example.env         # Vorlage für die spätere .env
#     └── install.sh          # Installer (siehe separate Datei)
#
# Ausführen im Repo-Root von OxiCloud: ./build-package.sh [version]

set -euo pipefail

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
ARCH="$(uname -m)"
DIST_NAME="oxicloud-${VERSION}-linux-${ARCH}"
STAGE="dist/${DIST_NAME}"

echo "==> Baue Backend (release)"
cargo build --release

echo "==> Baue Frontend (Vite)"
# Pfad ggf. anpassen, falls das Svelte-Projekt in einem anderen
# Unterordner liegt (im Repo z.B. "frontend/").
pushd frontend >/dev/null
npm ci
npm run build   # erzeugt laut build.rs standardmäßig static-dist/ im Repo-Root
popd >/dev/null

echo "==> Staging-Verzeichnis vorbereiten: ${STAGE}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/static"

cp target/release/oxicloud       "${STAGE}/bin/oxicloud"
cp -r static-dist/.              "${STAGE}/static/"
cp example.env                   "${STAGE}/example.env"
cp install.sh                    "${STAGE}/install.sh"
cp update.sh                     "${STAGE}/update.sh"
chmod +x "${STAGE}/install.sh" "${STAGE}/update.sh"
chmod 755 "${STAGE}/bin/oxicloud"

echo "${VERSION}" > "${STAGE}/VERSION"

# Falls DB-Migrationen zur Laufzeit vom Dateisystem gelesen werden
# (statt zur Compile-Zeit per sqlx::migrate!/include_str! eingebettet
# zu sein), hier mitpacken. Im Zweifel einfach mitkopieren - schadet nicht.
if [ -d migrations ]; then
  cp -r migrations "${STAGE}/migrations"
fi

echo "==> Packe tar.gz"
tar -C dist -czf "dist/${DIST_NAME}.tar.gz" "${DIST_NAME}"
sha256sum "dist/${DIST_NAME}.tar.gz" > "dist/${DIST_NAME}.tar.gz.sha256"

echo ""
echo "Fertig: dist/${DIST_NAME}.tar.gz"
echo "Prüfsumme: dist/${DIST_NAME}.tar.gz.sha256"
