#!/usr/bin/env bash
#
# configure-env.sh
#
# Version: 1.2
# Lizenz:  MIT
#
# Changelog:
#   1.2 - Optionale Selbstprüfung auf neuere Script-Version (CHECK_FOR_UPDATES,
#         analog install-oxicloud.sh 1.16), rein informativ und fehlertolerant.
#         Ohne Cache-Datei (anders als bei den Server-Scripts), da dieses
#         Script typischerweise selten und interaktiv von Hand aufgerufen
#         wird, nicht per Cron/automatisiert.
#   1.1 - Drei Härtungen, angelehnt an install-oxicloud.sh:
#         1) Nicht-atomares Schreiben behoben: Die temporäre Datei landete
#            bisher per "mktemp" (ohne Argument) in /tmp, danach "mv" nach
#            z.B. /etc/oxicloud/.env. Liegen /tmp und das Zielverzeichnis auf
#            unterschiedlichen Dateisystemen (sehr üblich, z.B. tmpfs vs.
#            root-fs), macht "mv" daraus intern ein cp+rm - NICHT atomar. Ein
#            Absturz/Stromausfall mittendrin hätte eine leere oder halb
#            geschriebene .env hinterlassen können. Jetzt wird die Temp-Datei
#            im selben Verzeichnis wie die Zieldatei angelegt, wodurch "mv"
#            ein reines (atomares) rename() ist.
#         2) backup_file() bereinigt jetzt alte Zeitstempel-Backups analog zu
#            GENERIC_BACKUP_KEEP in install-oxicloud.sh (Standard 10) - vorher
#            wuchs backups/ bei wiederholten Läufen unbegrenzt.
#         3) Ausgabedatei wird, sofern schreibbar, zusätzlich auf
#            root:<gruppe der Zieldatei bzw. "oxicloud"> gesetzt, nicht nur
#            chmod 640 - vorher blieb z.B. nach einer Neuanlage die Gruppe
#            ggf. auf der ausführenden Shell stehen statt auf "oxicloud".
#
# Liest eine example.env (Vorlage) und optional eine bereits bestehende
# .env, geht interaktiv jede Variable durch (behalten / aktivieren /
# deaktivieren / Wert ändern) und schreibt daraus eine neue .env.
#
# - Variablen, die NUR in der neuen example.env auftauchen (z.B. nach
#   einem Update auf eine neuere OxiCloud-Version), werden automatisch
#   erkannt und mit abgefragt.
# - Variablen, die NUR in der bestehenden .env auftauchen (in der neuen
#   example.env nicht mehr vorhanden), werden gesondert aufgelistet -
#   behalten oder entfernen liegt bei dir.
# - Eine auskommentierte "#KEY=WERT"-Zeile gilt als *deaktivierte*
#   Variable mit hinterlegtem Vorschlagswert; eine aktive "KEY=WERT"-
#   Zeile als aktiviert. So können beide Zustände hin- und hergeschaltet
#   werden, ohne den Vorschlagswert zu verlieren.
# - Kommentarzeilen direkt oberhalb einer Variable werden als Beschreibung
#   angezeigt und in der Ausgabe wieder mit ausgegeben.
#
# Aufruf:
#   ./configure-env.sh <example.env> [bestehende .env] [ausgabe-datei] [--defaults]
#
# Beispiele:
#   ./configure-env.sh example.env
#   ./configure-env.sh example.env /etc/oxicloud/.env
#   ./configure-env.sh example.env /etc/oxicloud/.env /etc/oxicloud/.env
#   ./configure-env.sh example.env /etc/oxicloud/.env /etc/oxicloud/.env --defaults
#
# --defaults: keine Rückfragen, übernimmt für jede Variable automatisch
#             den Ausgangswert (bestehende .env falls vorhanden, sonst
#             example.env) und behält alle "verwaisten" Variablen bei.
#             Nützlich zum Testen oder für unbeaufsichtigte Läufe.

set -euo pipefail

# Eigene Versionsnummer dieses Scripts.
SCRIPT_VERSION="1.2"

# Selbstprüfung auf neuere Script-Version (rein informativ, kein Cache -
# dieses Script läuft typischerweise selten/interaktiv, nicht per Cron).
CHECK_FOR_UPDATES=true
UPDATE_CHECK_REPO="roswitina/oxicloud-install"
UPDATE_CHECK_BRANCH="main"
if [ "${CHECK_FOR_UPDATES}" = "true" ] && command -v curl >/dev/null 2>&1; then
  REMOTE_RAW_SCRIPT="$(curl -fsS -m 5 \
    "https://raw.githubusercontent.com/${UPDATE_CHECK_REPO}/${UPDATE_CHECK_BRANCH}/configure-env.sh" 2>/dev/null || true)"
  if [ -n "${REMOTE_RAW_SCRIPT}" ]; then
    REMOTE_SCRIPT_VERSION="$(printf '%s\n' "${REMOTE_RAW_SCRIPT}" | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"
    if [ -n "${REMOTE_SCRIPT_VERSION}" ] && [ "${REMOTE_SCRIPT_VERSION}" != "${SCRIPT_VERSION}" ]; then
      echo "Hinweis: Auf GitHub liegt eine andere Version von configure-env.sh (lokal: ${SCRIPT_VERSION}, dort: ${REMOTE_SCRIPT_VERSION}). https://github.com/${UPDATE_CHECK_REPO}" >&2
    fi
  fi
fi

# ─── Argumente ─────────────────────────────────────────────────────────────
NONINTERACTIVE=0
ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --defaults) NONINTERACTIVE=1 ;;
    *) ARGS+=("${arg}") ;;
  esac
done

if [ "${#ARGS[@]}" -lt 1 ]; then
  echo "Aufruf: $0 <example.env> [bestehende .env] [ausgabe-datei] [--defaults]" >&2
  exit 1
fi

EXAMPLE_FILE="${ARGS[0]}"
EXISTING_FILE="${ARGS[1]:-}"
OUTPUT_FILE="${ARGS[2]:-${EXISTING_FILE:-.env}}"

if [ ! -f "${EXAMPLE_FILE}" ]; then
  echo "Fehler: ${EXAMPLE_FILE} nicht gefunden." >&2
  exit 1
fi
if [ -n "${EXISTING_FILE}" ] && [ ! -f "${EXISTING_FILE}" ]; then
  echo "Hinweis: ${EXISTING_FILE} existiert nicht - wird als 'keine bestehende .env' behandelt." >&2
  EXISTING_FILE=""
fi

# Wie viele Zeitstempel-Backups PRO DATEI in backups/ behalten werden.
# 0 = keine Bereinigung, alle Backups werden dauerhaft behalten.
GENERIC_BACKUP_KEEP=10

# ─── Backup-Helfer (wie in install-oxicloud.sh) ────────────────────────────
backup_file() {
  local file="$1"
  if [ -f "${file}" ]; then
    local backup_dir
    backup_dir="$(dirname "${file}")/backups"
    mkdir -p "${backup_dir}" 2>/dev/null || backup_dir="."
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    local base
    base="$(basename "${file}")"
    local backup_path="${backup_dir}/${base}.${ts}.bak"
    # Kollisionsschutz analog install-oxicloud.sh: Sekundenauflösung des
    # Zeitstempels reicht bei zwei schnell aufeinanderfolgenden Läufen nicht.
    if [ -e "${backup_path}" ]; then
      backup_path="${backup_dir}/${base}.${ts}-$$.bak"
    fi
    cp -p "${file}" "${backup_path}"
    echo "Backup angelegt: ${backup_path}"

    if [ "${GENERIC_BACKUP_KEEP}" -gt 0 ]; then
      local backup_count
      backup_count="$(find "${backup_dir}" -maxdepth 1 -type f -name "${base}.*.bak" 2>/dev/null | wc -l)"
      if [ "${backup_count}" -gt "${GENERIC_BACKUP_KEEP}" ]; then
        find "${backup_dir}" -maxdepth 1 -type f -name "${base}.*.bak" -printf '%T@ %p\n' 2>/dev/null \
          | sort -rn | tail -n +"$((GENERIC_BACKUP_KEEP + 1))" | cut -d' ' -f2- \
          | while IFS= read -r old_backup; do rm -f "${old_backup}"; done
      fi
    fi
  fi
}

# ─── Parser: liest eine .env/example.env in vorgegebene Array-Namen ───────
# Nutzt Namerefs (bash 4.3+), damit dieselbe Funktion für example.env UND
# eine bestehende .env verwendet werden kann.
parse_env_file() {
  local file="$1"
  local -n order_ref="$2"
  local -n desc_ref="$3"
  local -n value_ref="$4"
  local -n enabled_ref="$5"

  local pending_desc=""
  local line key value text

  while IFS= read -r line || [ -n "${line}" ]; do
    # Leerzeile: Beschreibung "endet" hier, nächster Block startet neu
    if [[ -z "${line//[[:space:]]/}" ]]; then
      pending_desc=""
      continue
    fi

    # Aktive KEY=WERT-Zeile
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ -z "${enabled_ref[${key}]+set}" ]]; then
        order_ref+=("${key}")
      fi
      desc_ref["${key}"]="${pending_desc}"
      value_ref["${key}"]="${value}"
      enabled_ref["${key}"]=1
      pending_desc=""
      continue
    fi

    # Auskommentierte KEY=WERT-Zeile -> deaktivierte Variable mit Vorschlagswert
    if [[ "${line}" =~ ^#[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ -z "${enabled_ref[${key}]+set}" ]]; then
        order_ref+=("${key}")
      fi
      desc_ref["${key}"]="${pending_desc}"
      value_ref["${key}"]="${value}"
      enabled_ref["${key}"]=0
      pending_desc=""
      continue
    fi

    # Normale Kommentarzeile -> als Beschreibung sammeln
    if [[ "${line}" =~ ^#(.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      text="${text# }"
      if [ -z "${pending_desc}" ]; then
        pending_desc="${text}"
      else
        pending_desc="${pending_desc}"$'\n'"${text}"
      fi
      continue
    fi

    # Alles andere (sollte selten vorkommen): Beschreibung zurücksetzen
    pending_desc=""
  done < "${file}"
}

# ─── example.env parsen ─────────────────────────────────────────────────────
declare -a NEW_ORDER=()
declare -A NEW_DESC=()
declare -A NEW_VALUE=()
declare -A NEW_ENABLED=()
parse_env_file "${EXAMPLE_FILE}" NEW_ORDER NEW_DESC NEW_VALUE NEW_ENABLED

# ─── bestehende .env parsen (falls vorhanden) ──────────────────────────────
declare -a CUR_ORDER=()
declare -A CUR_DESC=()
declare -A CUR_VALUE=()
declare -A CUR_ENABLED=()
if [ -n "${EXISTING_FILE}" ]; then
  parse_env_file "${EXISTING_FILE}" CUR_ORDER CUR_DESC CUR_VALUE CUR_ENABLED
fi

echo "example.env:      ${EXAMPLE_FILE}  (${#NEW_ORDER[@]} Variablen)"
if [ -n "${EXISTING_FILE}" ]; then
  echo "bestehende .env:   ${EXISTING_FILE}  (${#CUR_ORDER[@]} Variablen)"
else
  echo "bestehende .env:   keine (Erstkonfiguration)"
fi
echo "Ausgabe:           ${OUTPUT_FILE}"
echo ""

# ─── Hauptdurchlauf: jede Variable aus example.env abfragen ───────────────
declare -A FINAL_VALUE=()
declare -A FINAL_ENABLED=()

for key in "${NEW_ORDER[@]}"; do
  desc="${NEW_DESC[${key}]}"
  default_value="${NEW_VALUE[${key}]}"
  default_enabled="${NEW_ENABLED[${key}]}"

  if [[ -n "${CUR_ENABLED[${key}]+set}" ]]; then
    base_value="${CUR_VALUE[${key}]}"
    base_enabled="${CUR_ENABLED[${key}]}"
    source_label="bestehende .env"
  else
    base_value="${default_value}"
    base_enabled="${default_enabled}"
    source_label="neu aus example.env"
  fi

  if [ "${NONINTERACTIVE}" -eq 1 ]; then
    FINAL_VALUE["${key}"]="${base_value}"
    FINAL_ENABLED["${key}"]="${base_enabled}"
    continue
  fi

  echo "──────────────────────────────────────────────────────"
  echo "${key}  [${source_label}]"
  if [ -n "${desc}" ]; then
    while IFS= read -r dline; do echo "  ${dline}"; done <<< "${desc}"
  fi
  if [ "${base_enabled}" -eq 1 ]; then
    echo "  Status: aktiviert   Wert = ${base_value}"
  else
    echo "  Status: deaktiviert Vorschlagswert = ${base_value}"
  fi

  while true; do
    read -r -p "  [Enter]=behalten  a=aktivieren  d=deaktivieren  w=Wert ändern  > " choice
    case "${choice}" in
      "")
        FINAL_VALUE["${key}"]="${base_value}"
        FINAL_ENABLED["${key}"]="${base_enabled}"
        break
        ;;
      a|A)
        FINAL_VALUE["${key}"]="${base_value}"
        FINAL_ENABLED["${key}"]=1
        break
        ;;
      d|D)
        FINAL_VALUE["${key}"]="${base_value}"
        FINAL_ENABLED["${key}"]=0
        break
        ;;
      w|W)
        read -r -p "  Neuer Wert (aktuell: ${base_value}): " new_value
        FINAL_VALUE["${key}"]="${new_value:-${base_value}}"
        FINAL_ENABLED["${key}"]="${base_enabled}"
        break
        ;;
      *)
        echo "  Ungültige Eingabe, bitte Enter/a/d/w verwenden."
        ;;
    esac
  done
  echo ""
done

# ─── Verwaiste Variablen: in bestehender .env, aber nicht mehr in example.env ─
EXTRA_ORDER=()
for key in "${CUR_ORDER[@]}"; do
  if [[ -z "${NEW_ENABLED[${key}]+set}" ]]; then
    EXTRA_ORDER+=("${key}")
  fi
done

declare -A EXTRA_KEEP=()
if [ "${#EXTRA_ORDER[@]}" -gt 0 ]; then
  echo "════════════════════════════════════════════════════"
  echo "Variablen in der bestehenden .env, die in der neuen"
  echo "example.env nicht mehr vorkommen:"
  echo ""
  for key in "${EXTRA_ORDER[@]}"; do
    value="${CUR_VALUE[${key}]}"
    enabled="${CUR_ENABLED[${key}]}"
    status_txt="deaktiviert"
    [ "${enabled}" -eq 1 ] && status_txt="aktiviert"
    echo "${key} = ${value}  (${status_txt})"

    if [ "${NONINTERACTIVE}" -eq 1 ]; then
      EXTRA_KEEP["${key}"]=1
      continue
    fi

    read -r -p "  behalten? [J/n] " keep
    case "${keep}" in
      n|N) EXTRA_KEEP["${key}"]=0 ;;
      *)   EXTRA_KEEP["${key}"]=1 ;;
    esac
  done
  echo ""
fi

# ─── Ausgabe schreiben ──────────────────────────────────────────────────────
if [ -f "${OUTPUT_FILE}" ]; then
  backup_file "${OUTPUT_FILE}"
fi

# Fix (1.1): TMP_FILE MUSS im selben Verzeichnis wie OUTPUT_FILE liegen,
# nicht im systemweiten /tmp (Standard-Verhalten von "mktemp" ohne Argument).
# Liegen Temp- und Zielverzeichnis auf unterschiedlichen Dateisystemen, macht
# "mv" daraus intern ein cp+rm statt eines echten (atomaren) rename() - ein
# Absturz mittendrin könnte dann eine leere/kaputte .env hinterlassen.
OUTPUT_DIR_FOR_TMP="$(dirname "${OUTPUT_FILE}")"
mkdir -p "${OUTPUT_DIR_FOR_TMP}" 2>/dev/null || true
TMP_FILE="$(mktemp "${OUTPUT_DIR_FOR_TMP}/.configure-env.XXXXXX" 2>/dev/null || mktemp)"
{
  echo "# Erzeugt von configure-env.sh am $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Basis: ${EXAMPLE_FILE}$( [ -n "${EXISTING_FILE}" ] && echo " + ${EXISTING_FILE}" )"
  echo ""

  for key in "${NEW_ORDER[@]}"; do
    desc="${NEW_DESC[${key}]}"
    if [ -n "${desc}" ]; then
      while IFS= read -r dline; do echo "# ${dline}"; done <<< "${desc}"
    fi
    value="${FINAL_VALUE[${key}]}"
    if [ "${FINAL_ENABLED[${key}]}" -eq 1 ]; then
      echo "${key}=${value}"
    else
      echo "#${key}=${value}"
    fi
    echo ""
  done

  if [ "${#EXTRA_ORDER[@]}" -gt 0 ]; then
    any_kept=0
    for key in "${EXTRA_ORDER[@]}"; do
      [ "${EXTRA_KEEP[${key}]}" -eq 1 ] && any_kept=1
    done
    if [ "${any_kept}" -eq 1 ]; then
      echo "# --- Übernommen aus vorheriger .env, nicht mehr in example.env ---"
      for key in "${EXTRA_ORDER[@]}"; do
        if [ "${EXTRA_KEEP[${key}]}" -eq 1 ]; then
          value="${CUR_VALUE[${key}]}"
          if [ "${CUR_ENABLED[${key}]}" -eq 1 ]; then
            echo "${key}=${value}"
          else
            echo "#${key}=${value}"
          fi
        fi
      done
    fi
  fi
} > "${TMP_FILE}"

mv "${TMP_FILE}" "${OUTPUT_FILE}"
chmod 640 "${OUTPUT_FILE}" 2>/dev/null || true
# Fix (1.1): Ownership explizit setzen, nicht nur Rechte - sonst kann die
# Gruppe nach einer Neuanlage z.B. auf der ausführenden Shell/dem User
# stehen bleiben statt auf "oxicloud" (relevant, falls z.B. root diese
# Datei für den Dienst-User anlegt). Best-effort: schlägt still fehl, falls
# nicht als root ausgeführt oder die Gruppe "oxicloud" nicht existiert -
# das Script bleibt damit auch außerhalb von OxiCloud-Systemen nutzbar.
chown root:oxicloud "${OUTPUT_FILE}" 2>/dev/null || true

echo "Fertig geschrieben: ${OUTPUT_FILE}"
