# configure-env.sh — Anleitung

Interaktives Script, das aus einer `example.env` (Vorlage) und optional
einer bestehenden `.env` eine neue `.env` erzeugt — Variable für Variable
zum Behalten, Aktivieren, Deaktivieren oder Ändern.

Version: 1.2
Lizenz: MIT

---

## Änderungen in 1.2

Optionale Selbstprüfung auf neuere Script-Version: vergleicht bei jedem
Lauf (sofern `curl` vorhanden und `CHECK_FOR_UPDATES=true`, Standard) die
`SCRIPT_VERSION` im `main`-Branch von
[roswitina/oxicloud-install](https://github.com/roswitina/oxicloud-install)
mit der lokal laufenden und gibt bei Abweichung einen Hinweis aus — rein
informativ, kein automatisches Update, fehlertolerant. Anders als bei
`install-oxicloud.sh`/`install.sh`/`update.sh` **ohne** Cache-Datei, da
dieses Script typischerweise selten und interaktiv von Hand aufgerufen
wird statt per Cron.

---

## Änderungen in 1.1

Drei Härtungen, angelehnt an das Robustheits-Niveau von `install-oxicloud.sh`:

1. **Atomares Schreiben behoben:** Die temporäre Datei landete vorher per
   `mktemp` (ohne Argument) im systemweiten `/tmp`, bevor sie per `mv` an
   den eigentlichen Zielort verschoben wurde. Liegen `/tmp` und das
   Zielverzeichnis (z. B. `/etc/oxicloud`) auf unterschiedlichen
   Dateisystemen — üblich, z. B. `/tmp` als `tmpfs` — macht `mv` daraus
   intern ein `cp` + `rm`, was **nicht atomar** ist: ein Absturz oder
   Stromausfall mittendrin hätte eine leere oder halb geschriebene `.env`
   hinterlassen können. Die Temp-Datei wird jetzt im selben Verzeichnis wie
   die Zieldatei angelegt, wodurch `mv` zu einem echten (atomaren)
   `rename()` wird.
2. **Aufbewahrungsgrenze für Zeitstempel-Backups:** `backup_file()`
   bereinigt jetzt wie in `install-oxicloud.sh` alte Backups automatisch
   auf die neuesten `GENERIC_BACKUP_KEEP` Stände (Standard 10) pro Datei,
   inklusive Kollisionsschutz bei zwei Backups derselben Datei in
   derselben Sekunde.
3. **Ownership beim Schreiben:** Die Ausgabedatei wird zusätzlich zu
   `chmod 640` auf `root:oxicloud` gesetzt (best-effort, schlägt still
   fehl, falls nicht als root ausgeführt oder die Gruppe nicht existiert —
   das Script bleibt damit auch außerhalb von OxiCloud-Systemen nutzbar).

---

## Grundidee

Bei jedem OxiCloud-Release kann sich `example.env` ändern: neue Variablen
kommen hinzu, alte fallen weg. Von Hand zwei Dateien zu diffen und die
eigene `.env` manuell nachzuziehen ist fehleranfällig — vor allem, weil
dabei leicht ein Passwort oder eine individuelle Einstellung verloren geht.

`configure-env.sh` löst das, indem es beide Dateien parst und dir pro
Variable eine bewusste Entscheidung abverlangt, statt stillschweigend etwas
zu überschreiben oder wegzulassen.

---

## Format-Konventionen, die das Script erkennt

| Zeile in `.env`/`example.env` | Bedeutung |
|---|---|
| `KEY=WERT` | Variable ist **aktiviert**, mit diesem Wert |
| `#KEY=WERT` | Variable ist **deaktiviert**, aber mit hinterlegtem Vorschlagswert — praktisch für optionale Features, die per Auskommentieren "aus" sind |
| `# Freier Text` (kein `KEY=WERT`-Muster) | Wird als **Beschreibung** der direkt danach folgenden Variable interpretiert |
| Leerzeile | Trennt Beschreibungsblöcke — eine Beschreibung "gehört" nur zur unmittelbar folgenden Variable |

Beispiel, wie es in `example.env` typischerweise aussieht:

```bash
# WASM-Plugin-Runtime (Extism) aktivieren.
# Standard: deaktiviert.
#OXICLOUD_ENABLE_PLUGINS=true
```

Das Script erkennt daraus: Variable `OXICLOUD_ENABLE_PLUGINS`, Status
*deaktiviert*, Vorschlagswert `true`, Beschreibung die beiden Kommentarzeilen
darüber.

---

## Aufruf

```bash
./configure-env.sh <example.env> [bestehende .env] [ausgabe-datei] [--defaults]
```

| Argument | Pflicht? | Standard |
|---|---|---|
| `example.env` | ja | — |
| bestehende `.env` | nein | keine (Erstkonfiguration) |
| Ausgabedatei | nein | die bestehende `.env`, falls angegeben, sonst `.env` im aktuellen Verzeichnis |
| `--defaults` | nein | aus (interaktiv) |

**`--defaults`** überspringt alle Rückfragen: jede Variable übernimmt
automatisch ihren Ausgangswert (bestehende `.env` falls vorhanden, sonst
`example.env`), und alle verwaisten Variablen werden automatisch behalten.
Gedacht zum Testen oder für unbeaufsichtigte Läufe — für den eigentlichen
Zweck (bewusste Entscheidung pro Variable) willst du normalerweise den
interaktiven Modus.

---

## Typische Anwendungsfälle

### 1. Erstkonfiguration (noch keine `.env` vorhanden)

```bash
./configure-env.sh example.env
```

Jede Variable wird einmal abgefragt, Ausgangsbasis ist jeweils der
Vorschlagswert aus `example.env`. Ergebnis landet in `./.env`.

### 2. Bestehende Installation auf neue `example.env` aktualisieren

```bash
./configure-env.sh example.env /etc/oxicloud/.env /etc/oxicloud/.env
```

- Variablen, die in beiden Dateien vorkommen: Ausgangsbasis ist der
  **bestehende** Wert/Status aus `/etc/oxicloud/.env`
- Variablen, die nur in der neuen `example.env` auftauchen: werden erkannt
  und mit `[neu aus example.env]` markiert abgefragt
- Variablen, die nur noch in der alten `.env` stehen (in der neuen
  `example.env` entfernt): werden am Ende gesondert gelistet — pro
  Variable fragst du "behalten? [J/n]"

Da Ausgabedatei = bestehende `.env`, wird vor dem Schreiben automatisch ein
Zeitstempel-Backup unter `/etc/oxicloud/backups/.env.<timestamp>.bak`
angelegt (gleicher Mechanismus wie in `install.sh`).

### 3. Testen/Vorschau ohne Rückfragen

```bash
./configure-env.sh example.env /etc/oxicloud/.env /tmp/preview.env --defaults
diff /etc/oxicloud/.env /tmp/preview.env
```

Zeigt dir, was sich rein durch neue/entfernte Variablen ändern würde, ohne
etwas Produktives anzufassen.

---

## Ablauf einer einzelnen Abfrage

```
──────────────────────────────────────────────────────
OXICLOUD_ENABLE_PLUGINS  [bestehende .env]
  WASM-Plugin-Runtime (Extism) aktivieren.
  Standard: deaktiviert.
  Status: aktiviert   Wert = true
  [Enter]=behalten  a=aktivieren  d=deaktivieren  w=Wert ändern  >
```

| Eingabe | Wirkung |
|---|---|
| `Enter` | Wert und Status unverändert übernehmen |
| `a` | Variable aktivieren (Wert bleibt wie angezeigt) |
| `d` | Variable deaktivieren, Wert bleibt als Vorschlag erhalten (`#KEY=WERT`) |
| `w` | Nach neuem Wert fragen; Enter bei der Nachfrage behält den alten Wert |

---

## Was garantiert erhalten bleibt

- **Passwörter/Connection-Strings**: Solange du bei einer Variable nicht
  aktiv `w` wählst, bleibt ihr Wert exakt wie in der Ausgangsdatei — auch
  beim Deaktivieren/Aktivieren.
- **Vorschlagswerte deaktivierter Variablen**: Werden nicht gelöscht,
  sondern als `#KEY=WERT` mitgeschrieben, damit du sie später ohne erneute
  Eingabe wieder aktivieren kannst.
- **Bestehende Zieldatei**: Wird vor dem Überschreiben per Zeitstempel
  gesichert, nicht einfach ersetzt — seit 1.1 begrenzt auf die neuesten
  `GENERIC_BACKUP_KEEP` Stände (Standard 10), damit `backups/` nicht
  unbegrenzt wächst.

---

## Bekannte Grenzen

- Werte mit einem `=`-Zeichen (z. B. Connection-Strings mit Query-Parametern)
  werden korrekt erkannt, da nur bis zum *ersten* `=` als Schlüsselgrenze
  geparst wird.
- Mehrzeilige Werte (z. B. PEM-Zertifikate direkt in der `.env`) werden
  **nicht** unterstützt — jede Variable muss in einer Zeile stehen.
- Die Beschreibung wird anhand direkt vorangehender Kommentarzeilen
  erkannt; Abschnitts-Trennkommentare (z. B. `### ---- Config ----`)
  landen technisch mit in der Beschreibung, falls keine Leerzeile dazwischen
  liegt — kosmetisch, aber nicht falsch.

---

## Getestet mit

Ein Simulationslauf mit drei Szenarien hat die Kernlogik verifiziert:
1. `--defaults` mit bestehender `.env`: bestehende Werte (inkl. Passwort in
   der DB-Connection-String) bleiben erhalten, neue Variable wird erkannt
   und mit Vorschlagswert deaktiviert übernommen, verwaiste Variable bleibt
   erhalten.
2. Interaktiv mit simulierten Eingaben: Wert ändern, behalten, deaktivieren,
   aktivieren und verwaiste Variable verwerfen funktionieren wie erwartet.
3. Erstkonfiguration ganz ohne bestehende `.env`: alle Variablen werden mit
   den Vorschlagswerten aus `example.env` übernommen.

---

## Integration in install.sh (optional, noch nicht umgesetzt)

Aktuell kopiert `install.sh` `example.env` bei einer Erstinstallation nur
stumpf nach `/etc/oxicloud/.env`. Falls gewünscht, kann `install.sh` so
angepasst werden, dass es stattdessen `configure-env.sh` aufruft (sofern
vorhanden) und dir damit die interaktive Abfrage direkt während der
Installation anbietet, statt danach manuell in der `.env` herumzueditieren.
