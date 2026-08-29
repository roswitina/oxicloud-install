#!/usr/bin/env bash
#
# Native (non-container) install script for OxiCloud
# https://github.com/AtalayaLabs/OxiCloud
#
# Version:          1.19
# Lizenz:           MIT
# Erstellt am:      2026-07-13 15:59 UTC
# Zuletzt geändert: 2026-08-29 UTC (Update-Hinweis auch im Abschlussblock)
#
# Changelog:
#   1.19 - Der Hinweis auf eine neuere Script-Version (CHECK_FOR_UPDATES,
#          siehe 1.16) stand bisher nur mitten im scrollenden Lauf-Output,
#          direkt nach dem Preflight-Check. Im finalen Zusammenfassungsblock
#          am Scriptende - dem Teil, den man beim normalen Durchlauf
#          tatsächlich anschaut - tauchte er nicht mehr auf und ging damit
#          leicht unter, ohne dass man Grund hätte, extra ins Install-Log
#          zu schauen. Der Hinweis wird jetzt zusätzlich am Ende in der
#          Zusammenfassung wiederholt. Damit das auch dann noch funktioniert,
#          wenn der eigentliche GitHub-Abruf in diesem Lauf wegen
#          UPDATE_CHECK_INTERVAL_HOURS übersprungen wurde (Cache greift),
#          speichert die Cache-Datei jetzt zusätzlich zum Zeitstempel
#          (weiterhin Zeile 1, unverändertes Format) in Zeile 2 die zuletzt
#          bekannte Remote-Version - ein an einem Vortag gefundener Hinweis
#          bleibt so auch an den Tagen sichtbar, an denen selbst nicht neu
#          geprüft wird, bis entweder lokal aktualisiert wird oder ein
#          neuer echter Check dieselbe Version bestätigt.
#   1.18 - Review-Runde mit folgenden Fixes/Verbesserungen:
#          1) BUGFIX: Ermittlung des "latest"-GitHub-Release
#             (OXICLOUD_VERSION_PIN=latest) war unter "set -e -o pipefail"
#             NICHT gegen einen fehlschlagenden curl abgesichert (im
#             Gegensatz zur analogen, in 1.11 bereits gefixten Node-LTS-
#             Ermittlung). Schlug curl fehl (kein Internet, GitHub down,
#             Rate-Limit), brach die Pipe sofort und stillschweigend ab,
#             OHNE die eigentlich vorgesehene Fehlermeldung darunter jemals
#             zu erreichen. Jetzt mit "|| true" abgesichert, wie beim
#             Node-Fix; die bestehende Fehlerbehandlung greift wie geplant.
#          2) Verifizierung der benötigten Programme (git, curl, jq, openssl,
#             psql, node, npm, cargo) lief bisher NACH dem DB-Backup und der
#             Migration - fehlte eines davon, war der Lauf an dieser Stelle
#             schon mit einem unklaren Fehler gescheitert, bevor die
#             eigentlich freundliche Prüfung greifen konnte. Jetzt direkt
#             nach dem Preflight-Check, also VOR jeder Nutzung von psql/
#             cargo/etc.
#          3) Optionales GITHUB_TOKEN (Konfigurationsblock): wird, falls
#             gesetzt, als "Authorization: token ..."-Header an beide
#             GitHub-API-Aufrufe (Update-Check + OXICLOUD_VERSION_PIN=latest)
#             angehängt. Vermeidet, dass häufige automatisierte Läufe (Cron)
#             derselben IP ins anonyme GitHub-Rate-Limit (60 Requests/h)
#             laufen - was dank Fix 1) jetzt zwar nicht mehr hart abbricht,
#             aber weiterhin unschön wäre.
#          4) Automatischer Swapfile-Schutz wird jetzt NUR noch angelegt,
#             wenn tatsächlich ein Rebuild ansteht (NEED_BUILD=1). Vorher
#             wurde er bei knappem RAM bei JEDEM Lauf angelegt und am Ende
#             wieder entfernt, auch wenn gar nicht gebaut wurde - unnötiger
#             I/O-Aufwand bei reinen "nichts geändert"-Läufen.
#          5) Swapfile-Cleanup läuft jetzt über den bestehenden EXIT-Trap
#             (cleanup_on_exit, ersetzt/ergänzt notify_on_failure), nicht
#             mehr nur am glücklichen Skriptende. Vorher blieb ein
#             automatisch angelegter Swapfile bei jedem früheren Abbruch
#             (DB-Backup fehlgeschlagen, Migration fehlgeschlagen,
#             Health-Check fehlgeschlagen) dauerhaft aktiv + in /etc/fstab
#             eingetragen.
#          6) Neuer Symlink "current-good" neben "current": wird NUR nach
#             einem erfolgreichen Health-Check aktualisiert. Automatisches
#             Rollback zielt jetzt auf current-good statt auf "das zuletzt
#             modifizierte andere Release" - vorher war nicht sichergestellt,
#             dass das Rollback-Ziel selbst jemals gesund lief (Risiko bei
#             zwei aufeinanderfolgenden kaputten Commits).
#          7) Health-Check akzeptiert jetzt konfigurierbar entweder einen
#             dedizierten Endpoint (HEALTH_CHECK_PATH) oder "/", und
#             akzeptiert per HEALTH_CHECK_EXPECTED_CODES eine Liste
#             erwarteter HTTP-Codes statt nur 2xx via "curl -f" - vermeidet
#             Fehlalarme bei Diensten, die z.B. mit 301/401 auf "/" antworten.
#          8) Firewall-Hinweis (ufw) prüft jetzt zuerst, ob ufw überhaupt
#             AKTIV ist, bevor er vor einem "nicht freigegebenen Port" warnt -
#             vorher wurde bei inaktivem ufw fälschlich gewarnt, obwohl in
#             dem Fall gar nichts blockiert wird.
#          9) Vor dem Leeren eines nicht-leeren, aber noch nicht als
#             Git-Repo erkannten OXICLOUD_HOME wird jetzt zusätzlich ein
#             Tarball-Backup unter /etc/oxicloud/pre-clone-backups angelegt
#             (statt kommentarlosem "rm -rf") - konsistent zum sonstigen
#             Vorsichtsprinzip des Scripts (Backups vor .env/Unit/fstab).
#          10) set_env_var() escaped den Ersetzungswert jetzt für sed
#              (Sonderzeichen &, /, \\), damit z.B. eine ENV_OVERRIDE_BASE_URL
#              mit Sonderzeichen nicht zu einer fehlerhaften/kaputten .env
#              führt.
#          11) /etc/oxicloud selbst bekommt jetzt chmod 750 (vorher keine
#              expliziten Rechte) - verbirgt zumindest das Directory-Listing
#              (z.B. Dateinamen der DB-Backups) vor anderen lokalen Usern,
#              analog zum bestehenden Schutz von .env (640) und
#              .db_password (600).
#          12) ACTUAL_DISK_GB fällt jetzt sauber auf 0 zurück, falls die
#              df-Ermittlung eine leere Zeichenkette liefert (z.B. exotischer
#              OXICLOUD_HOME-Pfad), statt den späteren Integer-Vergleich mit
#              "integer expression expected" abstürzen zu lassen.
#          13) Neuer optionaler DRY_RUN-Modus (Standard false): loggt alle
#              destruktiven/ändernden Schritte (chown, git reset --hard,
#              Build, systemd restart, Swap/Firewall-Änderungen) nur, statt
#              sie auszuführen - nützlich zum Testen von Konfigurations-
#              änderungen ohne echten Effekt auf das System.
#   1.17 - Selbstheilung, falls "cargo build --release --locked" fehlschlägt,
#          weil die eingecheckte Cargo.lock nicht mehr zur Cargo.toml passt
#          (z.B. weil Upstream im main-Branch eine Abhängigkeit geändert/
#          hinzugefügt hat, ohne die Lockfile neu zu committen). Da dieses
#          Script standardmäßig ungepinnt dem main-Branch folgt, kann das
#          jederzeit erneut auftreten ("cannot update the lock file ...
#          because --locked was passed"). Der erste Build-Versuch bleibt
#          bewusst strikt mit "--locked" (damit ein "echter" Kompilierfehler
#          weiterhin sofort auffällt und nicht durch automatisches Neu-
#          Lock'en verschleiert wird). Schlägt er fehl, wird NUR die Lockfile
#          neu erzeugt (cargo generate-lockfile) und der Build danach genau
#          einmal erneut mit --locked versucht. Schlägt auch dieser zweite
#          Versuch fehl, liegt es an etwas anderem, und das Script bricht
#          regulär ab (set -e).
#   1.16 - Optionale Selbstprüfung auf neuere Script-Version (CHECK_FOR_UPDATES,
#          Standard true): vergleicht die Versionsnummer im main-Branch von
#          https://github.com/roswitina/oxicloud-install mit der lokal
#          laufenden SCRIPT_VERSION und gibt ggf. einen Hinweis aus - rein
#          informativ, lädt/ersetzt nichts automatisch. Fehlertolerant
#          (kein Abbruch bei fehlendem Internet/curl), auf höchstens einen
#          echten Check pro UPDATE_CHECK_INTERVAL_HOURS (Standard 24)
#          begrenzt, per CHECK_FOR_UPDATES=false komplett abschaltbar.
#   1.15 - Vier Verbesserungen nach Review:
#          1) Health-Check nach Rebuild wird jetzt übersprungen (mit klarer
#             Meldung), falls ENV_OVERRIDE_SERVER_HOST auf einen Wert
#             gesetzt ist, der NICHT 0.0.0.0/::/leer ist - z.B. eine feste
#             Interface-IP. In dem Fall lauscht der Dienst nicht (mehr) auf
#             127.0.0.1, der bisherige Health-Check hätte dort IMMER
#             fehlgeschlagen und bei jedem Rebuild fälschlich ein Rollback
#             ausgelöst, obwohl der Dienst einwandfrei läuft.
#          2) Health-Check läuft jetzt auch beim ALLERERSTEN Lauf (vorher
#             nur ab dem zweiten, weil da noch kein Rollback-Ziel existiert).
#             Schlägt er beim Erstlauf fehl, gibt es zwar kein Release zum
#             Zurückrollen, aber wenigstens eine deutliche Fehlermeldung
#             statt der bisherigen stillen Erfolgsmeldung trotz kaputtem
#             Dienst.
#          3) Tote Variable ROLLBACK_TRIGGERED entfernt (wurde gesetzt, aber
#             nie gelesen) - stattdessen fließt ein tatsächlich erfolgtes
#             Rollback jetzt in die Webhook-Fehlermeldung mit ein.
#          4) chown -R auf ${OXICLOUD_HOME} lief bisher bei JEDEM Lauf
#             bedingungslos, auch wenn ohnehin schon alles korrekt gehörte -
#             unnötig teuer bei großen Verzeichnissen (releases/, target/,
#             node_modules/). Jetzt wird zuerst geprüft, ob überhaupt etwas
#             falsch gehört, chown läuft nur noch wenn nötig.
#   1.14 - backup_file() (nutzt für .env, systemd-Unit, /etc/fstab) bereinigt
#          jetzt alte Zeitstempel-Backups (GENERIC_BACKUP_KEEP, Standard 10),
#          analog zu DB_BACKUP_KEEP/KEEP_RELEASES.
#   1.13 - Sieben Robustheits-Verbesserungen nach Review (Health-Check +
#          Rollback, DB-Backup vor Migration, Logrotate, git fetch+reset
#          statt pull, harter Disk-Abbruch vor Build, Firewall-Hinweis,
#          Webhook-Benachrichtigung bei Fehlschlag).
#   1.12 - "sudo" fehlte in der Preflight-Paketliste (LXC-Minimal-Templates).
#   1.11 - Node-LTS-Ermittlung gegen fehlschlagenden curl abgesichert,
#          DB-Passwort wird bei JEDEM Lauf durchgesetzt (ALTER ROLE),
#          DATABASE_URL wandert aus dem systemd-Unit-File (644) in die
#          restriktiver geschützte .env (640).
#
# Tested target: Debian/Ubuntu with systemd
# Requires: root privileges (or sudo)
#
# What this script does:
#   1. Preflight-Check: prüft benötigte Programme (git, curl, jq, openssl,
#      PostgreSQL, Node.js, Rust/cargo) und installiert/aktualisiert fehlende,
#      verifiziert direkt danach auch tatsächlich deren Verfügbarkeit.
#   2. Installs/updates Rust (rustup) and Node.js to the latest version
#      (or to a pinned version, see NODE_VERSION_PIN / RUST_VERSION_PIN below)
#   3. Creates a dedicated system user + PostgreSQL role/database. Stellt bei
#      jedem Lauf per rekursivem chown sicher, dass ${OXICLOUD_HOME}
#      durchgängig oxicloud:oxicloud gehört (nur falls nötig).
#   4. Clones/updates OxiCloud, configures /etc/oxicloud/.env. Bei bereits
#      bestehender .env werden fehlende Variablen aus einer neueren
#      example.env automatisch ergänzt. Standardmäßig wird immer der
#      main-Branch verfolgt; via OXICLOUD_VERSION_PIN kann stattdessen ein
#      festes Release/Tag verwendet werden. Lokale, nicht committete
#      Änderungen werden vor jedem Pull automatisch als Patch gesichert und
#      dann verworfen. sqlx-cli wird bei Bedarf installiert; "cargo sqlx
#      migrate run" wird bei JEDEM Lauf ausgeführt (idempotent).
#   5. Rebuilds frontend + release binary only if something actually changed.
#      Jede gebaute Binary wird nach ihrem Git-Commit-Hash versioniert unter
#      releases/ abgelegt; ein Symlink "current" zeigt auf die jeweils
#      aktive Version, "current-good" auf die zuletzt health-geprüfte.
#   6. Installs a systemd unit and (re)starts the service if needed, inkl.
#      automatischem Health-Check + Rollback auf "current-good" bei Bedarf.
#
# Idempotent: safe to re-run. DB password and .env values persist across runs.
#
# Version pinning: by default Node.js and Rust are always kept at the latest
# version. To pin them to a fixed version instead, set NODE_VERSION_PIN and/or
# RUST_VERSION_PIN in the configuration block below.
#
# DRY_RUN=true simuliert den Lauf: alle destruktiven/ändernden Schritte
# werden nur geloggt, nicht ausgeführt (siehe Konfigurationsblock).
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
# aktiv und mit identischem Release-Stand. Bitte einmal selbst verifizieren,
# welcher Remote für euch "der kanonische" ist, bevor ihr produktiv darauf
# setzt. Standardmäßig auf AtalayaLabs umgestellt.
REPO_URL="https://github.com/AtalayaLabs/OxiCloud.git"

# Script-Version (siehe Header-Kommentar oben)
SCRIPT_VERSION="1.19"

# Simulationsmodus: true = keine echten Änderungen am System, nur Logging.
# Nützlich um z.B. eine geänderte Konfiguration (ENV_OVERRIDE_*, Pins, ...)
# vorab durchzuspielen, ohne den laufenden Dienst zu beeinflussen.
DRY_RUN=false

# Versionierte Binaries: nach jedem Build wird die Binary nach ihrem
# Git-Commit-Hash benannt und unter releases/ abgelegt.
#   current      = zeigt auf die zuletzt gebaute/aktive Binary
#   current-good = zeigt auf die zuletzt Health-Check-geprüfte Binary,
#                  wird NUR nach erfolgreichem Health-Check aktualisiert und
#                  dient als verlässliches automatisches Rollback-Ziel.
RELEASES_DIR="${OXICLOUD_HOME}/releases"
CURRENT_LINK="${OXICLOUD_HOME}/current"
CURRENT_GOOD_LINK="${OXICLOUD_HOME}/current-good"

# Wie viele alte Releases behalten werden (für schnelles manuelles Rollback).
# 0 = keine Bereinigung, alle Releases werden dauerhaft behalten.
KEEP_RELEASES=5

# Versionen festnageln (optional). Leer lassen ("") = jeweils automatisch neueste Version verwenden.
NODE_VERSION_PIN=""
RUST_VERSION_PIN=""

# .env-Werte gezielt überschreiben (optional). Leer lassen ("") = den Wert
# aus example.env unverändert übernehmen.
ENV_OVERRIDE_SERVER_HOST=""
ENV_OVERRIDE_BASE_URL=""

# OxiCloud-Version festnageln (optional). Leer lassen ("") = immer der
# neueste Stand des main-Branches. "latest" = neuestes GitHub-Release.
# "vX.Y.Z" = exakt dieser Tag.
OXICLOUD_VERSION_PIN=""

# WASM-Plugin-Runtime (Extism) aktivieren. Erfordert das Cargo-Feature
# "plugins" beim Bauen.
ENABLE_PLUGINS=false

# Optionaler Webhook, der bei einem fehlgeschlagenen Lauf (Exit-Code != 0)
# aufgerufen wird. Leer lassen ("") = keine Benachrichtigung (Standard).
NOTIFY_WEBHOOK_URL=""

# Wie viele Zeitstempel-Backups PRO DATEI behalten werden (.env, systemd-
# Unit, /etc/fstab). 0 = keine Bereinigung.
GENERIC_BACKUP_KEEP=10

# Wie viele Datenbank-Backups (pg_dump, vor jeder Migration) behalten werden.
# 0 = keine Bereinigung.
DB_BACKUP_KEEP=10

# Unterhalb dieser freien GB unter ${OXICLOUD_HOME%/*} bricht das Script
# VOR dem Build hart ab.
DISK_ABORT_THRESHOLD_GB=5

# Wie oft (im 2-Sekunden-Abstand) der Health-Check nach einem Rebuild
# versucht wird, bevor automatisch auf "current-good" zurückgerollt wird.
HEALTH_RETRIES=10

# Health-Check-Konfiguration: Pfad und akzeptierte HTTP-Statuscodes (durch
# Leerzeichen getrennt). Manche Dienste antworten auf "/" z.B. mit einem
# Redirect (301/302) oder verlangen Auth (401) statt eines nackten 200 -
# das ist dann trotzdem ein Zeichen, dass der Dienst lebt und antwortet.
HEALTH_CHECK_PATH="/"
HEALTH_CHECK_EXPECTED_CODES="200 301 302 401"

# Prüft bei jedem Lauf (höchstens alle UPDATE_CHECK_INTERVAL_HOURS Stunden),
# ob im GitHub-Repo eine andere Script-Version dieses Scripts liegt als die
# lokal laufende - reine Information, KEIN automatisches Update.
CHECK_FOR_UPDATES=true
UPDATE_CHECK_REPO="roswitina/oxicloud-install"
UPDATE_CHECK_BRANCH="main"
UPDATE_CHECK_INTERVAL_HOURS=24
UPDATE_CHECK_CACHE="/etc/oxicloud/.update-check-install-oxicloud"

# Optionales GitHub-Token (z.B. "ghp_xxx" oder ein Fine-Grained-Token ohne
# besondere Rechte, nur zum Anheben des anonymen Rate-Limits). Wird, falls
# gesetzt, als "Authorization: token ..."-Header an alle GitHub-API-Aufrufe
# (Update-Check + OXICLOUD_VERSION_PIN=latest) angehängt. Leer lassen ("")
# = anonyme Aufrufe wie bisher (Standard-Rate-Limit von GitHub gilt).
GITHUB_TOKEN=""
### ---------------------------------------------------------------------------

# ---- Hilfsfunktion: GitHub-Requests optional mit Token authentifizieren ---
github_curl() {
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    curl -H "Authorization: token ${GITHUB_TOKEN}" "$@"
  else
    curl "$@"
  fi
}

# ---- DRY_RUN-Hilfsfunktion: führt einen Befehl nur aus, wenn DRY_RUN=false -
# Gibt bei DRY_RUN=true stattdessen den Befehl geloggt aus. Für einfache,
# klar abgegrenzte destruktive/ändernde Einzelbefehle gedacht (chown,
# systemctl, ln, rm, mkswap/swapon, ...). Größere Blöcke (Build, Migration)
# werden weiter unten jeweils mit einem eigenen "if [[ "${DRY_RUN}" == true"
# umschlossen, da sie aus mehreren Befehlen bestehen bzw. Rückgabewerte
# auswerten müssen.
run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde ausführen: $*"
  else
    "$@"
  fi
}

# ---- Fehler-Benachrichtigung + Aufräumarbeiten (optional) ------------------
# Läuft das Script unbeaufsichtigt per Cron, fällt ein fehlgeschlagener Lauf
# sonst erst auf, wenn der Dienst schon länger down ist. Bei Exit-Code != 0
# und gesetztem NOTIFY_WEBHOOK_URL wird eine kurze Meldung per POST an den
# Webhook geschickt. Zusätzlich (Fix 1.18/5): räumt einen in DIESEM Lauf
# automatisch angelegten Swapfile IMMER auf, auch bei einem Abbruch vor dem
# regulären Skriptende (vorher blieb er in dem Fall dauerhaft aktiv +
# in /etc/fstab eingetragen). Absichtlich robust gegen eigene Fehler
# ("|| true" überall), damit weder Benachrichtigung noch Cleanup selbst
# jemals den eigentlichen Exit-Code verschlucken.
ROLLBACK_STATUS=""
SWAP_FILE="/swapfile"
SWAP_AUTO_CREATED=0
cleanup_on_exit() {
  local exit_code=$?

  if [[ "${SWAP_AUTO_CREATED}" -eq 1 ]]; then
    echo "==> Cleanup: entferne automatisch angelegten Swapfile ${SWAP_FILE} wieder..." >&2
    swapoff "${SWAP_FILE}" 2>/dev/null || true
    rm -f "${SWAP_FILE}" 2>/dev/null || true
    sed -i "\#^${SWAP_FILE} #d" /etc/fstab 2>/dev/null || true
  fi

  if [[ "${exit_code}" -ne 0 && -n "${NOTIFY_WEBHOOK_URL}" ]]; then
    local host
    host="$(hostname 2>/dev/null || echo unknown)"
    local msg="OxiCloud install/update auf '${host}' fehlgeschlagen (Exit-Code ${exit_code})."
    [[ -n "${ROLLBACK_STATUS}" ]] && msg="${msg} ${ROLLBACK_STATUS}"
    msg="${msg} Log: ${LOG_FILE:-/var/log/oxicloud-install.log}"
    curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
      -d "$(printf '{"text":"%s"}' "${msg//\"/\\\"}")" \
      "${NOTIFY_WEBHOOK_URL}" >/dev/null 2>&1 || true
  fi
  return "${exit_code}"
}
trap cleanup_on_exit EXIT

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root bzw. mit sudo ausführen." >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "======================================================================"
  echo " DRY_RUN=true: Es werden KEINE echten Änderungen am System vorgenommen."
  echo " Destruktive/ändernde Schritte werden nur geloggt."
  echo "======================================================================"
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
    local base="$(basename "${file}")"
    local backup_path="${backup_dir}/${base}.${ts}.bak"
    if [[ -e "${backup_path}" ]]; then
      backup_path="${backup_dir}/${base}.${ts}-$$.bak"
    fi
    cp -p "${file}" "${backup_path}"
    echo "    Backup angelegt: ${backup_path}"

    if [[ "${GENERIC_BACKUP_KEEP}" -gt 0 ]]; then
      local backup_count
      backup_count="$(find "${backup_dir}" -maxdepth 1 -type f -name "${base}.*.bak" | wc -l)"
      if [[ "${backup_count}" -gt "${GENERIC_BACKUP_KEEP}" ]]; then
        find "${backup_dir}" -maxdepth 1 -type f -name "${base}.*.bak" -printf '%T@ %p\n' \
          | sort -rn | tail -n +"$((GENERIC_BACKUP_KEEP + 1))" | cut -d' ' -f2- \
          | while IFS= read -r old_backup; do rm -f "${old_backup}"; done
      fi
    fi
  fi
}

# ---- Ressourcen-Hinweis für den Kompiliervorgang ---------------------------
RECOMMENDED_BUILD_CPUS=4
RECOMMENDED_BUILD_RAM_GB=16
RECOMMENDED_BUILD_DISK_GB=20
ACTUAL_CPUS="$(nproc)"
ACTUAL_RAM_GB="$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024))"
# Fix (1.18/12): df-Ermittlung kann bei einem exotischen/nicht existierenden
# OXICLOUD_HOME-Elternverzeichnis eine leere Zeichenkette liefern - das ließ
# den späteren Integer-Vergleich ("-lt") mit "integer expression expected"
# abstürzen. ": ${VAR:=0}" erzwingt jetzt sauber 0 als Fallback.
ACTUAL_DISK_GB="$(df --output=avail -BG "${OXICLOUD_HOME%/*}" 2>/dev/null | tail -1 | tr -dc '0-9')"
: "${ACTUAL_DISK_GB:=0}"

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
if [[ "${ACTUAL_DISK_GB}" -lt "${DISK_ABORT_THRESHOLD_GB}" ]]; then
  echo "FEHLER: Nur noch ca. ${ACTUAL_DISK_GB} GB frei unter ${OXICLOUD_HOME%/*}" >&2
  echo "(kritischer Schwellwert: ${DISK_ABORT_THRESHOLD_GB} GB). Breche vor dem Build ab," >&2
  echo "um einen mittendrin abgebrochenen 'cargo build' durch vollgelaufene Platte zu vermeiden." >&2
  echo "Bitte zuerst Speicherplatz freigeben (z.B. alte Releases unter ${RELEASES_DIR}," >&2
  echo "alte DB-Backups unter /etc/oxicloud/db-backups, apt-get clean) und erneut versuchen." >&2
  exit 1
fi

echo "==> Preflight-Check: prüfe Basis-Pakete und installiere fehlende nach..."
REQUIRED_APT_PACKAGES=(sudo git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
MISSING_PACKAGES=()
for pkg in "${REQUIRED_APT_PACKAGES[@]}"; do
  dpkg -s "${pkg}" &>/dev/null || MISSING_PACKAGES+=("${pkg}")
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
  echo "    Fehlende Pakete werden installiert: ${MISSING_PACKAGES[*]}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde ausführen: apt-get update -y && apt-get install -y ${MISSING_PACKAGES[*]}"
  else
    apt-get update -y
    apt-get install -y "${MISSING_PACKAGES[@]}"
  fi
else
  echo "    Alle benötigten Basis-Pakete sind bereits installiert."
fi

# ---- Fix (1.18/2): Dependency-Verifizierung VOR jeder weiteren Nutzung ----
# Vorher lief dieser Check erst kurz vor dem Build - also NACH DB-Backup und
# "cargo sqlx migrate run", die beide bereits psql bzw. cargo voraussetzen.
# Fehlte eines der Tools trotz Preflight (z.B. weil apt-get install aus
# irgendeinem Grund unvollständig blieb), scheiterte der Lauf vorher mit
# einem unklaren Fehler mitten in der DB-Logik. Jetzt direkt hier, bevor
# irgendetwas anderes davon abhängt (Node/Rust-Installation ausgenommen,
# die folgen erst als Nächstes und installieren sich bei Bedarf selbst).
echo "==> Verifiziere, dass die Basis-Programme tatsächlich verfügbar sind..."
for cmd in git curl jq openssl psql; do
  command -v "${cmd}" &>/dev/null || { echo "Fehler: '${cmd}' ist trotz Installationsversuch nicht verfügbar." >&2; exit 1; }
done
echo "    Basis-Abhängigkeiten sind vorhanden (Node/npm/cargo werden weiter unten installiert/geprüft)."

# ---- Selbstprüfung auf neuere Script-Version (rein informativ) ------------
# Fix (1.19): Das Ergebnis dieses Checks stand bisher NUR mitten im
# scrollenden Lauf-Output - im finalen Zusammenfassungsblock am Scriptende
# (der Teil, den man tatsächlich anschaut) tauchte es nicht mehr auf und
# ging damit leicht unter, ohne dass man Grund hätte, extra ins Install-Log
# zu schauen. UPDATE_AVAILABLE_VERSION hält das Ergebnis jetzt über den
# Rest des Laufs hinweg fest, damit der Abschlussblock es erneut anzeigen
# kann. Die Cache-Datei speichert dafür zusätzlich zum Zeitstempel (weiterhin
# erste Zeile, unverändertes Format für Abwärtskompatibilität mit älteren
# Läufen) jetzt optional eine zweite Zeile mit der zuletzt bekannten
# Remote-Version - so lässt sich der Hinweis auch dann noch im
# Abschlussblock anzeigen, wenn der eigentliche GitHub-Abruf in DIESEM Lauf
# wegen UPDATE_CHECK_INTERVAL_HOURS übersprungen wurde, der letzte
# tatsächliche Check (an einem Vortag) aber schon eine neuere Version fand.
UPDATE_AVAILABLE_VERSION=""
if [[ "${CHECK_FOR_UPDATES}" == "true" ]] && command -v curl &>/dev/null; then
  DO_UPDATE_CHECK=1
  CACHED_REMOTE_VERSION=""
  if [[ -f "${UPDATE_CHECK_CACHE}" ]]; then
    LAST_CHECK_EPOCH="$(sed -n '1p' "${UPDATE_CHECK_CACHE}" 2>/dev/null || echo 0)"
    CACHED_REMOTE_VERSION="$(sed -n '2p' "${UPDATE_CHECK_CACHE}" 2>/dev/null || echo "")"
    NOW_EPOCH="$(date +%s)"
    AGE_HOURS=$(( (NOW_EPOCH - LAST_CHECK_EPOCH) / 3600 ))
    [[ "${AGE_HOURS}" -lt "${UPDATE_CHECK_INTERVAL_HOURS}" ]] && DO_UPDATE_CHECK=0
  fi

  if [[ "${DO_UPDATE_CHECK}" -eq 1 ]]; then
    REMOTE_RAW_SCRIPT="$(github_curl -fsS -m 5 \
      "https://raw.githubusercontent.com/${UPDATE_CHECK_REPO}/${UPDATE_CHECK_BRANCH}/install-oxicloud.sh" 2>/dev/null)" || true
    if [[ -n "${REMOTE_RAW_SCRIPT}" ]]; then
      REMOTE_SCRIPT_VERSION="$(printf '%s\n' "${REMOTE_RAW_SCRIPT}" | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"
      if [[ -n "${REMOTE_SCRIPT_VERSION}" && "${REMOTE_SCRIPT_VERSION}" != "${SCRIPT_VERSION}" ]]; then
        UPDATE_AVAILABLE_VERSION="${REMOTE_SCRIPT_VERSION}"
        echo ""
        echo "Hinweis: Auf GitHub liegt eine andere Version von install-oxicloud.sh"
        echo "         (lokal: ${SCRIPT_VERSION}, dort auf '${UPDATE_CHECK_BRANCH}': ${REMOTE_SCRIPT_VERSION})."
        echo "         https://github.com/${UPDATE_CHECK_REPO}"
        echo "         (Dieser Hinweis erscheint am Ende auch nochmal in der Zusammenfassung.)"
        echo ""
      fi
    fi
    mkdir -p "$(dirname "${UPDATE_CHECK_CACHE}")" 2>/dev/null || true
    { date +%s; echo "${UPDATE_AVAILABLE_VERSION}"; } > "${UPDATE_CHECK_CACHE}" 2>/dev/null || true
  elif [[ -n "${CACHED_REMOTE_VERSION}" && "${CACHED_REMOTE_VERSION}" != "${SCRIPT_VERSION}" ]]; then
    # Check heute schon gelaufen (Cache greift), letzter tatsächlicher Check
    # hatte aber eine neuere Version gefunden - Hinweis bleibt sichtbar,
    # bis entweder das Script aktualisiert wird oder ein neuer echter Check
    # dieselbe Version bestätigt (dann wird der Cache-Eintrag oben beim
    # nächsten echten Check ohnehin durch die aktuelle Remote-Version
    # überschrieben).
    UPDATE_AVAILABLE_VERSION="${CACHED_REMOTE_VERSION}"
  fi
fi

if [[ -n "${NODE_VERSION_PIN}" ]]; then
  echo "==> Node.js-Version ist festgenagelt auf ${NODE_VERSION_PIN}.x"
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
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde Node.js ${LATEST_LTS_MAJOR}.x installieren."
  else
    curl -fsSL "https://deb.nodesource.com/setup_${LATEST_LTS_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi
else
  echo "    Node.js ${CURRENT_NODE_MAJOR}.x ist bereits die aktuelle LTS-Major-Version, prüfe auf Patch-Updates..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde 'apt-get install --only-upgrade -y nodejs' ausführen."
  else
    apt-get update -y
    apt-get install --only-upgrade -y nodejs
  fi
fi

echo "==> Stelle sicher, dass PostgreSQL läuft..."
run systemctl enable --now postgresql

echo "==> Ermittle/erzeuge DB-Passwort (bleibt über mehrere Läufe hinweg stabil)..."
DB_PASS_FILE="/etc/oxicloud/.db_password"
mkdir -p /etc/oxicloud
chmod 750 /etc/oxicloud
if [[ -f "${DB_PASS_FILE}" ]]; then
  DB_PASS="$(cat "${DB_PASS_FILE}")"
  DB_PASS_IS_NEW=0
else
  DB_PASS="$(openssl rand -hex 16)"
  DB_PASS_IS_NEW=1
fi

echo "==> Lege PostgreSQL-Rolle und Datenbank an (falls noch nicht vorhanden)..."
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "    [DRY_RUN] würde Rolle/Datenbank '${DB_USER}'/'${DB_NAME}' anlegen (falls nötig) und Passwort setzen."
else
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';"

  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

  echo "==> Stelle sicher, dass das DB-Passwort mit ${DB_PASS_FILE} übereinstimmt..."
  sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
fi

if [[ "${DB_PASS_IS_NEW}" -eq 1 && "${DRY_RUN}" != "true" ]]; then
  echo -n "${DB_PASS}" > "${DB_PASS_FILE}"
  chmod 600 "${DB_PASS_FILE}"
fi

DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}"

echo "==> Teste Datenbankverbindung mit den ermittelten Zugangsdaten..."
if [[ "${DRY_RUN}" != "true" ]]; then
  if ! PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "FEHLER: Verbindung zur Datenbank '${DB_NAME}' als '${DB_USER}' schlägt fehl," >&2
    echo "obwohl Rolle/Datenbank/Passwort gerade eben gesetzt wurden." >&2
    echo "Mögliche Ursachen: PostgreSQL-Authentifizierungsmethode in pg_hba.conf" >&2
    echo "erlaubt kein Passwort-Login für 'localhost' (z.B. 'peer' statt 'md5'/'scram-sha-256')." >&2
    echo "Prüfen: cat /etc/postgresql/*/main/pg_hba.conf | grep -v '^#'" >&2
    exit 1
  fi
  echo "    Datenbankverbindung erfolgreich verifiziert."
else
  echo "    [DRY_RUN] übersprungen."
fi

echo "==> Lege Systembenutzer '${OXICLOUD_USER}' an..."
if [[ "${DRY_RUN}" == "true" ]]; then
  id -u "${OXICLOUD_USER}" &>/dev/null || echo "    [DRY_RUN] würde useradd für '${OXICLOUD_USER}' ausführen."
else
  id -u "${OXICLOUD_USER}" &>/dev/null || useradd -r -M -d "${OXICLOUD_HOME}" -s /usr/sbin/nologin "${OXICLOUD_USER}"
fi

mkdir -p "${OXICLOUD_HOME}"
if [[ -n "$(find "${OXICLOUD_HOME}" \( ! -user "${OXICLOUD_USER}" -o ! -group "${OXICLOUD_USER}" \) -print -quit 2>/dev/null)" ]]; then
  echo "==> ${OXICLOUD_HOME} enthält falsch gehörende Dateien, korrigiere auf ${OXICLOUD_USER}:${OXICLOUD_USER}..."
  run chown -R "${OXICLOUD_USER}:${OXICLOUD_USER}" "${OXICLOUD_HOME}"
else
  echo "==> ${OXICLOUD_HOME} gehört bereits durchgängig ${OXICLOUD_USER}:${OXICLOUD_USER}, überspringe chown."
fi

echo "==> Klone/aktualisiere OxiCloud in ${OXICLOUD_HOME}..."
NEED_BUILD=0

resolve_target_ref() {
  if [[ -z "${OXICLOUD_VERSION_PIN}" ]]; then
    echo "main"
  elif [[ "${OXICLOUD_VERSION_PIN}" == "latest" ]]; then
    local tag
    # Fix (1.18/1): war zuvor NICHT gegen einen fehlschlagenden curl
    # abgesichert - unter "set -e -o pipefail" brach die Pipe bei z.B.
    # fehlendem Internet oder GitHub-Rate-Limit sofort und stillschweigend
    # ab, die Fehlerbehandlung direkt darunter wurde nie erreicht. "|| true"
    # erzwingt jetzt Exit-Code 0 für die Pipe; "tag" bleibt dann einfach
    # leer und die folgende Prüfung greift wie vorgesehen.
    tag="$(github_curl -fsSL https://api.github.com/repos/AtalayaLabs/OxiCloud/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)" || true
    if [[ -z "${tag}" ]]; then
      echo "Fehler: Konnte neuestes GitHub-Release nicht ermitteln (API nicht erreichbar, Rate-Limit erreicht oder keine Releases vorhanden)." >&2
      echo "Tipp: GITHUB_TOKEN im Konfigurationsblock setzen, falls das Rate-Limit die Ursache ist." >&2
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
    # Fix (1.18/9): Vorher wurde ein nicht-leeres, aber noch nicht als
    # Git-Repo erkanntes OXICLOUD_HOME kommentarlos per "rm -rf" geleert -
    # im Gegensatz zu .env/systemd-Unit/fstab, für die es explizite Backups
    # gibt. Falls hier versehentlich ein bereits genutztes Verzeichnis
    # konfiguriert wurde, sichern wir den Inhalt vorher als Tarball.
    echo "    Verzeichnis ${OXICLOUD_HOME} ist nicht leer, aber noch kein Git-Repo."
    PRE_CLONE_BACKUP_DIR="/etc/oxicloud/pre-clone-backups"
    mkdir -p "${PRE_CLONE_BACKUP_DIR}"
    PRE_CLONE_BACKUP_FILE="${PRE_CLONE_BACKUP_DIR}/oxicloud-home-$(date '+%Y%m%d-%H%M%S').tar.gz"
    echo "    Sichere bestehenden Inhalt vorsichtshalber unter: ${PRE_CLONE_BACKUP_FILE}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "    [DRY_RUN] würde Tarball anlegen und danach ${OXICLOUD_HOME} leeren."
    else
      tar -czf "${PRE_CLONE_BACKUP_FILE}" -C "$(dirname "${OXICLOUD_HOME}")" "$(basename "${OXICLOUD_HOME}")" 2>/dev/null || \
        echo "    WARNUNG: Tarball-Backup konnte nicht angelegt werden, fahre trotzdem fort." >&2
      find "${OXICLOUD_HOME}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde 'git clone ${REPO_URL} ${OXICLOUD_HOME}' ausführen."
    OLD_REV="none"
    NEED_BUILD=1
  else
    sudo -u "${OXICLOUD_USER}" git clone "${REPO_URL}" "${OXICLOUD_HOME}"
    OLD_REV="none"
  fi
else
  OLD_REV="$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" rev-parse HEAD)"
  echo "    Repo existiert bereits, hole Updates (inkl. Tags)..."
  run sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" fetch --tags --force origin

  if [[ -n "$(sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" status --porcelain --untracked-files=no)" ]]; then
    echo "    WARNUNG: Lokale, nicht committete Änderungen an getrackten Dateien gefunden."
    echo "    /opt/oxicloud soll ausschließlich vom Script verwaltet werden - sichere die"
    echo "    Änderungen als Patch und verwerfe sie, damit Checkout/Pull sauber laufen kann."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "    [DRY_RUN] würde Patch sichern und 'git reset --hard HEAD' ausführen."
    else
      PATCH_DIR="${OXICLOUD_HOME}/local-changes-backup"
      mkdir -p "${PATCH_DIR}"
      chown "${OXICLOUD_USER}:${OXICLOUD_USER}" "${PATCH_DIR}"
      PATCH_FILE="${PATCH_DIR}/discarded-$(date '+%Y%m%d-%H%M%S').patch"
      sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" diff > "${PATCH_FILE}"
      echo "    Patch gesichert unter: ${PATCH_FILE}"
      sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" reset --hard HEAD
    fi
  fi
fi

if [[ "${DRY_RUN}" != "true" ]]; then
  if [[ "${TARGET_REF}" == "main" ]]; then
    sudo -u "${OXICLOUD_USER}" git -C "${OXICLOUD_HOME}" checkout main
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
else
  NEW_REV="${OLD_REV}"
  echo "    [DRY_RUN] Checkout/Reset übersprungen."
fi

if [[ ! -e "${CURRENT_LINK}" ]]; then
  NEED_BUILD=1
fi

echo "==> Installiere/aktualisiere Rust (rustup) für Benutzer ${OXICLOUD_USER}..."
if ! sudo -u "${OXICLOUD_USER}" bash -c 'command -v cargo' &>/dev/null; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde rustup installieren."
  else
    sudo -u "${OXICLOUD_USER}" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
  fi
fi
RUSTUP_ENV="${OXICLOUD_HOME}/.cargo/env"

OLD_RUST_VERSION="$(sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo --version" 2>/dev/null || echo "none")"

if [[ "${DRY_RUN}" != "true" ]]; then
  if [[ -n "${RUST_VERSION_PIN}" ]]; then
    echo "    Rust-Version ist festgenagelt auf ${RUST_VERSION_PIN}"
    sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && rustup toolchain install ${RUST_VERSION_PIN} && rustup default ${RUST_VERSION_PIN}"
  else
    echo "    Prüfe auf Rust-Updates (rustup update stable)..."
    sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && rustup update stable && rustup default stable"
  fi
  NEW_RUST_VERSION="$(sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo --version")"
else
  echo "    [DRY_RUN] Rust-Update übersprungen."
  NEW_RUST_VERSION="${OLD_RUST_VERSION}"
fi

if [[ "${OLD_RUST_VERSION}" != "${NEW_RUST_VERSION}" ]]; then
  echo "    Rust-Toolchain hat sich geändert (${OLD_RUST_VERSION} -> ${NEW_RUST_VERSION}), Rebuild erforderlich."
  NEED_BUILD=1
fi

echo "==> Prüfe, ob sqlx-cli (für Datenbank-Migrationen) installiert ist..."
if ! sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && command -v sqlx" &>/dev/null; then
  echo "    sqlx-cli nicht gefunden, installiere es (kann einige Minuten dauern)..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde sqlx-cli installieren."
  else
    sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && cargo install sqlx-cli --no-default-features --features rustls,postgres"
  fi
else
  echo "    sqlx-cli ist bereits installiert."
fi

# ---- Verifiziere ALLE benötigten Programme (inkl. Node/cargo) --------------
echo "==> Verifiziere, dass Node.js/npm/cargo tatsächlich verfügbar sind..."
if [[ "${DRY_RUN}" != "true" ]]; then
  command -v node &>/dev/null || { echo "Fehler: 'node' ist nicht verfügbar." >&2; exit 1; }
  command -v npm  &>/dev/null || { echo "Fehler: 'npm' ist nicht verfügbar." >&2; exit 1; }
  sudo -u "${OXICLOUD_USER}" bash -c "source '${RUSTUP_ENV}' && command -v cargo" &>/dev/null \
    || { echo "Fehler: 'cargo' ist für Benutzer ${OXICLOUD_USER} nicht verfügbar." >&2; exit 1; }
  echo "    Alle Abhängigkeiten sind vorhanden."
else
  echo "    [DRY_RUN] übersprungen."
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
BUILD_MARKER_FILE="/etc/oxicloud/.last_build_ok"
EXPECTED_MARKER="${NEW_REV}|${BUILD_FEATURES}"
LAST_BUILD_OK="$(cat "${BUILD_MARKER_FILE}" 2>/dev/null || echo "")"
if [[ "${LAST_BUILD_OK}" != "${EXPECTED_MARKER}" ]]; then
  echo "    Letzter erfolgreicher Build passt nicht zum aktuellen Stand (Commit/Features), Rebuild erforderlich."
  NEED_BUILD=1
fi

# ---- Automatischer Swapfile als OOM-Schutz, falls nötig --------------------
# Fix (1.18/4): Wird jetzt NUR noch angelegt, wenn tatsächlich ein Rebuild
# ansteht (NEED_BUILD=1) - vorher lief das bei knappem RAM bei JEDEM Lauf,
# auch bei reinen "nichts geändert"-Läufen, unnötig teuer (fallocate +
# mkswap + swapon + swapoff + rm bei jedem Aufruf).
# Fix (1.18/5): Cleanup läuft jetzt über den EXIT-Trap (cleanup_on_exit
# oben), damit ein bei einem SPÄTEREN Abbruch (Build/Migration/Health-Check
# schlägt fehl) angelegter Swapfile nicht dauerhaft aktiv bleibt.
SWAP_SIZE_GB=8

if [[ "${NEED_BUILD}" -eq 1 && "${ACTUAL_RAM_GB}" -lt "${RECOMMENDED_BUILD_RAM_GB}" ]] && ! swapon --show | grep -q .; then
  echo "==> Wenig RAM erkannt, Rebuild ansteht und kein Swap aktiv: lege automatisch einen ${SWAP_SIZE_GB} GB Swapfile an (${SWAP_FILE})..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde Swapfile ${SWAP_FILE} (${SWAP_SIZE_GB} GB) anlegen und aktivieren."
  else
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
    echo "    >>> Er wird nach Abschluss dieses Laufs (Erfolg oder Fehlschlag) automatisch wieder entfernt."
  fi
  echo ""
fi

echo "==> Erzeuge Konfigurationsverzeichnis /etc/oxicloud und .env..."
CONFIG_DIR="/etc/oxicloud"
STORAGE_DIR="/mnt/oxicloud-data/storage"
STATIC_DIR="${OXICLOUD_HOME}/static"

mkdir -p "${CONFIG_DIR}"
chmod 750 "${CONFIG_DIR}"
if [[ ! -f "${CONFIG_DIR}/.env" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde ${OXICLOUD_HOME}/example.env nach ${CONFIG_DIR}/.env kopieren."
  else
    cp "${OXICLOUD_HOME}/example.env" "${CONFIG_DIR}/.env"
  fi
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
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "    [DRY_RUN] würde ${#ADDED_KEYS[@]} neue Variable(n) ergänzen: $(printf '%s ' "${ADDED_KEYS[@]%%=*}")"
    else
      backup_file "${CONFIG_DIR}/.env"
      {
        echo ""
        echo "# --- Automatisch ergänzt aus example.env am $(date '+%Y-%m-%d %H:%M:%S') ---"
        printf '%s\n' "${ADDED_KEYS[@]}"
      } >> "${CONFIG_DIR}/.env"
      echo "    Neue Variablen ergänzt (${#ADDED_KEYS[@]}): $(printf '%s ' "${ADDED_KEYS[@]%%=*}")"
    fi
  else
    echo "    Keine neuen Variablen gefunden, .env bereits vollständig."
  fi
fi

mkdir -p "${STORAGE_DIR}"
run chown -R "${OXICLOUD_USER}:${OXICLOUD_USER}" "${STORAGE_DIR}"

if ! mountpoint -q /mnt; then
  echo "    Hinweis: /mnt scheint kein eigener Mountpoint (keine separate Platte/Partition) zu sein."
  echo "    ${STORAGE_DIR} liegt damit trotz Trennung im Verzeichnisbaum physisch auf derselben Platte wie das OS."
  echo "    Falls gewünscht: separate Platte/Partition vorher unter /mnt einhängen (z.B. via /etc/fstab), dann Script erneut ausführen."
fi

# Fix (1.18/10): set_env_var() escaped den Wert jetzt für sed, damit
# Sonderzeichen (&, /, \) im Wert (z.B. eine ENV_OVERRIDE_BASE_URL mit
# Query-String oder Fragment) nicht zu einer fehlerhaften Ersetzung oder
# einer kaputten .env führen.
set_env_var() {
  local key="$1" value="$2" file="$3"
  local escaped_value
  escaped_value="$(printf '%s' "${value}" | sed -e 's/[&/\]/\\&/g')"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [DRY_RUN] würde in ${file} setzen: ${key}=${value}"
    return
  fi
  if grep -q "^${key}=" "${file}"; then
    sed -i "s#^${key}=.*#${key}=${escaped_value}#" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

if [[ "${DRY_RUN}" != "true" ]]; then
  backup_file "${CONFIG_DIR}/.env"
fi
set_env_var "OXICLOUD_DB_CONNECTION_STRING" "${DATABASE_URL}" "${CONFIG_DIR}/.env"
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
      # Fix (1.18/8): Vorher wurde direkt gegen "^PORT... ALLOW" gegrept,
      # ohne vorher zu prüfen, ob ufw überhaupt AKTIV ist. Bei inaktivem ufw
      # matcht das Grep natürlich nicht -> es wurde fälschlich vor einem
      # "nicht freigegebenen Port" gewarnt, obwohl inaktives ufw gar nichts
      # blockiert (Port ist dann sowieso offen).
      if ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -qE "^${OXICLOUD_PORT}(/tcp)?[[:space:]]+ALLOW"; then
          echo "    ACHTUNG: ufw ist AKTIV, aber Port ${OXICLOUD_PORT}/tcp scheint dort nicht"
          echo "    freigegeben zu sein. Ohne separate Freigabe sollte der Port also NICHT von"
          echo "    außen erreichbar sein - falls du das aber (z.B. übers LAN) doch willst:"
          echo "    'ufw allow ${OXICLOUD_PORT}/tcp'."
        fi
      else
        echo "    Hinweis: ufw ist installiert, aber INAKTIV - es blockiert aktuell nichts."
        echo "    Bitte manuell sicherstellen (z.B. über nftables/iptables, Cloud-Security-Group"
        echo "    oder durch Aktivieren von ufw), dass Port ${OXICLOUD_PORT}/tcp nicht"
        echo "    versehentlich offen ins Internet zeigt."
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

if [[ "${DRY_RUN}" != "true" ]]; then
  chown root:"${OXICLOUD_USER}" "${CONFIG_DIR}/.env"
  chmod 640 "${CONFIG_DIR}/.env"
fi

echo "==> Erstelle Datenbank-Backup vor der Migration..."
DB_BACKUP_DIR="/etc/oxicloud/db-backups"
mkdir -p "${DB_BACKUP_DIR}"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "    [DRY_RUN] würde pg_dump-Backup von '${DB_NAME}' anlegen."
else
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
fi

echo "==> Führe ausstehende Datenbank-Migrationen aus (sqlx migrate run)..."
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "    [DRY_RUN] würde 'cargo sqlx migrate run' ausführen."
else
  sudo -u "${OXICLOUD_USER}" bash -c "
    source '${RUSTUP_ENV}'
    cd '${OXICLOUD_HOME}'
    export DATABASE_URL='${DATABASE_URL}'
    cargo sqlx migrate run
  "
fi

if [[ "${NEED_BUILD}" -eq 1 ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "==> [DRY_RUN] würde Frontend + Release-Binary neu bauen."
  else
    echo "==> Baue das Frontend (npm)..."
    sudo -u "${OXICLOUD_USER}" bash -c "
      cd '${OXICLOUD_HOME}/frontend'
      npm ci
      npm run build
    "

    echo "==> Baue OxiCloud im Release-Modus (das kann einige Minuten dauern)..."
    if ! sudo -u "${OXICLOUD_USER}" bash -c "
      source '${RUSTUP_ENV}'
      cd '${OXICLOUD_HOME}'
      export DATABASE_URL='${DATABASE_URL}'
      cargo build --release --locked ${BUILD_FEATURES}
    "; then
      echo "    'cargo build --locked' ist fehlgeschlagen - vermutlich passt die"
      echo "    eingecheckte Cargo.lock nicht mehr zur Cargo.toml (Upstream hat sie"
      echo "    beim letzten Commit nicht mit aktualisiert). Erzeuge die Lockfile"
      echo "    neu und versuche den Build genau einmal erneut..."
      sudo -u "${OXICLOUD_USER}" bash -c "
        source '${RUSTUP_ENV}'
        cd '${OXICLOUD_HOME}'
        cargo generate-lockfile
      "
      echo "    Lockfile neu erzeugt, wiederhole den Release-Build mit --locked..."
      sudo -u "${OXICLOUD_USER}" bash -c "
        source '${RUSTUP_ENV}'
        cd '${OXICLOUD_HOME}'
        export DATABASE_URL='${DATABASE_URL}'
        cargo build --release --locked ${BUILD_FEATURES}
      "
    fi

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
      # Fix (1.18/6): current-good zusätzlich zu current bei der Bereinigung
      # ausnehmen, damit ein bekanntermaßen gesundes Release nicht gelöscht
      # wird, nur weil "current" inzwischen weitergezogen ist.
      ACTIVE_RELEASE="$(readlink -f "${CURRENT_LINK}" 2>/dev/null || echo "")"
      GOOD_RELEASE="$(readlink -f "${CURRENT_GOOD_LINK}" 2>/dev/null || echo "")"
      RELEASE_COUNT="$(find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' | wc -l)"
      if [[ "${RELEASE_COUNT}" -gt "${KEEP_RELEASES}" ]]; then
        echo "    Bereinige alte Releases (behalte die neuesten ${KEEP_RELEASES}; aktive und zuletzt gesunde Version bleiben immer erhalten)..."
        find "${RELEASES_DIR}" -maxdepth 1 -type f -name 'oxicloud-*' -printf '%T@ %p\n' \
          | sort -rn | tail -n +"$((KEEP_RELEASES + 1))" | cut -d' ' -f2- \
          | while IFS= read -r old_release; do
              [[ "${old_release}" == "${ACTIVE_RELEASE}" ]] && continue
              [[ "${old_release}" == "${GOOD_RELEASE}" ]] && continue
              rm -f "${old_release}"
            done
      fi
    fi
  fi
else
  echo "==> Überspringe Frontend- und Release-Build (keine Änderungen seit letztem Lauf)."
fi

BIN_PATH="${CURRENT_LINK}"
if [[ "${DRY_RUN}" != "true" && ! -e "${BIN_PATH}" ]]; then
  echo "Fehler: Binary wurde nicht unter ${BIN_PATH} gefunden. Build vermutlich fehlgeschlagen." >&2
  exit 1
fi

echo "==> Richte systemd-Service ein..."
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "    [DRY_RUN] würde /etc/systemd/system/oxicloud.service (neu) schreiben."
else
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
fi

run systemctl daemon-reload
if [[ "${NEED_BUILD}" -eq 1 ]]; then
  run systemctl enable oxicloud
  run systemctl restart oxicloud
  echo "    Dienst wurde neu gestartet (neues Binary)."
else
  run systemctl enable --now oxicloud
  echo "    Dienst läuft bereits / wurde gestartet, kein Neustart nötig."
fi

# ---- Health-Check + automatisches Rollback ---------------------------------
HEALTH_CHECK_HOST="127.0.0.1"
SKIP_HEALTH_CHECK=0
if [[ -n "${ENV_OVERRIDE_SERVER_HOST}" && "${ENV_OVERRIDE_SERVER_HOST}" != "0.0.0.0" && "${ENV_OVERRIDE_SERVER_HOST}" != "::" ]]; then
  SKIP_HEALTH_CHECK=1
fi

# Fix (1.18/7): Health-Check akzeptiert jetzt konfigurierbar mehrere HTTP-
# Statuscodes (HEALTH_CHECK_EXPECTED_CODES) statt nur pauschal 2xx via
# "curl -f". Manche Dienste antworten auf "/" z.B. mit einem Redirect
# (301/302) oder verlangen Auth (401) - das ist trotzdem ein Beweis, dass
# der Dienst lebt und antwortet, wurde vorher aber als "down" gewertet.
check_health() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://${HEALTH_CHECK_HOST}:${OXICLOUD_PORT}${HEALTH_CHECK_PATH}" 2>/dev/null)" || return 1
  for expected in ${HEALTH_CHECK_EXPECTED_CODES}; do
    [[ "${code}" == "${expected}" ]] && return 0
  done
  return 1
}

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "==> [DRY_RUN] Health-Check/Rollback-Logik übersprungen."
elif [[ "${NEED_BUILD}" -eq 1 && "${SKIP_HEALTH_CHECK}" -eq 1 ]]; then
  echo "==> Überspringe automatischen Health-Check: ENV_OVERRIDE_SERVER_HOST ist auf"
  echo "    '${ENV_OVERRIDE_SERVER_HOST}' gesetzt, der Dienst lauscht damit vermutlich nicht auf"
  echo "    ${HEALTH_CHECK_HOST}. Bitte manuell prüfen: systemctl status oxicloud / journalctl -u oxicloud -f"
elif [[ "${NEED_BUILD}" -eq 1 ]]; then
  echo "==> Prüfe, ob der Dienst nach dem Neustart tatsächlich läuft und antwortet..."
  HEALTH_OK=0
  for i in $(seq 1 "${HEALTH_RETRIES}"); do
    sleep 2
    if systemctl is-active --quiet oxicloud && check_health; then
      HEALTH_OK=1
      break
    fi
  done

  if [[ "${HEALTH_OK}" -eq 1 ]]; then
    echo "    Health-Check erfolgreich, Dienst antwortet auf Port ${OXICLOUD_PORT}${HEALTH_CHECK_PATH}."
    # Fix (1.18/6): current-good wird NUR nach erfolgreichem Health-Check
    # aktualisiert - dient als verlässliches Rollback-Ziel, das garantiert
    # schon einmal gesund lief (im Gegensatz zu "irgendein anderes Release").
    ln -sfn "$(readlink -f "${CURRENT_LINK}")" "${CURRENT_GOOD_LINK}"
    echo "    'current-good' aktualisiert -> $(readlink -f "${CURRENT_GOOD_LINK}")"
  else
    echo "FEHLER: Dienst antwortet nach ${HEALTH_RETRIES} Versuchen (je 2s) nicht auf Port ${OXICLOUD_PORT}${HEALTH_CHECK_PATH}." >&2
    echo "    Prüfe: journalctl -u oxicloud -n 50 --no-pager" >&2
    journalctl -u oxicloud -n 50 --no-pager >&2 || true

    if [[ ! -e "${CURRENT_GOOD_LINK}" ]]; then
      echo "    Kein 'current-good'-Release vorhanden (z.B. Erstinstallation): kein Rollback-Ziel." >&2
      ROLLBACK_STATUS="Health-Check fehlgeschlagen, kein 'current-good'-Rollback-Ziel vorhanden. Manueller Eingriff nötig!"
      exit 1
    fi

    PREV_BIN="$(readlink -f "${CURRENT_GOOD_LINK}")"
    if [[ -n "${PREV_BIN}" && "${PREV_BIN}" != "$(readlink -f "${CURRENT_LINK}")" ]]; then
      echo "    Rolle automatisch zurück auf zuletzt gesundes Release: ${PREV_BIN}" >&2
      ln -sfn "${PREV_BIN}" "${CURRENT_LINK}"
      systemctl restart oxicloud
      sleep 3
      if systemctl is-active --quiet oxicloud && check_health; then
        echo "    Rollback erfolgreich, Dienst läuft wieder mit ${PREV_BIN}." >&2
        ROLLBACK_STATUS="Automatisches Rollback auf ${PREV_BIN} (current-good) erfolgreich."
      else
        echo "    ACHTUNG: Auch das zuletzt gesunde Release startet jetzt nicht mehr sauber. Manueller Eingriff nötig!" >&2
        ROLLBACK_STATUS="Rollback auf ${PREV_BIN} (current-good) versucht, aber auch dieses Release startet/antwortet nicht mehr!"
      fi
    else
      echo "    'current-good' zeigt bereits auf das aktuelle (fehlgeschlagene) Release - kein sinnvolles Rollback-Ziel." >&2
      ROLLBACK_STATUS="Health-Check fehlgeschlagen, 'current-good' zeigt auf dasselbe Release wie 'current'. Manueller Eingriff nötig!"
    fi
    exit 1
  fi
fi

echo ""
echo "======================================================================"
echo " OxiCloud wurde installiert und gestartet."
echo " (Script-Version: ${SCRIPT_VERSION}$( [[ "${DRY_RUN}" == "true" ]] && echo " - DRY_RUN, keine echten Änderungen" ))"
echo ""
echo " URL:               http://$(hostname -I | awk '{print $1}'):${OXICLOUD_PORT}"
echo " Installationspfad: ${OXICLOUD_HOME}"
echo " Konfiguration:     /etc/oxicloud/.env"
echo " Aktives Release:   $(readlink -f "${CURRENT_LINK}" 2>/dev/null || echo "unbekannt")"
echo " Zuletzt gesundes Release (current-good): $(readlink -f "${CURRENT_GOOD_LINK}" 2>/dev/null || echo "noch keins")"
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

# Fix (1.19): Der Hinweis auf eine neuere Script-Version stand bisher nur
# mitten im scrollenden Lauf-Output (direkt nach dem Preflight-Check) - im
# Zusammenfassungsblock, den man beim normalen Durchlauf tatsächlich liest,
# tauchte er nicht mehr auf und wurde dadurch leicht übersehen, ohne dass
# ein Grund bestünde, extra ins Install-Log zu schauen. Erscheint hier
# erneut, falls beim Update-Check (oben, ggf. aus dem Cache übernommen)
# eine abweichende Version gefunden wurde.
if [[ -n "${UPDATE_AVAILABLE_VERSION}" ]]; then
  echo ""
  echo "Hinweis: Für install-oxicloud.sh liegt auf GitHub eine andere Version vor"
  echo "         (lokal: ${SCRIPT_VERSION}, dort auf '${UPDATE_CHECK_BRANCH}': ${UPDATE_AVAILABLE_VERSION})."
  echo "         https://github.com/${UPDATE_CHECK_REPO}"
fi

if [[ "${NEED_BUILD}" -eq 1 && "${DRY_RUN}" != "true" ]]; then
  echo ""
  echo "Hinweis: Der Build ist abgeschlossen. Falls du CPU/RAM für den Build"
  echo "hochgesetzt hattest, kannst du sie jetzt für den reinen Betrieb wieder"
  echo "zurückstellen (Empfehlung: 2 CPU-Kerne / 3 GB RAM genügen zum Laufenlassen)."
fi
