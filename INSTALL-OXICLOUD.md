# install-oxicloud.sh — Anleitung

Native (Nicht-Container-)Installation von OxiCloud, die den Quellcode
**direkt auf dem Zielserver** klont, kompiliert und als systemd-Dienst
betreibt — im Gegensatz zum separaten Prebuilt-Tooling
(`build-package.sh`/`install.sh`/`update.sh`), das auf einer separaten
Build-Maschine kompiliert und ein fertiges `.tar.gz` verteilt.

Version: 1.23
Lizenz: MIT

---

## Versionshistorie

| Version | Änderung |
|---|---|
| 1.9 | Ursprüngliche Fassung |
| 1.10 | `REPO_URL` konsistent auf `AtalayaLabs/OxiCloud`; systemd-Hardening ergänzt |
| 1.11 | `set -e`-Fallstrick bei Node.js-LTS-Ermittlung behoben; DB-Passwort wird bei jedem Lauf durchgesetzt; DB-Passwort nicht mehr im world-readable systemd-Unit-File |
| 1.12 | `sudo` fehlte in der Preflight-Paketliste (LXC-Minimal-Templates) |
| 1.13 | Automatisches Health-Check-Rollback, DB-Backup vor jeder Migration, Log-Rotation, `git fetch`+`reset --hard` statt `pull`, harter Diskspace-Abbruch, Firewall-Hinweis, Webhook-Benachrichtigung |
| 1.14 | Aufbewahrungsgrenze für generische Zeitstempel-Backups (`GENERIC_BACKUP_KEEP`) |
| 1.15 | Health-Check-Skip bei fester `ENV_OVERRIDE_SERVER_HOST`; Health-Check auch bei Erstinstallation; Rollback-Status in Webhook-Meldung; `chown -R` nur bei Bedarf |
| 1.16 | Optionale Selbstprüfung auf neuere Script-Version gegen GitHub (`CHECK_FOR_UPDATES`) |
| 1.17 | Selbstheilung bei fehlschlagendem `cargo build --release --locked` (Cargo.lock-Konflikt) |
| 1.18 | Review-Runde mit 13 Fixes/Verbesserungen, siehe Abschnitt „Neuerungen in 1.18" unten: u. a. abgesicherte `latest`-Release-Ermittlung, vorgezogene Dependency-Verifizierung, optionales `GITHUB_TOKEN`, bedarfsgesteuerter + garantiert aufgeräumter Swapfile, neuer `current-good`-Rollback-Anker, tolerantere Health-Check-Codes, korrigierte ufw-Prüfung, Backup vor destruktivem Directory-Cleanup, sed-Escaping in `set_env_var()`, restriktivere Rechte auf `/etc/oxicloud`, robuste Diskspace-Ermittlung und neuer `DRY_RUN`-Modus |
| 1.19 | Der Hinweis auf eine neuere Script-Version erscheint zusätzlich im finalen Zusammenfassungsblock statt nur mitten im scrollenden Lauf-Output, siehe Abschnitt „Neuerung in 1.19" unten — bleibt dafür seit dieser Version auch über den Update-Check-Cache hinweg sichtbar |
| 1.20 | Neuer, standardmäßig deaktivierter Schalter `AUTO_REPAIR_MODIFIED_MIGRATIONS` für den Fall „migration X was previously applied but has been modified" (sqlx-Checksummen-Mismatch bei ungepinntem main-Branch), siehe Abschnitt „Neuerung in 1.20" unten |
| 1.21 | Bugfix `.env`-Abgleich: Auch auskommentierte, optionale Variablen der Vorlage werden jetzt samt Erklärungstext in eine bestehende `.env` übernommen; Vorlage wird unter `example.env`, `.env.example` und `env.example` gesucht, siehe Abschnitt „Neuerung in 1.21" unten |
| 1.22 | Neue Einstellung `ENV_LANGUAGE`: `.env` auf Deutsch (oder Englisch) anlegen bzw. einmalig umbauen – mit Prüfung, dass alle eigenen Werte erhalten bleiben; danach werden neue Variablen in der gewählten Sprache ergänzt, siehe Abschnitt „Neuerung in 1.22" unten |
| **1.23** | **Bugfix Update-Hinweis:** erscheint nur noch, wenn auf GitHub eine **neuere** Version liegt; nach einem lokalen Script-Update wird sofort neu geprüft statt einen veralteten Stand aus dem Cache zu zeigen, siehe Abschnitt „Fix in 1.23" unten |

---

## Grundidee

Ein einziges Script übernimmt Erstinstallation **und** spätere Updates:
einfach erneut ausführen. Es ist vollständig idempotent — ein zweiter Lauf
erkennt selbst, ob sich seit dem letzten Mal etwas geändert hat (neuer
Commit, neue Rust-Toolchain, geänderte Build-Features), und baut nur dann
neu.

**Wichtig:** Dieses Script und das separate Prebuilt-Tooling
(`build-package.sh`/`install.sh`/`update.sh`) schließen sich gegenseitig
aus. Nicht beide gegen dasselbe `/opt/oxicloud` laufen lassen — entweder
der Server baut sich selbst (dieses Script), oder er bekommt ein fertiges
Paket von außen (Prebuilt-Tooling), nicht beides gemischt.

---

## Fix in 1.23

### Update-Hinweis nur noch bei einer neueren Version auf GitHub

**Das Problem:** Nach dem Hochladen einer neuen Script-Version auf GitHub
meldete das Script trotzdem z. B.

```
Hinweis: Für install-oxicloud.sh liegt auf GitHub eine andere Version vor
         (lokal: 1.22, dort auf 'main': 1.20).
```

Zwei Ursachen: Der Vergleich prüfte nur auf *ungleich*, meldete also auch
eine **ältere** Version auf GitHub. Und das Ergebnis des letzten echten
Checks lag bis zu `UPDATE_CHECK_INTERVAL_HOURS` (Standard 24 Stunden) im
Cache `/etc/oxicloud/.update-check-install-oxicloud` – nach einem lokalen
Update wurde also noch ein Tag lang der alte GitHub-Stand angezeigt.

**Jetzt:**

- Versionen werden der Größe nach verglichen (`sort -V`, also auch
  `1.9` < `1.10`). Der Hinweis erscheint nur, wenn die Version auf GitHub
  **neuer** ist.
- Ist die lokale Version neuer (noch nicht hochgeladen, oder GitHub liefert
  die neue Datei erst nach einigen Minuten aus), gibt es nur eine kurze
  Info-Zeile im Lauf, keinen Hinweis in der Zusammenfassung.
- Der Cache merkt sich zusätzlich die lokale Version des letzten Checks.
  Wurde das Script seitdem aktualisiert, wird sofort neu geprüft. Ältere
  Cache-Dateien werden dabei automatisch erneuert.

---

## Neuerung in 1.22

### Sprache der `.env` wählen: `ENV_LANGUAGE`

Die Erklärungstexte in `/etc/oxicloud/.env` stammen aus der Vorlage
`example.env` des Repositorys und sind englisch. Mit der neuen Einstellung
`ENV_LANGUAGE` im Konfigurationsblock lässt sich die Sprache wählen:

| Wert | Wirkung |
|---|---|
| `""` (Standard) | wie in 1.21: `.env` wird nicht umgebaut, fehlende Variablen kommen mit englischem Text dazu |
| `"de"` | deutsche `.env` – Vorlage ist `ENV_TEMPLATE_DIR/example.env.de` |
| `"en"` | englische `.env` im Aufbau der `example.env` des Repositorys |

**Einrichten (Deutsch):**

1. Die deutsche Vorlage `example.env.de` nach `/etc/oxicloud/example.env.de`
   kopieren (Standard für `ENV_TEMPLATE_DIR` ist `/etc/oxicloud`). Dort
   überschreibt sie kein Update – anders als die `example.env` im
   Programmordner `/opt/oxicloud`, die bei jedem `git reset` erneuert wird.
2. Im Konfigurationsblock `ENV_LANGUAGE="de"` setzen.
3. Script wie gewohnt ausführen (vorher Snapshot).

**Was beim ersten Lauf passiert – einmaliger Umbau:**

- Die bestehende `.env` wird im Aufbau der deutschen Vorlage neu
  geschrieben: deutsche Abschnitte, deutsche Erklärungen, dieselbe
  Reihenfolge wie die Vorlage.
- **Eigene Werte bleiben erhalten:** Für jede Variable wird die eigene
  Zeile aus der bisherigen `.env` an ihre Stelle in der Vorlage gesetzt –
  aktiv, wenn sie aktiv war, auskommentiert, wenn sie auskommentiert war.
  Kommt eine Variable in der Vorlage mehrfach vor (Beispielzeilen), wird
  nur die erste ersetzt; weitere werden nie zusätzlich aktiv.
- Variablen der bisherigen `.env`, die die Vorlage nicht kennt (eigene
  Variablen, ältere Namen), kommen gesammelt ans Ende unter
  „Weitere Einstellungen aus der bisherigen .env".
- Blöcke der Vorlage, deren Variable es im Repository nicht mehr gibt und
  die in der `.env` nicht vorkommt, entfallen.
- **Prüfung:** Vor dem Schreiben vergleicht das Script die wirksamen
  Einstellungen (so, wie systemd die `.env` liest: letzte aktive Zeile je
  Variable gewinnt) vorher und nachher. Würde sich auch nur ein bisher
  wirksamer Wert ändern, bricht der Umbau ab, nennt die betroffene
  Variable (ohne Wert) und die `.env` bleibt unverändert. Neu wirksam
  werden dürfen nur Standardwerte der Vorlage für Variablen, die vorher gar
  nicht gesetzt waren – genau wie bei einer Neuinstallation; das Script
  nennt sie.
- Vorher wird wie immer eine Zeitstempel-Kopie unter
  `/etc/oxicloud/backups/` angelegt.
- Eine Markierungszeile ganz oben merkt sich die Sprache:
  `# install-oxicloud.sh: env-language=de`

**Bei jedem weiteren Lauf** wird nicht mehr umgebaut, sondern nur ergänzt:
Bringt eine neue OxiCloud-Version neue Variablen mit, kommen sie mit dem
deutschen Text aus `example.env.de` dazu. Gibt es für eine Variable noch
keine Übersetzung, kommt sie mit dem englischen Text aus dem Repository
dazu, markiert mit
`# [noch nicht übersetzt - Text aus der englischen Vorlage des Repositorys]`.
Maßgeblich dafür, welche Variablen es gibt, ist immer die `example.env` des
Repositorys.

**Sprache wechseln:** `ENV_LANGUAGE` ändern und das Script ausführen. Weil
die Markierung nicht mehr passt, wird die `.env` erneut umgebaut – mit
derselben Prüfung. `ENV_LANGUAGE=""` lässt eine bereits umgebaute `.env`
einfach so, wie sie ist.

**Neuinstallation:** Mit `ENV_LANGUAGE="de"` wird die `.env` direkt aus der
deutschen Vorlage angelegt (plus noch nicht übersetzte Variablen).

**Zu beachten:** Eigene Kommentarzeilen, die man selbst in die `.env`
geschrieben hat, übernimmt der Umbau nicht – nur die Variablenzeilen. Die
alte Fassung liegt im Backup-Ordner.

Nebenbei behoben: Bei einer **leeren** `.env` hat der Abgleich aus 1.21 die
Vorlage nicht richtig erkannt (awk-Eigenheit bei leeren Dateien). Das ist
jetzt korrigiert.

---

## Neuerung in 1.21

### `.env` wird vollständig mit der Vorlage abgeglichen – auch optionale Variablen

**Das Problem:** Bei einer bereits bestehenden `.env` hat das Script bisher
nur **aktive** Zeilen der Vorlage (`VARIABLE=wert`) übernommen. In der
aktuellen `example.env` von OxiCloud sind aber nur rund 10 Variablen aktiv;
die übrigen rund 170 Einstellungen stehen dort **auskommentiert**
(`#VARIABLE=wert`), jeweils mit einem Erklärungstext darüber. Kommentarzeilen
hat der Abgleich komplett übersprungen. Dadurch kamen diese optionalen
Einstellungen nie in die `.env` – man sah dort also gar nicht, welche
Möglichkeiten es gibt, und neue Optionen späterer OxiCloud-Versionen
tauchten nie auf. Außerdem kannte das Script nur den Dateinamen
`example.env` und brach ab, wenn die Vorlage fehlte.

**Jetzt:**

- Die Vorlage wird unter `example.env`, `.env.example` und `env.example`
  gesucht (in dieser Reihenfolge). Fehlt sie ganz, gibt es nur einen
  Hinweis; bei einer Erstinstallation wird dann eine leere `.env` angelegt,
  in die das Script die nötigen Werte (`DATABASE_URL` usw.) wie bisher
  selbst einträgt.
- Jede Variable der Vorlage, die in der `.env` **weder aktiv noch
  auskommentiert** vorkommt, wird **zusammen mit ihrem Erklärungstext**
  angehängt – und zwar genau in der Form wie in der Vorlage:
  - aktive Variablen bleiben aktiv, **auch wenn der Wert leer ist**,
  - auskommentierte bleiben auskommentiert und haben damit keine Wirkung.

  Das Ergebnis entspricht damit dem, was eine Neuinstallation (Kopie der
  Vorlage) ergeben würde.
- **Bestehende Werte werden nie verändert.** Eine Variable gilt als
  vorhanden, wenn sie aktiv (`VARIABLE=…`, auch `export VARIABLE=…`) oder
  auskommentiert (`#VARIABLE=…`, `# VARIABLE=…`) in der `.env` steht. Wer
  eine Option bewusst auskommentiert hat, bekommt sie also nicht noch
  einmal angehängt.
- Der ergänzte Teil steht am Ende der `.env` unter einer Überschrift mit
  Datum und dem Hinweis, dass auskommentierte Zeilen optional sind und zum
  Aktivieren nur das `#` entfernt werden muss. Vorher wird wie gewohnt
  eine Zeitstempel-Kopie der `.env` angelegt (`backup_file()`).
- Die Ausgabe nennt die Anzahl der ergänzten Variablen, getrennt nach
  aktiv und auskommentiert, und listet die aktiv ergänzten mit Namen auf.
  Mit `DRY_RUN=true` sieht man vorher, was ergänzt würde.
- Ein zweiter Lauf ergänzt nichts doppelt und meldet „`.env` ist
  vollständig".

**Technisch:** Der Abgleich läuft über ein kleines POSIX-`awk`-Programm
(funktioniert auch mit `mawk`, wie es auf DietPi/Debian-Minimal üblich
ist). Als Erklärungstext gilt der zusammenhängende Kommentarblock direkt
über der Variablen bis zur vorherigen Leerzeile; Abschnittsüberschriften
der Vorlage werden nicht mitkopiert. Windows-Zeilenenden (CRLF) in der
Vorlage werden entfernt.

**Beim ersten Lauf mit 1.21** werden bei einer älteren Installation einmalig
viele Variablen ergänzt (bei der aktuellen Vorlage typischerweise gut 160,
fast alle davon auskommentiert). Das ist gewollt. Die aktiv ergänzten
entsprechen den Standardwerten einer Neuinstallation; `DATABASE_URL`,
`OXICLOUD_DB_CONNECTION_STRING`, `OXICLOUD_STORAGE_PATH` und
`OXICLOUD_STATIC_PATH` setzt das Script direkt danach wie bisher auf die
richtigen Werte.

---

## Neuerung in 1.20

### Umgang mit nachträglich geänderten, bereits angewendeten Migrationen

Da dieses Script standardmäßig ungepinnt dem `main`-Branch folgt (siehe
`OXICLOUD_VERSION_PIN`), kann es vorkommen, dass Upstream eine Migration
nachträglich ändert, die bei euch **bereits erfolgreich angewendet**
wurde — z. B. ein reiner Performance-Rewrite einer als idempotent
nachgewiesenen Migration. `cargo sqlx migrate run` bricht in diesem Fall
absichtlich ab:

```
error: migration 20261017000002 was previously applied but has been modified
```

Das ist **kein Bug**, sondern der eingebaute Schutzmechanismus von sqlx
gegen unbemerkt veränderte Migrationshistorien — ob eine geänderte
Migration wirklich nur ein harmloser Rewrite war oder tatsächlich die
Semantik geändert hat, lässt sich nicht automatisch beurteilen. Das
Script hat diesen Fehler bisher unverändert durchgereicht: Abbruch,
manuelle Prüfung und ggf. manuelles Löschen des Tracking-Eintrags nötig.

Neu ist der Konfigurationsschalter `AUTO_REPAIR_MODIFIED_MIGRATIONS`
(Standard `false`):

- **`false` (Standard, unverändertes Verhalten):** Das Script erkennt den
  Fall, gibt eine ausführliche Warnung mit der betroffenen
  Migrationsversion und einer konkreten Handlungsanweisung aus und
  bricht dann wie bisher ab:

  ```
  WARNUNG: Migration 20261017000002 wurde bereits angewendet, ihr Inhalt
  wurde seitdem aber geändert (sqlx-Checksummen-Mismatch). Das passiert, weil
  dieser Lauf ungepinnt dem main-Branch folgt (OXICLOUD_VERSION_PIN="") und
  Upstream eine bereits ausgelieferte Migration nachträglich umgeschrieben hat.
  Empfehlung: OXICLOUD_VERSION_PIN im Konfigurationsblock auf einen festen
  Release-Tag setzen, damit das künftig nicht mehr passiert.

  AUTO_REPAIR_MODIFIED_MIGRATIONS ist false (Standard): kein automatischer
  Eingriff. Bitte manuell prüfen, ob die Änderung an der Migrationsdatei
  tatsächlich nur ein sicherer/idempotenter Rewrite ist (Diff der Migration
  gegen den vorherigen Stand ansehen), dann ggf. von Hand beheben mit:
    sudo -u postgres psql -d 'oxicloud' \
      -c "DELETE FROM _sqlx_migrations WHERE version = 20261017000002;"
  und das Script erneut ausführen. Alternativ AUTO_REPAIR_MODIFIED_MIGRATIONS=true
  setzen, falls dieser Fall künftig automatisch behoben werden soll.
  ```

- **`true`:** Das Script parst die betroffene Migrationsversion
  automatisch aus der sqlx-Fehlermeldung, löscht **gezielt nur ihren**
  Eintrag in `_sqlx_migrations` und führt `cargo sqlx migrate run`
  danach einmal automatisch erneut aus — die Migration läuft dann mit
  ihrem neuen Inhalt. Das ohnehin schon vor jeder Migration angelegte
  DB-Backup (siehe `DB_BACKUP_KEEP`) existiert zu diesem Zeitpunkt
  bereits und dient dabei als Absicherung nach unten.

Wichtig, was **unverändert** bleibt:

- Jede **andere** Art von Migrationsfehler (z. B. ein echter SQL-Fehler in
  einer neuen Migration) wird weiterhin unverändert durchgereicht — das
  Script bricht wie bisher mit dem ursprünglichen Exit-Code ab, unabhängig
  vom Stand von `AUTO_REPAIR_MODIFIED_MIGRATIONS`.
- `AUTO_REPAIR_MODIFIED_MIGRATIONS=true` behebt nur das **Symptom**. Der
  eigentlich robustere Weg gegen dieses Szenario bleibt,
  `OXICLOUD_VERSION_PIN` auf einen festen Release-Tag zu setzen — Upstream
  ändert Migrationen in bereits veröffentlichten Tags praktisch nie mehr
  nachträglich. Die Warnmeldung empfiehlt das deshalb unabhängig davon,
  wie `AUTO_REPAIR_MODIFIED_MIGRATIONS` gesetzt ist.
- `AUTO_REPAIR_MODIFIED_MIGRATIONS` hat außerhalb dieses einen Fehlerbilds
  keinerlei Effekt — bei erfolgreicher Migration oder einem anderen Fehler
  ändert sich am Ablauf nichts.

**Wann `true` sinnvoll ist:** Nur, wenn ihr bewusst darauf vertraut, dass
nachträgliche Änderungen von Upstream an bereits angewendeten Migrationen
bei diesem Projekt ausschließlich sichere/idempotente Rewrites sind (z. B.
reine Performance-Optimierungen ohne Semantikänderung) — z. B. für
unbeaufsichtigte Cron-Läufe, bei denen ein Abbruch mangels manueller
Prüfung ohnehin nur zu einem veralteten, aber laufenden Dienst führen
würde. Für produktive Instanzen mit hohen Anforderungen an Nachvollziehbarkeit
ist `OXICLOUD_VERSION_PIN` auf einen festen Tag in Kombination mit dem
Standardverhalten (`false`) der robustere Ansatz.

Der Zusammenfassungsblock am Scriptende zeigt seit 1.20 zusätzlich an, ob
`AUTO_REPAIR_MODIFIED_MIGRATIONS` aktiviert ist.

---

## Neuerung in 1.19

### Update-Hinweis erscheint jetzt zusätzlich im finalen Zusammenfassungsblock

Der Hinweis auf eine neuere Script-Version (siehe „Neuerung in 1.16")
stand bisher nur mitten im scrollenden Lauf-Output, direkt nach dem
Preflight-Check:

```
==> Verifiziere, dass die Basis-Programme tatsächlich verfügbar sind...
    Basis-Abhängigkeiten sind vorhanden (...).

Hinweis: Auf GitHub liegt eine andere Version von install-oxicloud.sh
         (lokal: 1.17, dort auf 'main': 1.18).
         https://github.com/roswitina/oxicloud-install

==> Node.js-Version ist festgenagelt auf ...
```

Bei einem normalen, mehrere Minuten dauernden Durchlauf (Node/Rust-Update,
Build, Migration, ...) scrollt diese Zeile schnell aus dem sichtbaren
Bereich heraus. Im finalen Zusammenfassungsblock am Scriptende — dem Teil,
den man tatsächlich anschaut, weil dort URL, aktives Release,
DB-Passwort etc. stehen — tauchte der Hinweis bisher nicht mehr auf. Ohne
konkreten Anlass, extra ins Install-Log zu schauen, ging er damit leicht
unter (siehe die entsprechende Rückfrage weiter oben in diesem Gespräch).

Der Hinweis erscheint jetzt **zusätzlich** direkt vor dem Ende der
Zusammenfassung:

```
======================================================================
 OxiCloud wurde installiert und gestartet.
 ...
 Logs (Installation): /var/log/oxicloud-install.log
======================================================================

Hinweis: Für install-oxicloud.sh liegt auf GitHub eine andere Version vor
         (lokal: 1.17, dort auf 'main': 1.18).
         https://github.com/roswitina/oxicloud-install
```

**Wichtig, damit das auch an Tagen funktioniert, an denen gar nicht
tatsächlich geprüft wird:** Der eigentliche GitHub-Abruf läuft weiterhin
höchstens alle `UPDATE_CHECK_INTERVAL_HOURS` (Standard 24, siehe „Neuerung
in 1.16"). Damit der Hinweis in der Zusammenfassung nicht nur an dem einen
Tag erscheint, an dem der Abruf tatsächlich stattfand, speichert die
Cache-Datei `/etc/oxicloud/.update-check-install-oxicloud` jetzt in einer
zweiten Zeile zusätzlich die zuletzt bekannte Remote-Version (Zeile 1 =
Zeitstempel, unverändertes Format). Wurde der Abruf in einem Lauf wegen
des Intervalls übersprungen, aber der letzte tatsächliche Check hatte
schon eine neuere Version gefunden, erscheint der Hinweis trotzdem — bis
entweder lokal aktualisiert wird oder ein neuer echter Check dieselbe
(dann aktuelle) Version bestätigt und den Cache-Eintrag überschreibt.

Kein Verhalten ändert sich, wenn `CHECK_FOR_UPDATES=false` gesetzt ist
oder ohnehin keine neuere Version gefunden wird — die zusätzliche Zeile
im Abschlussblock erscheint nur, wenn es tatsächlich etwas zu melden gibt.

---

Dreizehn Verbesserungen aus einer weiteren Review-Runde — drei davon
echte Bugfixes, der Rest Härtung und ein neuer Simulationsmodus.

### 1. Bugfix: `latest`-Release-Ermittlung gegen fehlschlagenden curl abgesichert

`resolve_target_ref()` (nur relevant bei `OXICLOUD_VERSION_PIN="latest"`)
rief `api.github.com` unter `set -e -o pipefail` auf, **ohne** die Pipe
gegen einen fehlschlagenden `curl` abzusichern — anders als die analoge,
bereits in 1.11 gefixte Node-LTS-Ermittlung. Schlug der Aufruf fehl (kein
Internet, GitHub down, Rate-Limit), brach die Pipe sofort und
**stillschweigend** ab; die eigentlich vorgesehene Fehlermeldung
(„Konnte neuestes GitHub-Release nicht ermitteln") wurde nie erreicht.
Jetzt mit `|| true` abgesichert, analog zum 1.11-Fix — die bestehende
Fehlerbehandlung greift wie ursprünglich vorgesehen, inklusive eines
neuen Hinweises auf `GITHUB_TOKEN` (siehe Punkt 3) als mögliche Ursache.

### 2. Dependency-Verifizierung deutlich nach vorne verschoben

Der Block „Verifiziere, dass alle benötigten Programme tatsächlich
verfügbar sind" (git, curl, jq, openssl, psql) lief bisher **nach** dem
DB-Backup und `cargo sqlx migrate run` — beide setzen `psql` bzw. `cargo`
bereits voraus. Fehlte eines der Basis-Tools trotz Preflight, scheiterte
der Lauf an dieser Stelle mit einem unklaren Fehler mitten in der
DB-Logik, statt mit der eigentlich vorgesehenen klaren Meldung. Die
Basis-Verifizierung (`git`, `curl`, `jq`, `openssl`, `psql`) läuft jetzt
direkt nach dem Preflight-Check; die Verifizierung von `node`/`npm`/`cargo`
folgt weiterhin nach deren Installation/Update, aber weiterhin **vor** dem
eigentlichen Build.

### 3. Optionales `GITHUB_TOKEN`

Neue Konfigurationsvariable `GITHUB_TOKEN` (leer = Standard, anonyme
Aufrufe). Falls gesetzt, wird sie als `Authorization: token ...`-Header an
**beide** GitHub-API-Aufrufe angehängt: den Update-Check (1.16) und die
`OXICLOUD_VERSION_PIN=latest`-Auflösung. Relevant vor allem bei häufigen
automatisierten Läufen (Cron) von derselben IP, die sonst leichter ins
anonyme GitHub-Rate-Limit (60 Requests/Stunde) laufen können — was dank
Fix 1 zwar nicht mehr hart abbricht, aber weiterhin unnötig wäre. Ein
Token ohne besondere Rechte (reines Anheben des Rate-Limits) genügt.

### 4. Swapfile wird nur noch bei tatsächlich anstehendem Rebuild angelegt

Die automatische Swapfile-Logik (OOM-Schutz beim Kompilieren) prüfte
bisher nur RAM und ob bereits Swap aktiv ist — **nicht**, ob `NEED_BUILD`
überhaupt `1` ist. Bei knappem RAM legte das Script also bei **jedem**
Lauf (auch reinen „nichts geändert"-Läufen) einen 8-GB-Swapfile per
`fallocate`+`mkswap`+`swapon` an und entfernte ihn am Ende wieder —
unnötiger I/O- und Zeitaufwand. Die Bedingung prüft jetzt zusätzlich
`NEED_BUILD -eq 1`.

### 5. Swapfile-Cleanup läuft jetzt garantiert über den EXIT-Trap

Vorher wurde ein automatisch angelegter Swapfile nur am **glücklichen**
Skriptende wieder entfernt. Brach das Script vorher ab — DB-Backup
fehlgeschlagen, Migration fehlgeschlagen, Health-Check fehlgeschlagen
(jeweils `exit 1`) — blieb der Swapfile dauerhaft aktiv und in
`/etc/fstab` eingetragen. Der bestehende `trap ... EXIT`-Mechanismus
(bisher nur für die Webhook-Benachrichtigung genutzt, jetzt
`cleanup_on_exit` statt `notify_on_failure`) räumt den Swapfile jetzt bei
**jedem** Skriptende auf, unabhängig vom Exit-Code.

### 6. Neuer `current-good`-Symlink als verlässliches Rollback-Ziel

Bisher zielte das automatische Rollback auf „das zuletzt modifizierte
**andere** Release unter `releases/`" — ohne Garantie, dass dieses Release
selbst jemals einen Health-Check bestanden hat. Bei zwei aufeinanderfolgenden
kaputten Commits konnte das Rollback also auf ein ebenfalls defektes
Release zeigen. Neu ist der Symlink `${OXICLOUD_HOME}/current-good`, der
**ausschließlich** nach einem erfolgreichen Health-Check aktualisiert wird
(`ln -sfn` auf das aktuell aktive Release). Automatisches Rollback zielt
jetzt auf `current-good` statt auf eine reine Zeitstempel-Heuristik; die
Release-Bereinigung (`KEEP_RELEASES`) nimmt `current-good` zusätzlich zu
`current` von der Löschung aus.

### 7. Health-Check akzeptiert konfigurierbare HTTP-Codes

Der Health-Check nutzte bisher `curl -fsS`, was **jeden** Nicht-2xx-Status
als „Dienst down" wertete. Antwortet OxiCloud auf `/` z. B. mit einem
Redirect (301/302) oder verlangt Auth (401), ist das trotzdem ein Beweis,
dass der Dienst lebt und antwortet — wurde vorher aber fälschlich als
Fehlschlag gewertet und hätte ein unnötiges Rollback ausgelöst. Zwei neue
Variablen steuern das jetzt:

- `HEALTH_CHECK_PATH` (Standard `"/"`) — der geprüfte Pfad
- `HEALTH_CHECK_EXPECTED_CODES` (Standard `"200 301 302 401"`) — Leerzeichen-
  getrennte Liste akzeptierter HTTP-Statuscodes

Der Check liest jetzt den tatsächlichen Statuscode
(`curl -s -o /dev/null -w '%{http_code}'`) und vergleicht ihn gegen diese
Liste, statt sich auf `curl -f` zu verlassen.

### 8. ufw-Firewall-Hinweis prüft jetzt zuerst, ob ufw aktiv ist

Der bisherige Check fragte direkt `ufw status | grep -qE "^PORT... ALLOW"`
ab. War `ufw` zwar installiert, aber **inaktiv** (`Status: inactive`),
matchte das Grep naturgemäß nicht — das Script warnte dann fälschlich vor
einem „nicht freigegebenen Port", obwohl inaktives ufw gar nichts
blockiert (der Port ist in dem Fall ohnehin offen). Der Check fragt jetzt
zuerst `ufw status | grep -q "Status: active"` ab und gibt bei inaktivem
ufw stattdessen einen allgemeineren, korrekten Hinweis aus.

### 9. Backup vor destruktivem Directory-Cleanup

War `OXICLOUD_HOME` nicht leer, aber (noch) kein Git-Repository, wurde der
Inhalt bisher kommentarlos per `rm -rf` gelöscht — im Gegensatz zum
sonstigen Vorsichtsprinzip des Scripts (Backups vor `.env`, systemd-Unit,
`/etc/fstab`). Falls `OXICLOUD_HOME` versehentlich auf ein bereits
genutztes Verzeichnis zeigt, legt das Script jetzt vorher einen Tarball
unter `/etc/oxicloud/pre-clone-backups/oxicloud-home-<timestamp>.tar.gz`
an (best effort — schlägt das Tarball-Backup selbst fehl, wird das
geloggt, der Lauf aber nicht deswegen abgebrochen).

### 10. `set_env_var()` escaped Sonderzeichen für `sed`

Die Funktion ersetzte `.env`-Werte bisher über `sed -i "s#^KEY=.*#KEY=VALUE#"`
ohne den Wert zu escapen. Enthielt `VALUE` selbst ein `&` (Sed-Sonderzeichen
im Ersetzungsteil, wird zum gesamten Match) oder das Delimiter-Zeichen `#`,
konnte das zu einer falschen Ersetzung oder einem Sed-Fehler führen — z. B.
bei einer `ENV_OVERRIDE_BASE_URL` mit Fragment oder Query-String. Der Wert
wird jetzt vor dem Einsetzen escaped (`&`, `/`, `\`).

### 11. Restriktivere Rechte auf `/etc/oxicloud`

Einzelne Dateien darin waren immer schon geschützt (`.env` 640,
`.db_password` 600, DB-Backups 600), das Verzeichnis selbst aber ohne
explizite Rechte (Standard-`umask` von `mkdir -p`). Andere lokale User
konnten damit zumindest das Directory-Listing einsehen (z. B. Dateinamen
der DB-Backups). `/etc/oxicloud` bekommt jetzt `chmod 750`.

### 12. Robuste Diskspace-Ermittlung

`ACTUAL_DISK_GB` wurde per `df --output=avail ... | tail -1 | tr -dc '0-9'`
ermittelt. Bei einem exotischen oder (temporär) nicht existierenden
`OXICLOUD_HOME`-Elternverzeichnis konnte das eine leere Zeichenkette statt
einer Zahl liefern — der spätere Integer-Vergleich (`-lt`) wäre dann mit
„integer expression expected" abgestürzt, statt die vorgesehene
Fehlerbehandlung zu durchlaufen. `: "${ACTUAL_DISK_GB:=0}"` erzwingt jetzt
einen sauberen Fallback auf `0`.

### 13. Neuer `DRY_RUN`-Modus

Neue Konfigurationsvariable `DRY_RUN` (Standard `false`). Bei `true`
werden alle destruktiven/ändernden Schritte — `chown`, `git reset --hard`,
Paketinstallationen, Node/Rust-Updates, DB-Rolle/Passwort, `.env`-Schreiben,
Build, systemd-Aktionen, Swapfile/Firewall-Änderungen — nur mit `[DRY_RUN]`
geloggt statt ausgeführt. Nützlich, um eine geänderte Konfiguration
(`ENV_OVERRIDE_*`, Pins, `ENABLE_PLUGINS`, ...) vorab durchzuspielen und
den geplanten Ablauf zu sehen, ohne den laufenden Dienst oder das System
tatsächlich zu beeinflussen. Health-Check und Rollback-Logik werden bei
`DRY_RUN=true` komplett übersprungen, da es nichts Reales gibt, das
geprüft werden könnte.

---

## Neuerung in 1.17

### Selbstheilung bei fehlschlagendem `cargo build --release --locked`

Da dieses Script standardmäßig ungepinnt dem `main`-Branch von OxiCloud
folgt, kann es passieren, dass Upstream im main-Branch eine Abhängigkeit
in `Cargo.toml` ändert oder hinzufügt, ohne die eingecheckte `Cargo.lock`
mit zu aktualisieren. `cargo build --release --locked` verweigert dann
bewusst jede Aktualisierung der Lockfile und bricht stattdessen ab:

```
error: cannot update the lock file ... because --locked was passed
```

Vorher musste das jedes Mal von Hand behoben werden
(`cargo generate-lockfile` + Build erneut anstoßen). Das Script macht das
jetzt selbst:

1. Erster Build-Versuch bleibt bewusst strikt mit `--locked` — ein
   „echter" Kompilierfehler (z. B. kaputter Code, fehlende Systemlib) soll
   weiterhin sofort auffallen und nicht durch automatisches Neu-Lock'en
   verschleiert werden.
2. Schlägt nur dieser Versuch fehl, wird **nur** die Lockfile neu erzeugt
   (`cargo generate-lockfile`, ohne `--offline` — braucht kurz Netzwerk)
   und der Release-Build danach **genau einmal** erneut mit `--locked`
   versucht.
3. Schlägt auch dieser zweite Versuch fehl, liegt es an etwas anderem als
   der Lockfile — das Script bricht dann regulär ab (`set -e`), inklusive
   der üblichen Fehler-Benachrichtigung per Webhook, falls konfiguriert.

Kein Verhaltensunterschied, wenn der erste `--locked`-Versuch ohnehin
erfolgreich ist (der Normalfall) — die Zwei-Versuche-Logik greift nur im
Fehlerfall.

---

## Neuerung in 1.16

### Selbstprüfung auf neuere Script-Version (GitHub)

Bei jedem Lauf (nachdem `curl` durch den Preflight-Check garantiert
vorhanden ist) prüft das Script, ob im `main`-Branch von
[roswitina/oxicloud-install](https://github.com/roswitina/oxicloud-install)
eine andere `SCRIPT_VERSION` steht als lokal gerade läuft:

```
Hinweis: Auf GitHub liegt eine andere Version von install-oxicloud.sh
         (lokal: 1.16, dort auf 'main': 1.17).
         https://github.com/roswitina/oxicloud-install
```

Wichtig, was das **nicht** tut:
- **Kein automatisches Update.** Es wird nichts heruntergeladen, ersetzt
  oder ausgeführt — nur die Versionsnummer im Header des Remote-Scripts
  wird per `curl` (seit 1.18 optional mit `GITHUB_TOKEN`, siehe „Neuerungen
  in 1.18", Punkt 3) abgerufen und verglichen.
- **Kein Abbruch bei Fehlschlag.** Kein Internet, GitHub nicht erreichbar,
  Rate-Limit, kein `curl` vorhanden — in jedem Fall wird der Check still
  übersprungen (`|| true`, 5s Timeout), der eigentliche Install-/Update-Lauf
  läuft unbeeinflusst weiter.
- **Kein Spam bei häufigen/automatisierten Läufen.** Der tatsächliche
  GitHub-Abruf erfolgt höchstens alle `UPDATE_CHECK_INTERVAL_HOURS`
  (Standard 24) - der Zeitpunkt des letzten Checks wird in
  `/etc/oxicloud/.update-check-install-oxicloud` gecacht (seit 1.19
  zusätzlich mit der zuletzt gefundenen Remote-Version in Zeile 2, siehe
  „Neuerung in 1.19").

Seit 1.19 erscheint der Hinweis zusätzlich am Ende im Zusammenfassungsblock
erneut (siehe „Neuerung in 1.19") — die grundsätzliche Logik hier (Cache,
Fehlertoleranz, kein Auto-Update) bleibt davon unverändert.

Per `CHECK_FOR_UPDATES=false` komplett abschaltbar (z. B. auf Servern ohne
Internetzugang zu GitHub); `UPDATE_CHECK_REPO`/`UPDATE_CHECK_BRANCH` sind
konfigurierbar, falls ihr das Tooling forkt.

---

## Neuerungen in 1.15

Vier Verbesserungen nach einem weiteren Review — alle betreffen Fälle, in
denen das Script vorher entweder unnötig viel Arbeit machte oder sich in
Randfällen falsch verhalten hätte.

### 1. Health-Check wird bei fester, nicht-lokaler `ENV_OVERRIDE_SERVER_HOST` übersprungen

Der Health-Check prüft fest gegen `http://127.0.0.1:${OXICLOUD_PORT}${HEALTH_CHECK_PATH}`
(Pfad seit 1.18 konfigurierbar, siehe oben). Für `0.0.0.0`/`::` (Dienst
lauscht auf allen Interfaces, `127.0.0.1` also eingeschlossen) ist das
kein Problem. Wird `ENV_OVERRIDE_SERVER_HOST` aber auf eine **feste,
andere** Adresse gesetzt (z. B. `"192.168.1.50"`), lauscht der Dienst dort
und nicht mehr auf `127.0.0.1` — der Check wäre dann bei **jedem** Rebuild
fälschlich fehlgeschlagen und hätte ein unnötiges Rollback ausgelöst,
obwohl der Dienst einwandfrei läuft. Das Script überspringt den Check
jetzt in diesem Fall bewusst, mit dem Hinweis, den Dienst manuell zu
prüfen (`systemctl status oxicloud`).

### 2. Health-Check läuft jetzt auch bei der Erstinstallation

Vorher lief der komplette Health-Check-Abschnitt nur ab dem **zweiten**
Lauf, weil nur dann ein Rollback-Ziel existiert. Damit wurde eine kaputte
**Erstinstallation** (z. B. fehlerhafte `.env`) nie geprüft — das Script
meldete am Ende trotzdem unkommentiert "erfolgreich installiert". Jetzt
läuft der Check immer; nur der eigentliche Rollback-Schritt bleibt
naturgemäß auf den Fall beschränkt, dass es ein `current-good`-Release
gibt (seit 1.18, siehe oben — vorher „ein vorheriges Release"). Schlägt
der Check bei der Erstinstallation fehl, bricht das Script mit einer
klaren Fehlermeldung ab, statt fälschlich Erfolg zu melden.

### 3. Rollback-Status fließt in die Webhook-Meldung ein

Die interne Variable, die bisher nur "es gab ein Rollback" markierte, ohne
je gelesen zu werden, wurde entfernt. Stattdessen trägt ein aussagekräftiger
Text (z. B. "Automatisches Rollback auf .../oxicloud-<hash> (current-good)
erfolgreich.") jetzt direkt in die `NOTIFY_WEBHOOK_URL`-Meldung ein — bei
einem unbeaufsichtigten Cron-Lauf seht ihr damit sofort im Chat/Webhook,
*warum* der Lauf fehlgeschlagen ist, statt nur eines generischen
Exit-Codes.

### 4. `chown -R` läuft nur noch, wenn tatsächlich nötig

Der rekursive `chown` auf `${OXICLOUD_HOME}` (Selbstheilung, siehe
Grundidee) lief bisher bei **jedem** Lauf bedingungslos — bei einem
gewachsenen Checkout mit `releases/` (mehrere Binaries), `target/`
(Rust-Build-Cache) und `node_modules/` unnötig langsam, wenn ohnehin
schon alles korrekt gehört. Ein schneller Scan prüft jetzt vorab, ob
überhaupt eine falsch gehörende Datei existiert; der eigentliche
`chown -R` läuft nur noch in diesem Fall.

---

## Neuerung in 1.14

### Aufbewahrungsgrenze für generische Datei-Backups

`backup_file()` — genutzt für `/etc/oxicloud/.env`, `/etc/systemd/system/oxicloud.service`
und `/etc/fstab` (beim Swapfile-Handling) — legte bei jedem Aufruf eine
weitere Zeitstempel-Kopie unter `<verzeichnis>/backups/` an, bereinigte
aber nie etwas. Im Unterschied zu `DB_BACKUP_KEEP` (Abschnitt 1.13) und
`KEEP_RELEASES` wuchs dieses Verzeichnis damit unbegrenzt — besonders
relevant bei `.env`, die pro Lauf potenziell **zweimal** gesichert wird
(einmal beim Ergänzen neuer Variablen aus der Vorlage, einmal direkt
danach vor dem Setzen von `DATABASE_URL` etc.).

Jetzt bereinigt `backup_file()` nach jedem Aufruf automatisch auf die
neuesten `GENERIC_BACKUP_KEEP` Stände **pro Datei** (Standard `10`).
Zusätzlich gibt es jetzt einen Kollisionsschutz: Fallen zwei Backups
derselben Datei in dieselbe Sekunde (Zeitstempel hat nur
Sekundenauflösung — genau der Fall bei den zwei `.env`-Backups pro Lauf),
wird die PID an den Dateinamen angehängt (`.env.<timestamp>-<pid>.bak`),
statt dass der zweite Aufruf den ersten Backup-Stand stillschweigend
überschreibt.

### Alle Schwellwerte jetzt zentral im Konfigurationsblock

Zusätzlich wurden `DISK_ABORT_THRESHOLD_GB`, `DB_BACKUP_KEEP` und
`HEALTH_RETRIES` (alle drei aus 1.13) sowie das neue `GENERIC_BACKUP_KEEP`
aus ihren bisherigen Positionen direkt über der jeweiligen Codestelle in
den zentralen Konfigurationsblock am Scriptanfang verschoben — seit 1.18
gilt das ebenso für alle neuen Variablen (`GITHUB_TOKEN`, `DRY_RUN`,
`HEALTH_CHECK_PATH`, `HEALTH_CHECK_EXPECTED_CODES`), seit 1.20 auch für
`AUTO_REPAIR_MODIFIED_MIGRATIONS`.

---

## Neuerungen in 1.13

Sieben Verbesserungen nach einem Review des bisherigen Stands — alle
zielen darauf ab, Fehler früher abzufangen bzw. automatisch zu behandeln,
statt sie erst später kryptisch auffallen zu lassen.

### 1. Automatisches Health-Check-Rollback

Bisher war Rollback ein rein manueller Schritt — obwohl das Script mit
den nach Git-Commit-Hash versionierten Binaries unter `releases/` und dem
`current`-Symlink die Infrastruktur dafür längst hatte.

Jetzt gilt: Nach einem Rebuild + Neustart prüft das Script bis zu
`HEALTH_RETRIES`-mal im Abstand von 2 Sekunden, ob der Dienst aktiv ist
**und** auf `http://127.0.0.1:${OXICLOUD_PORT}${HEALTH_CHECK_PATH}` mit
einem der `HEALTH_CHECK_EXPECTED_CODES` antwortet (Pfad/Codes
konfigurierbar seit 1.18, siehe „Neuerungen in 1.18", Punkt 7). Schlägt
das fehl:

```
FEHLER: Dienst antwortet nach 10 Versuchen (je 2s) nicht auf Port 8086/.
    Prüfe: journalctl -u oxicloud -n 50 --no-pager
    Rolle automatisch zurück auf zuletzt gesundes Release: /opt/oxicloud/releases/oxicloud-<alter-hash>
    Rollback erfolgreich, Dienst läuft wieder mit /opt/oxicloud/releases/oxicloud-<alter-hash>.
```

`current` wird automatisch auf das Release hinter `current-good`
zurückgesetzt (seit 1.18, siehe „Neuerungen in 1.18", Punkt 6 — vorher:
„das zuletzt modifizierte andere Release"), der Dienst erneut gestartet,
und das Script beendet sich danach trotzdem mit Exit-Code 1 (damit ein
automatisierter/Cron-Lauf den Fehlschlag als solchen erkennt — siehe
Punkt 7). Gibt es kein `current-good`-Release (z. B. Erstinstallation)
oder scheitert auch der Rollback-Neustart, wird das deutlich ausgegeben —
dann ist manueller Eingriff nötig.

### 2. Automatisches DB-Backup vor jeder Migration

`cargo sqlx migrate run` lief bisher bei jedem Lauf ohne vorheriges
Backup. Jetzt läuft direkt davor:

```bash
sudo -u postgres pg_dump "${DB_NAME}" | gzip > /etc/oxicloud/db-backups/oxicloud-<timestamp>.sql.gz
```

mit `chmod 600` und automatischer Bereinigung auf die letzten
`DB_BACKUP_KEEP` Stände (Standard 10). Schlägt das Backup selbst fehl,
bricht das Script **vor** der Migration ab, statt eine potenziell
riskante Migration ohne Sicherheitsnetz laufen zu lassen. Seit 1.20 dient
dieses Backup zusätzlich als Absicherung für den optionalen
`AUTO_REPAIR_MODIFIED_MIGRATIONS`-Mechanismus (siehe „Neuerung in 1.20").

### 3. Log-Rotation für das Install-Log

`/var/log/oxicloud-install.log` wuchs bisher unbegrenzt (`tee -a` bei
jedem Lauf). Sofern `logrotate` auf dem System vorhanden ist, legt das
Script jetzt bei jedem Lauf idempotent `/etc/logrotate.d/oxicloud-install`
an (wöchentliche Rotation, 8 Generationen, komprimiert,
`copytruncate` — wichtig, da das Log während des Laufs offen gehalten
wird).

### 4. `git fetch` + `reset --hard origin/main` statt `git pull`

Passend zur bereits bestehenden Philosophie, dass `/opt/oxicloud`
ausschließlich vom Script verwaltet wird: `git pull origin main` konnte
an einem divergierten main scheitern, z. B. nach einem Force-Push
upstream im Repository. `git fetch origin main` + `git reset --hard
origin/main` erzwingt stattdessen immer exakt den Stand von
`origin/main`, unabhängig von der lokalen Historie. Betrifft nur den
Fall, dass kein `OXICLOUD_VERSION_PIN` gesetzt ist (also dem
`main`-Branch gefolgt wird) — bei einem festen Tag/Release lief es schon
vorher über `git checkout`. Genau dieses ungepinnte main-Tracking ist
auch die Voraussetzung dafür, dass der in 1.20 behandelte Fall
(nachträglich geänderte, bereits angewendete Migration) überhaupt
auftreten kann.

### 5. Harter Abbruch bei kritisch wenig Diskspace

Bisher gab es nur eine Warnung, falls weniger als die empfohlenen ~20 GB
frei waren; der Build lief trotzdem an und scheiterte im ungünstigsten
Fall erst mitten in `cargo build --release`. Jetzt bricht das Script
**vor** dem Build hart ab, wenn weniger als `DISK_ABORT_THRESHOLD_GB=5`
GB frei sind, mit Hinweisen, wo sich am ehesten Platz freiräumen lässt
(alte Releases, alte DB-Backups, `apt-get clean`). Die zugrunde liegende
Ermittlung der freien GB ist seit 1.18 zusätzlich gegen eine leere
Rückgabe abgesichert (siehe „Neuerungen in 1.18", Punkt 12).

### 6. Firewall-Hinweis bei `0.0.0.0`/`::`

Wird `ENV_OVERRIDE_SERVER_HOST` auf `0.0.0.0` oder `::` gesetzt (Dienst
lauscht auf allen Interfaces), prüft das Script — falls `ufw` vorhanden
ist — ob der Port dort freigegeben ist, und gibt andernfalls einen
deutlichen Hinweis aus, das selbst zu prüfen (Portweiterleitung,
Cloud-Security-Group, `ufw allow ${OXICLOUD_PORT}/tcp` falls gewünscht).
Seit 1.18 wird dabei zuerst geprüft, ob ufw überhaupt **aktiv** ist,
bevor vor einem angeblich nicht freigegebenen Port gewarnt wird (siehe
„Neuerungen in 1.18", Punkt 8) — vorher kam die Warnung fälschlich auch
bei inaktivem ufw. Ist `ufw` nicht vorhanden, erfolgt weiterhin ein
allgemeinerer Hinweis, das über `nftables`/`iptables`/Cloud-Firewall
manuell zu prüfen.

### 7. Optionale Fehler-Benachrichtigung per Webhook

Konfigurationsvariable `NOTIFY_WEBHOOK_URL` (leer = deaktiviert,
Standard). Ein `trap` auf `EXIT` (seit 1.18 `cleanup_on_exit`, siehe
„Neuerungen in 1.18", Punkt 5 — übernimmt zusätzlich das
Swapfile-Aufräumen) sorgt dafür, dass bei **jedem** Fehlschlag des
Scripts (Exit-Code ≠ 0, unabhängig an welcher Stelle) eine kurze
POST-Anfrage mit `{"text": "..."}` an die konfigurierte URL geschickt
wird (kompatibel zu Slack-/Mattermost-Incoming-Webhooks). Relevant vor
allem, falls das Script unbeaufsichtigt per Cron läuft — ohne das fällt
ein fehlgeschlagener Auto-Update-Lauf sonst erst auf, wenn der Dienst
schon länger down ist. Die Benachrichtigung selbst ist bewusst
fehlertolerant (`|| true`, 10s Timeout) und verändert nie den eigentlichen
Exit-Code des Scripts.

---

## Fix in 1.12

Entstanden aus einem echten fehlgeschlagenen Testlauf: Installation in
einem **LXC-Container** (Proxmox, Debian Trixie) brach mitten in der
PostgreSQL-Rolle-Anlage ab, während dieselbe Script-Version auf einer
vollwertigen VM (DietPi, x86) anstandslos durchlief.

### `sudo` fehlte in der Preflight-Paketliste

Ursache im Install-Log:
```
==> Lege PostgreSQL-Rolle und Datenbank an (falls noch nicht vorhanden)...
./install-oxicloud.sh: line 306: sudo: command not found
```

Viele minimale LXC-Templates (insbesondere die offiziellen
Proxmox-Debian-Templates) bringen `sudo` **nicht** vorinstalliert mit — im
Gegensatz zu vollwertigen VMs oder Images wie DietPi, wo es praktisch immer
vorhanden ist. Root zu sein (der `EUID`-Check am Scriptanfang) garantiert
nicht, dass der Befehl `sudo` selbst existiert. Das Script verlässt sich
aber an sehr vielen Stellen auf `sudo -u ...` — DB-Rolle anlegen,
Repo klonen, Rust/Cargo-Aufrufe, `npm run build`, uvm. — daher scheiterte
der Lauf beim allerersten `sudo`-Aufruf.

Vorher:
```bash
REQUIRED_APT_PACKAGES=(git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
```

Jetzt:
```bash
REQUIRED_APT_PACKAGES=(sudo git curl openssl build-essential pkg-config libssl-dev postgresql postgresql-contrib ca-certificates jq)
```

Der bestehende Preflight-Mechanismus (fehlende Pakete automatisch per
`apt-get install` nachziehen) deckt `sudo` damit von Anfang an mit ab,
noch bevor der erste `sudo -u ...`-Aufruf im Script erreicht wird.

**Falls du bereits einen fehlgeschlagenen Lauf mit einer älteren Version
in einem solchen Container hattest:** einfach `apt-get install -y sudo`
manuell nachholen oder das Script erneut mit Version 1.12 (oder neuer)
ausführen — Idempotenz sorgt dafür, dass der Rest des vorherigen
(Teil-)Laufs sauber fortgesetzt wird.

---

## Fixes in 1.11

Entstanden aus einem Code-Review, nicht aus einem konkreten Vorfall bei
diesem Script — aber alle drei Muster waren real bei anderen Skripten des
Projekts aufgetreten.

### 1. `set -e`-Fallstrick bei der Node.js-LTS-Ermittlung

```bash
LATEST_LTS_MAJOR="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '...' | sed '...' | cut -d. -f1)"
```

Das war eine plain Command-Substitution mit Pipe unter `set -e -o pipefail`
**ohne** Absicherung. Schlug `curl` fehl (nodejs.org nicht erreichbar,
Netzwerk-Hänger), beendete sich das **ganze Script sofort und
stillschweigend** an dieser Zeile — der direkt darunterstehende Fallback
(`LATEST_LTS_MAJOR=24`) wurde **nie erreicht**. Jetzt mit `|| true`
abgesichert:

```bash
LATEST_LTS_MAJOR="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | jq -r '...' 2>/dev/null | sed '...' | cut -d. -f1)" || true
```

`LATEST_LTS_MAJOR` bleibt bei einem Fehlschlag einfach leer, der
nachfolgende `if [[ -z "${LATEST_LTS_MAJOR}" ]]`-Fallback greift dann wie
ursprünglich vorgesehen. Derselbe Fallstrick wurde in 1.18 an der
analogen Stelle für die `OXICLOUD_VERSION_PIN=latest`-Ermittlung gefunden
und behoben (siehe „Neuerungen in 1.18", Punkt 1).

### 2. DB-Passwort wurde nur beim Erstanlegen der Rolle gesetzt

Vorher:
```bash
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';"
```
Existierte die Rolle bereits — z. B. nach einem abgebrochenen vorherigen
Lauf oder einer aus einem Backup wiederhergestellten Datenbank — mit einem
**anderen** Passwort als in `/etc/oxicloud/.db_password` gespeichert, blieb
das unbemerkt, bis `sqlx migrate run` oder der Dienst selbst mit einem
kryptischen Auth-Fehler scheiterte.

Jetzt läuft bei **jedem** Lauf zusätzlich:
```bash
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';"
```
(idempotent, harmlos falls das Passwort ohnehin schon übereinstimmt), plus
direkt danach ein echter Verbindungstest:
```bash
PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;"
```
Schlägt der Test fehl, bricht das Script mit einer konkreten Fehlermeldung
ab (inkl. Hinweis auf `pg_hba.conf`), statt erst später kryptisch zu
scheitern.

### 3. DB-Passwort stand im Klartext im systemd-Unit-File

Vorher enthielt die generierte `oxicloud.service` diese Zeile:
```ini
Environment=DATABASE_URL=postgres://oxicloud:<klartext-passwort>@localhost:5432/oxicloud
```
Unit-Files unter `/etc/systemd/system/` sind standardmäßig `644` — **für
alle lokalen User lesbar**. Das stand damit im Widerspruch zur sonst
vorbildlich restriktiven Rechtevergabe des Scripts (`.env` mit `640`,
`.db_password` mit `600`).

Jetzt wird `DATABASE_URL` stattdessen zusätzlich in die (weiterhin `640`,
`root:oxicloud`) `.env` geschrieben:
```bash
set_env_var "DATABASE_URL" "${DATABASE_URL}" "${CONFIG_DIR}/.env"
```
und die Unit lädt sie ausschließlich über `EnvironmentFile=/etc/oxicloud/.env`
— die `Environment=DATABASE_URL=...`-Zeile im Unit-File ist komplett
entfernt.

**Falls du eine ältere Installation (vor 1.11) hast**: Nach dem Update mit
diesem Script einmal prüfen, ob das alte Unit-File noch die Klartext-Zeile
enthält, und ggf. manuell bereinigen:
```bash
grep -n "DATABASE_URL" /etc/systemd/system/oxicloud.service
```
Ein erneuter Lauf von `install-oxicloud.sh` schreibt die Unit ohnehin neu
(mit vorherigem Backup unter `/etc/systemd/system/backups/`).

---

## Voraussetzungen

- Debian/Ubuntu mit systemd
- root-Zugriff (bzw. `sudo` — wird seit 1.12 falls nötig selbst
  nachinstalliert, siehe „Fix in 1.12" oben; **auf minimalen LXC-Templates
  vorher trotzdem sinnvoll, einmal manuell zu prüfen, ob es schon da ist**)
- Internetzugang auf dem Zielserver (für `apt`, GitHub, crates.io, npm-Registry, rustup, NodeSource, optional den Webhook-Endpunkt aus `NOTIFY_WEBHOOK_URL`)
- Ausreichend Ressourcen zum Kompilieren — siehe Abschnitt „Ressourcenbedarf" unten. Fehlt genug RAM **und** steht ein Rebuild an, legt das Script selbst einen temporären Swapfile an (seit 1.18 nur noch bei tatsächlich anstehendem Rebuild, siehe „Neuerungen in 1.18", Punkt 4). Seit 1.13 bricht das Script bei kritisch wenig Diskspace vor dem Build hart ab, statt nur zu warnen.
- `logrotate` (optional): falls vorhanden, richtet das Script seit 1.13 automatisch eine Rotation für `/var/log/oxicloud-install.log` ein
- `curl` erreichbar auf `127.0.0.1:${OXICLOUD_PORT}` (für den seit 1.13 vorhandenen, seit 1.18 konfigurierbaren Health-Check nach jedem Rebuild)
- optional: ein `GITHUB_TOKEN` (seit 1.18), falls häufige automatisierte Läufe ins anonyme GitHub-Rate-Limit laufen könnten

Wird **auf dem Zielserver selbst** installiert:
- Rust (via `rustup`, Benutzer-lokal)
- Node.js (via NodeSource, systemweit)
- PostgreSQL (via `apt`)
- `sqlx-cli` (für Datenbank-Migrationen)

---

## Aufruf

```bash
sudo bash install-oxicloud.sh
```

Kein Parameter nötig — alle Einstellungen erfolgen über den
Konfigurationsblock am Scriptanfang (siehe unten) oder durch erneutes
Ausführen mit geänderten Werten dort.

**Testlauf ohne echte Änderungen** (neu in 1.18): `DRY_RUN=true` im
Konfigurationsblock setzen, dann normal ausführen. Alle geplanten
Schritte werden mit `[DRY_RUN]`-Präfix geloggt, aber nicht ausgeführt
(siehe „Neuerungen in 1.18", Punkt 13).

---

## Konfigurationsblock (Kopf des Scripts)

| Variable | Standard | Bedeutung |
|---|---|---|
| `OXICLOUD_USER` | `oxicloud` | Systemuser, unter dem geklont/gebaut/betrieben wird |
| `OXICLOUD_HOME` | `/opt/oxicloud` | Git-Working-Copy **und** Installationsort — wird ausschließlich vom Script verwaltet |
| `OXICLOUD_PORT` | `8086` | Anzeige-URL am Ende **und** Ziel des automatischen Health-Checks nach jedem Rebuild |
| `DB_NAME` / `DB_USER` | `oxicloud` | Name von Datenbank und Postgres-Rolle |
| `REPO_URL` | `https://github.com/AtalayaLabs/OxiCloud.git` | Woher geklont wird — siehe Hinweis im Script zur Doppel-Existenz von `DioCrafts/OxiCloud` und `AtalayaLabs/OxiCloud` |
| `DRY_RUN` *(neu in 1.18)* | `false` | `true` = keine echten Systemänderungen, alle destruktiven/ändernden Schritte werden nur geloggt |
| `KEEP_RELEASES` | `5` | Wie viele alte versionierte Binaries behalten werden; `0` = nichts löschen. Das aktive Release **und** `current-good` bleiben davon immer ausgenommen |
| `NODE_VERSION_PIN` | leer | Leer = immer neueste LTS-Major-Version; sonst z. B. `"22"` |
| `RUST_VERSION_PIN` | leer | Leer = immer `rustup update stable`; sonst z. B. `"1.82.0"` |
| `ENV_LANGUAGE` *(neu in 1.22)* | leer | Sprache der Erklärungstexte in der `.env`: `""` = wie bisher, `"de"` = Deutsch (Vorlage `ENV_TEMPLATE_DIR/example.env.de`), `"en"` = Englisch. Baut eine bestehende `.env` einmalig geprüft um, siehe „Neuerung in 1.22" |
| `ENV_TEMPLATE_DIR` *(neu in 1.22)* | `/etc/oxicloud` | Ordner mit übersetzten Vorlagen `example.env.<sprache>` |
| `ENV_OVERRIDE_SERVER_HOST` | leer | Überschreibt `OXICLOUD_SERVER_HOST` in der `.env`, z. B. `"0.0.0.0"` — mit Firewall-Hinweis bei `0.0.0.0`/`::` (seit 1.18 nur bei aktivem ufw, siehe oben) |
| `ENV_OVERRIDE_BASE_URL` | leer | Überschreibt `OXICLOUD_BASE_URL` in der `.env`, z. B. `"https://cloud.example.com"` — Sonderzeichen werden seit 1.18 korrekt escaped |
| `OXICLOUD_VERSION_PIN` | leer | Leer = folgt `main`-Branch; `"latest"` = neuestes GitHub-Release (seit 1.18 robust gegen fehlschlagenden Abruf, siehe oben); `"vX.Y.Z"` = fester Tag. **Empfehlung:** für produktive Instanzen fest pinnen, damit der in 1.20 behandelte Fall (nachträglich geänderte, bereits angewendete Migration) gar nicht erst auftritt |
| `ENABLE_PLUGINS` | `false` | `true` baut mit Cargo-Feature `plugins` (WASM-Runtime via Extism) und setzt `OXICLOUD_ENABLE_PLUGINS=true` |
| `NOTIFY_WEBHOOK_URL` | leer | Leer = keine Benachrichtigung; sonst Slack-/Mattermost-kompatible Webhook-URL, die bei jedem fehlgeschlagenen Lauf (Exit-Code ≠ 0) einen POST mit `{"text": "..."}` erhält |
| `GENERIC_BACKUP_KEEP` | `10` | Wie viele Zeitstempel-Backups **pro Datei** in den jeweiligen `backups/`-Unterordnern behalten werden (`.env`, systemd-Unit, `/etc/fstab`); `0` = keine Bereinigung |
| `DB_BACKUP_KEEP` | `10` | Wie viele DB-Backups unter `/etc/oxicloud/db-backups` behalten werden; `0` = keine Bereinigung |
| `AUTO_REPAIR_MODIFIED_MIGRATIONS` *(neu in 1.20)* | `false` | `true` behebt den Fall „migration X was previously applied but has been modified" automatisch (Tracking-Eintrag löschen + Migration erneut ausführen), statt wie im Standardverhalten abzubrechen — siehe „Neuerung in 1.20" |
| `DISK_ABORT_THRESHOLD_GB` | `5` | Unterhalb dieser freien GB im Ressourcen-Check bricht das Script vor dem Build hart ab (Ermittlung seit 1.18 robust gegen leere Rückgabe) |
| `HEALTH_RETRIES` | `10` | Wie oft (im 2-Sekunden-Abstand) der Health-Check nach einem Rebuild versucht wird, bevor ein Rollback ausgelöst wird |
| `HEALTH_CHECK_PATH` *(neu in 1.18)* | `"/"` | Pfad, gegen den der Health-Check läuft |
| `HEALTH_CHECK_EXPECTED_CODES` *(neu in 1.18)* | `"200 301 302 401"` | Leerzeichen-getrennte Liste akzeptierter HTTP-Statuscodes für den Health-Check |
| `CHECK_FOR_UPDATES` | `true` | Prüft bei jedem Lauf (gecacht, siehe `UPDATE_CHECK_INTERVAL_HOURS`), ob im GitHub-Repo eine andere Script-Version liegt — rein informativ, `false` deaktiviert den Check komplett |
| `UPDATE_CHECK_REPO` | `roswitina/oxicloud-install` | GitHub-Repo (`owner/repo`), gegen das die Versionsprüfung läuft |
| `UPDATE_CHECK_BRANCH` | `main` | Branch, aus dem die Referenzversion gelesen wird |
| `UPDATE_CHECK_INTERVAL_HOURS` | `24` | Mindestabstand zwischen zwei tatsächlichen GitHub-Abrufen (Cache-Datei) |
| `GITHUB_TOKEN` *(neu in 1.18)* | leer | Optionales Token, wird als `Authorization: token ...`-Header an alle GitHub-API-Aufrufe angehängt (Update-Check + `OXICLOUD_VERSION_PIN=latest`) — hebt das anonyme Rate-Limit an |

Alle `ENV_OVERRIDE_*`-Variablen greifen nur, wenn nicht leer — leer lassen
heißt: Standardwert aus `example.env` bleibt unangetastet.

Seit 1.14 stehen **alle** anpassbaren Werte gesammelt im
Konfigurationsblock am Scriptanfang, inklusive der in 1.18 und 1.20 neu
hinzugekommenen.

---

## Ablauf im Detail

1. **Preflight-Check**: `sudo`, `git`, `curl`, `jq`, `openssl`,
   `postgresql`, `postgresql-contrib`, `build-essential`, `pkg-config`,
   `libssl-dev`, `ca-certificates` werden geprüft und fehlende per `apt`
   nachinstalliert. Seit 1.13 wird außerdem, falls `logrotate` vorhanden
   ist, automatisch eine Rotation für `/var/log/oxicloud-install.log`
   eingerichtet, und bei kritisch wenig freiem Diskspace
   (< `DISK_ABORT_THRESHOLD_GB`) bricht das Script an dieser Stelle
   bereits hart ab. **Seit 1.18** folgt direkt danach die Verifizierung,
   dass `git`/`curl`/`jq`/`openssl`/`psql` tatsächlich verfügbar sind —
   vorher lief dieser Check erst kurz vor dem Build, also nach DB-Backup
   und Migration (siehe „Neuerungen in 1.18", Punkt 2). Unmittelbar danach
   läuft der Update-Check (siehe „Neuerung in 1.16"); das Ergebnis wird
   seit 1.19 in `UPDATE_AVAILABLE_VERSION` gemerkt, damit es am Ende auch
   in der Zusammenfassung wiederholt werden kann (siehe „Neuerung in
   1.19").
2. **Node.js & Rust**: werden installiert bzw. aktualisiert (oder auf die
   gepinnte Version gebracht, falls `NODE_VERSION_PIN`/`RUST_VERSION_PIN`
   gesetzt sind). Ein Versionswechsel bei einem der beiden löst automatisch
   einen Rebuild aus. Die Node.js-LTS-Ermittlung ist seit 1.11 gegen einen
   stillen Script-Abbruch bei Netzwerkproblemen abgesichert. Direkt danach
   (seit 1.18) wird zusätzlich verifiziert, dass `node`/`npm`/`cargo`
   tatsächlich verfügbar sind.
3. **Systemuser + PostgreSQL-Rolle/Datenbank**: werden angelegt, falls noch
   nicht vorhanden. `OXICLOUD_HOME` wird bei Bedarf rekursiv auf
   `oxicloud:oxicloud` zurückgesetzt (Selbstheilung, seit 1.15 nur falls
   nötig). Seit 1.11 wird das DB-Passwort zusätzlich bei **jedem** Lauf
   per `ALTER ROLE` durchgesetzt und die Verbindung direkt verifiziert.
4. **Klonen/Aktualisieren**: `git clone` bei Erstlauf (ist `OXICLOUD_HOME`
   dabei nicht-leer und noch kein Git-Repo, wird der Inhalt seit 1.18
   vorher als Tarball gesichert, siehe „Neuerungen in 1.18", Punkt 9);
   danach, sofern kein `OXICLOUD_VERSION_PIN` gesetzt ist, seit 1.13
   `git fetch` + `git reset --hard origin/main` statt `git pull origin
   main`. Lokale, nicht committete Änderungen an getrackten Dateien
   werden weiterhin vorher als Patch unter `local-changes-backup/`
   gesichert und dann verworfen.
5. **`.env` erzeugen/ergänzen**: Bei Erstlauf wird die Vorlage
   (`example.env`, `.env.example` oder `env.example`) kopiert. Bei bereits
   bestehender `.env` werden alle **fehlenden** Variablen der Vorlage
   angehängt — seit 1.21 auch die auskommentierten, optionalen, jeweils
   mit Erklärungstext (siehe „Neuerung in 1.21") — vorhandene Werte
   bleiben unverändert. `DATABASE_URL` landet seit 1.11 ebenfalls in der
   `.env` (statt im systemd-Unit-File). Werte werden seit 1.18 vor dem
   Einsetzen für `sed` escaped (siehe „Neuerungen in 1.18", Punkt 10).
   Wird `ENV_OVERRIDE_SERVER_HOST` auf `0.0.0.0`/`::` gesetzt, gibt das
   Script einen Firewall-Hinweis aus (seit 1.18 nur bei aktivem ufw
   fälschungssicher formuliert).
6. **DB-Backup + Migrationen**: Seit 1.13 läuft direkt vor der Migration
   ein `pg_dump`-Backup nach `/etc/oxicloud/db-backups`; schlägt das
   Backup fehl, wird die Migration gar nicht erst versucht. Danach läuft
   `cargo sqlx migrate run` wie bisher bei **jedem** Lauf (idempotent,
   wendet nur ausstehende Migrationen an). **Seit 1.20:** Meldet sqlx dabei
   „migration X was previously applied but has been modified" (typisch bei
   ungepinntem main-Branch, siehe „Neuerung in 1.20"), gibt das Script eine
   ausführliche Warnung samt Handlungsempfehlung aus und bricht standardmäßig
   ab; nur bei explizit gesetztem `AUTO_REPAIR_MODIFIED_MIGRATIONS=true`
   wird der betroffene Tracking-Eintrag automatisch entfernt und die
   Migration einmal automatisch wiederholt. Jeder andere Migrationsfehler
   wird weiterhin unverändert durchgereicht.
7. **Rebuild** (nur falls nötig): Frontend (`npm run build`) und Backend
   (`cargo build --release --locked`) werden neu gebaut. Steht ein
   Rebuild an und ist wenig RAM frei, legt das Script vorher **seit
   1.18 nur in diesem Fall** einen temporären Swapfile an (siehe
   „Neuerungen in 1.18", Punkt 4), der garantiert über den EXIT-Trap
   wieder entfernt wird (Punkt 5) — auch bei einem Abbruch mitten im
   Build. Die entstehende Binary wird nach ihrem Git-Commit-Hash
   versioniert unter `releases/` abgelegt; der Symlink `current` zeigt
   danach darauf.
8. **systemd**: Unit wird (neu) geschrieben (weiterhin ohne `DATABASE_URL`
   im Klartext), Dienst bei Bedarf neu gestartet.
9. **Health-Check + automatisches Rollback**: Läuft immer, wenn gerade neu
   gebaut/gestartet wurde — außer `ENV_OVERRIDE_SERVER_HOST` ist auf eine
   feste, nicht-lokale Adresse gesetzt, dann wird bewusst übersprungen.
   Der Check akzeptiert seit 1.18 konfigurierbare Pfade/Statuscodes (siehe
   „Neuerungen in 1.18", Punkt 7). Antwortet der Dienst fristgerecht,
   wird `current-good` aktualisiert (neu in 1.18, Punkt 6). Andernfalls
   wird automatisch auf `current-good` zurückgerollt, sofern es existiert.
   Bei jedem Fehlschlag des gesamten Laufs (Exit-Code ≠ 0) wird, falls
   `NOTIFY_WEBHOOK_URL` gesetzt ist, zusätzlich eine Benachrichtigung
   verschickt, inklusive Rollback-Status im Text.
10. **Zusammenfassungsblock**: URL, aktives Release, `current-good`,
    DB-Passwort und weitere Eckdaten des Laufs, seit 1.20 zusätzlich der
    Status von `AUTO_REPAIR_MODIFIED_MIGRATIONS`. **Seit 1.19** erscheint
    hier zusätzlich der Update-Hinweis aus Schritt 1 erneut, falls
    `UPDATE_AVAILABLE_VERSION` gesetzt ist (siehe „Neuerung in 1.19") —
    vorher stand er nur einmalig weiter oben im scrollenden Output.

---

## Was garantiert erhalten bleibt (idempotent über mehrere Läufe)

| Was | Mechanismus |
|---|---|
| DB-Passwort | Persistiert in `/etc/oxicloud/.db_password` (`chmod 600`), wiederverwendet statt neu generiert — bei jedem Lauf aktiv gegen die Datenbank durchgesetzt (`ALTER ROLE`), nicht nur beim Erstanlegen vorausgesetzt |
| Bestehende `.env`-Werte | Nur fehlende Variablen werden ergänzt (seit 1.21 auch auskommentierte Optionen samt Erklärung), nichts wird überschrieben; bewusst auskommentierte Variablen gelten als vorhanden |
| Lokale, nicht committete Änderungen in `OXICLOUD_HOME` | Werden vor jedem Pull/Reset als Patch unter `local-changes-backup/` gesichert (dann verworfen, da das Verzeichnis ausschließlich vom Script verwaltet werden soll) |
| `.env`, systemd-Unit, `/etc/fstab` | Vor jedem Überschreiben wird eine Zeitstempel-Kopie in einem `backups/`-Unterordner neben der jeweiligen Datei angelegt — begrenzt auf die neuesten `GENERIC_BACKUP_KEEP` Stände pro Datei |
| Nicht-leeres, noch nicht geklontes `OXICLOUD_HOME` *(neu in 1.18)* | Wird vor dem Leeren als Tarball unter `/etc/oxicloud/pre-clone-backups/` gesichert |
| Alte Releases | Über `KEEP_RELEASES` gesteuert; die aktive Version **und** `current-good` (neu in 1.18) werden nie automatisch gelöscht |
| DB-Backups | Unter `/etc/oxicloud/db-backups`, über `DB_BACKUP_KEEP` (Standard 10) gesteuert — dient seit 1.20 zusätzlich als Absicherung für `AUTO_REPAIR_MODIFIED_MIGRATIONS` |
| Zuletzt gesundes Release *(neu in 1.18)* | Symlink `current-good`, wird nur nach erfolgreichem Health-Check aktualisiert — dient als verlässliches automatisches Rollback-Ziel |
| sqlx-Migrationshistorie *(neu in 1.20)* | Wird standardmäßig (`AUTO_REPAIR_MODIFIED_MIGRATIONS=false`) nie automatisch verändert — der Checksummen-Schutz von sqlx gegen nachträglich geänderte Migrationen bleibt aktiv, bis ihr bewusst manuell (oder per Opt-in automatisiert) eingreift |

---

## Sicherheit: Datei-Rechte im Überblick

| Datei/Verzeichnis | Rechte | Enthält |
|---|---|---|
| `/etc/oxicloud/` *(seit 1.18 explizit)* | `750`, root | Verzeichnis selbst — verbirgt u. a. Dateinamen der DB-Backups vor anderen lokalen Usern |
| `/etc/oxicloud/.env` | `640`, `root:oxicloud` | `DATABASE_URL`, `OXICLOUD_DB_CONNECTION_STRING`, weitere `.env`-Werte |
| `/etc/oxicloud/.db_password` | `600`, root | DB-Passwort im Klartext |
| `/etc/oxicloud/db-backups/*.sql.gz` | `600`, root | Vollständiger Datenbank-Dump (potenziell sensible Nutzdaten) |
| `/etc/oxicloud/pre-clone-backups/*.tar.gz` *(neu in 1.18)* | Standard (root-Verzeichnis `750`) | Tarball eines evtl. vorbefüllten `OXICLOUD_HOME` vor dem ersten Klonen |
| `/etc/systemd/system/oxicloud.service` | `644` (systemd-Standard, für alle lesbar) | Seit 1.11 kein Passwort mehr — vorher enthielt es `DATABASE_URL` im Klartext |

---

## Versionierte Releases & Rollback

Jede gebaute Binary landet unter `${OXICLOUD_HOME}/releases/oxicloud-<git-hash>`.
Es gibt zwei Symlinks:

- **`current`** — zeigt immer auf die zuletzt gebaute/aktive Binary.
- **`current-good`** *(neu in 1.18)* — zeigt auf die Binary, die zuletzt
  einen Health-Check bestanden hat. Wird ausschließlich nach erfolgreichem
  Health-Check aktualisiert und dient als verlässliches automatisches
  Rollback-Ziel — im Unterschied zu vorher, wo schlicht „das zuletzt
  modifizierte andere Release" gewählt wurde, ohne Garantie, dass dieses
  selbst je funktioniert hat.

**Automatisch:** Antwortet der Dienst nach einem Rebuild nicht innerhalb
von `HEALTH_RETRIES` × 2 Sekunden mit einem der `HEALTH_CHECK_EXPECTED_CODES`
auf `http://127.0.0.1:${OXICLOUD_PORT}${HEALTH_CHECK_PATH}`, rollt das
Script selbstständig auf `current-good` zurück und startet den Dienst
damit neu. Das Script beendet sich in diesem Fall trotzdem mit Exit-Code
1, damit der Fehlschlag sichtbar bleibt (z. B. für die
Webhook-Benachrichtigung oder einen Cron-Job-Status).

**Manuell** (z. B. um gezielt auf ein älteres, nicht das direkt vorherige
Release zu wechseln):

```bash
sudo ln -sfn /opt/oxicloud/releases/oxicloud-<alter-hash> /opt/oxicloud/current
sudo systemctl restart oxicloud
```

---

## Ressourcenbedarf beim Kompilieren

`cargo build --release` mit LTO ist speicherhungrig. Das Script gibt dazu
eine Einschätzung aus (empfohlen: 4+ CPU-Kerne, 16+ GB RAM, ~20 GB freier
Speicher) und legt bei zu wenig RAM **und tatsächlich anstehendem
Rebuild** (seit 1.18, vorher bei jedem Lauf) automatisch einen 8-GB-Swapfile
an (`/swapfile`, dauerhaft in `/etc/fstab` eingetragen) — und entfernt ihn
garantiert wieder vollständig, inklusive `/etc/fstab`-Eintrag, egal ob der
Lauf erfolgreich war oder vorzeitig abgebrochen ist (seit 1.18 über einen
EXIT-Trap, siehe „Neuerungen in 1.18", Punkt 5).

Seit 1.13 gilt zusätzlich: Sinkt der freie Speicherplatz unter
`DISK_ABORT_THRESHOLD_GB` (Standard 5 GB), bricht das Script **vor** dem
Build hart ab, statt erst mitten in `cargo build` an voller Platte zu
scheitern.

Falls das automatische Swap-Verhalten nicht gewünscht ist: manuell vorab
mehr RAM bereitstellen, oder den Swapfile-Block im Script deaktivieren.

---

## Versions-Pinning

Standardmäßig läuft alles auf dem jeweils neuesten Stand:
- OxiCloud: `main`-Branch (via `git fetch` + `reset --hard origin/main`)
- Node.js: neueste LTS-Major-Version
- Rust: `rustup update stable`

Für reproduzierbare/stabile Deployments können alle drei über
`OXICLOUD_VERSION_PIN`, `NODE_VERSION_PIN`, `RUST_VERSION_PIN` festgenagelt
werden. `OXICLOUD_VERSION_PIN="latest"` löst zur Laufzeit gegen das
neueste GitHub-Release auf (seit 1.18 robust gegen Netzwerkfehler und
optional mit `GITHUB_TOKEN` gegen Rate-Limits abgesichert). Ein Wechsel
eines Pins löst automatisch einen Rebuild aus, sobald sich dadurch etwas
ändert.

**Zusätzlicher Grund, `OXICLOUD_VERSION_PIN` zu setzen (seit 1.20):** Nur
beim ungepinnten `main`-Branch kann eine bereits angewendete Migration von
Upstream nachträglich geändert werden und den in „Neuerung in 1.20"
beschriebenen sqlx-Checksummen-Mismatch auslösen. Bei einem festen
Release-Tag tritt dieser Fall praktisch nicht auf, da Upstream Migrationen
in bereits veröffentlichten Tags nicht mehr nachträglich anfasst.

---

## Logs

```bash
journalctl -u oxicloud -f          # Dienst-Logs (laufender Betrieb)
tail -f /var/log/oxicloud-install.log   # Install-/Update-Läufe des Scripts
```

Jeder Lauf des Scripts hängt zusätzlich an `/var/log/oxicloud-install.log`
an. Seit 1.13 richtet das Script (sofern `logrotate` verfügbar ist)
automatisch `/etc/logrotate.d/oxicloud-install` ein (wöchentlich, 8
Generationen, komprimiert), damit dieses Log bei wiederholten/
automatisierten Läufen nicht unbegrenzt wächst.

---

## Troubleshooting

**„Für install-oxicloud.sh liegt auf GitHub eine andere Version vor", obwohl die neue Version schon hochgeladen ist:**
Betrifft Versionen bis 1.22 (Cache des Update-Checks, siehe „Fix in 1.23").
Ab 1.23 behoben. Wer noch eine ältere Version nutzt, kann den Cache von
Hand löschen: `rm /etc/oxicloud/.update-check-install-oxicloud`.

**„Umbau der .env auf 'de' abgebrochen – diese Einstellungen wären verändert worden" (neu in 1.22):**
Die Sicherheitsprüfung hat angeschlagen; die `.env` ist unverändert, das
Script läuft normal weiter. Die genannten Variablen in der `.env` ansehen
(z. B. doppelt mit unterschiedlichen Werten oder ungewöhnlich
geschrieben), bereinigen und das Script erneut ausführen.

**„ENV_LANGUAGE=de, aber …/example.env.de fehlt" (neu in 1.22):**
Die deutsche Vorlage liegt nicht unter `ENV_TEMPLATE_DIR`. Das Script
arbeitet dann wie mit `ENV_LANGUAGE=""`. Datei nach
`/etc/oxicloud/example.env.de` kopieren und erneut ausführen.

**Nach dem Update auf 1.21 ist die `.env` viel länger (neu in 1.21):**
Gewollt. Beim ersten Lauf werden einmalig alle Variablen der Vorlage
ergänzt, die bisher fehlten — fast alle auskommentiert und damit ohne
Wirkung, jeweils mit Erklärung. Sie stehen gesammelt am Ende unter
„Automatisch ergänzt aus …". Wer zum alten Stand zurück will, findet die
vorherige Fassung unter `/etc/oxicloud/backups/`. Eine Option aktivieren:
in `/etc/oxicloud/.env` das `#` vor der Zeile entfernen, Wert anpassen,
dann `systemctl restart oxicloud`.

**„Keine Vorlage (example.env, .env.example, env.example) gefunden" (neu in 1.21):**
Im Quellcode unter `/opt/oxicloud` liegt keine Vorlage (z. B. weil
Upstream die Datei umbenannt hat). Der Lauf bricht deshalb nicht ab, die
`.env` wird nur nicht abgeglichen. Den Dateinamen im Repository
nachsehen; falls er anders lautet, in `find_env_template()` ergänzen.

**`error: migration X was previously applied but has been modified` (neu behandelt seit 1.20):**
Tritt nur auf, wenn `OXICLOUD_VERSION_PIN=""` ist (main-Branch wird
verfolgt) und Upstream eine bereits bei euch angewendete Migration
nachträglich geändert hat — kein Bug, sondern der Schutzmechanismus von
sqlx gegen unbemerkt veränderte Migrationshistorien. Das Script erkennt
den Fall jetzt und gibt eine Warnung mit der genauen Migrationsversion
sowie einer Handlungsanleitung aus. Standardmäßig
(`AUTO_REPAIR_MODIFIED_MIGRATIONS=false`) bricht der Lauf danach ab;
manuell beheben mit:
```bash
sudo -u postgres psql -d oxicloud \
  -c "DELETE FROM _sqlx_migrations WHERE version = <angezeigte Versionsnummer>;"
```
und das Script erneut ausführen — vorher aber prüfen, ob die Änderung an
der Migration tatsächlich nur ein sicherer/idempotenter Rewrite war.
Alternativ `AUTO_REPAIR_MODIFIED_MIGRATIONS=true` setzen, damit das Script
das künftig automatisch erledigt (siehe „Neuerung in 1.20" oben zu den
Voraussetzungen, unter denen das sinnvoll ist). Langfristig empfiehlt sich
in jedem Fall, `OXICLOUD_VERSION_PIN` auf einen festen Release-Tag zu
setzen, damit der Fall gar nicht erst auftritt.

**`./install-oxicloud.sh: line N: sudo: command not found` (behoben seit 1.12):**
Trat vor allem in minimalen LXC-Containern auf (z. B. offizielle
Proxmox-Debian-Templates), die `sudo` standardmäßig nicht mitbringen — im
Gegensatz zu vollwertigen VMs/Images. Seit Version 1.12 installiert der
Preflight-Check `sudo` automatisch mit, falls es fehlt. Bei einer älteren
Script-Version: `apt-get install -y sudo` manuell ausführen und das
Script erneut starten — dank Idempotenz setzt es sauber dort fort, wo es
abgebrochen war.

**`error: cannot update the lock file ... because --locked was passed` (behoben seit 1.17):**
Die eingecheckte `Cargo.lock` passt nicht mehr zur `Cargo.toml` — meist,
weil Upstream im main-Branch eine Abhängigkeit geändert/hinzugefügt hat,
ohne die Lockfile neu zu committen. Seit Version 1.17 fängt das Script
das selbst ab: erzeugt bei diesem Fehler einmalig eine neue Lockfile
(`cargo generate-lockfile`) und wiederholt den Build genau einmal. Bei
einer älteren Script-Version manuell:
`cd /opt/oxicloud && sudo -u oxicloud bash -c "source .cargo/env && cargo generate-lockfile"`,
danach das Script erneut ausführen.

**„Konnte neuestes GitHub-Release nicht ermitteln" bei `OXICLOUD_VERSION_PIN=latest` (Fehlermeldung jetzt erreichbar seit 1.18):**
Vor 1.18 hätte ein fehlschlagender GitHub-Abruf an dieser Stelle das
gesamte Script durch einen `set -e`-Fallstrick still beendet, ohne dass
diese Meldung je erschienen wäre. Seit 1.18 wird der Fehler korrekt
abgefangen und ausgegeben. Ursache meist: kein Internet, GitHub nicht
erreichbar, oder das anonyme Rate-Limit ist erreicht — in letzterem Fall
hilft, `GITHUB_TOKEN` im Konfigurationsblock zu setzen.

**Update-Hinweis erscheint zweimal im Output (kein Fehler, seit 1.19 beabsichtigt):**
Findet der Update-Check eine neuere Version, erscheint der Hinweis
inzwischen bewusst **zweimal** — einmal direkt nach dem Preflight-Check
(wie schon seit 1.16) und ein zweites Mal am Ende im Zusammenfassungsblock
(neu in 1.19, siehe „Neuerung in 1.19"). Das ist kein Duplikat-Bug, sondern
der Grund für die 1.19-Änderung: die erste Ausgabe scrollt bei einem
längeren Lauf schnell aus dem Sichtbereich, die zweite im Abschlussblock
soll sie zuverlässig sichtbar halten.

**Build bricht mit `signal: 9, SIGKILL` ab:**
Fast immer OOM (zu wenig RAM). Das Script versucht das per Auto-Swapfile
abzufangen (seit 1.18 nur, wenn tatsächlich ein Rebuild ansteht), aber
bei sehr kleinen VMs (z. B. 1–2 GB RAM) kann selbst das nicht reichen —
mehr RAM bereitstellen oder auf das Prebuilt-Tooling umsteigen (Build auf
einer stärkeren separaten Maschine).

**Script bricht mit „Nur noch ca. X GB frei ... Breche vor dem Build ab" ab:**
Kein Fehler, sondern beabsichtigt: weniger als `DISK_ABORT_THRESHOLD_GB`
(Standard 5 GB) frei unter `${OXICLOUD_HOME%/*}`. Zuerst Speicherplatz
freigeben — Kandidaten laut Fehlermeldung: alte Releases unter
`releases/` (über `KEEP_RELEASES` steuerbar), alte DB-Backups unter
`/etc/oxicloud/db-backups` (über `DB_BACKUP_KEEP` steuerbar),
`apt-get clean` — dann erneut ausführen.

**„Dienst antwortet nach 10 Versuchen (je 2s) nicht ... Rolle automatisch zurück auf zuletzt gesundes Release":**
Der Health-Check nach einem Rebuild ist fehlgeschlagen, das Script hat
automatisch auf `current-good` zurückgerollt (siehe „Versionierte
Releases & Rollback" oben). Ursache im **neuen** Release liegt meist an
einem Laufzeitfehler oder einer fehlgeschlagenen Migration — dazu die
mitausgegebenen letzten 50 Zeilen aus `journalctl -u oxicloud` prüfen,
bzw. erneut per `journalctl -u oxicloud -n 100 --no-pager` nachsehen.
Erst nach Behebung der Ursache erneut versuchen; bis dahin läuft der
Dienst stabil mit dem zurückgerollten Release weiter.

**„Kein 'current-good'-Release vorhanden ... kein Rollback-Ziel" (Meldung angepasst seit 1.18):**
Es gibt noch kein Release, das je einen Health-Check bestanden hat — z. B.
bei der Erstinstallation. In diesem Fall ist manueller Eingriff nötig,
`systemctl status oxicloud` und `journalctl -u oxicloud -n 100 --no-pager`
prüfen.

**„Überspringe automatischen Health-Check: ENV_OVERRIDE_SERVER_HOST ist auf ... gesetzt":**
Kein Fehler: `ENV_OVERRIDE_SERVER_HOST` ist auf eine feste, nicht-lokale
Adresse gesetzt (nicht leer, nicht `0.0.0.0`/`::`), der Dienst lauscht dort
also nicht auf `127.0.0.1`. Der Check würde in diesem Fall immer
fälschlich fehlschlagen, deshalb wird er bewusst übersprungen. Bitte
manuell prüfen: `systemctl status oxicloud` und ggf. `curl` direkt gegen
die konfigurierte Adresse.

**„ACHTUNG: Auch das zuletzt gesunde Release startet jetzt nicht mehr sauber. Manueller Eingriff nötig!":**
Sowohl das neue als auch das automatisch zurückgerollte `current-good`-
Release starten nicht sauber — deutet meist auf ein externes Problem hin,
das nicht am Release selbst liegt (z. B. PostgreSQL down, `.env`
fehlerhaft, Port bereits belegt). `systemctl status oxicloud` und
`journalctl -u oxicloud -n 100 --no-pager` prüfen, Ursache beheben, dann
manuell `systemctl restart oxicloud`.

**Kein DB-Backup gefunden, obwohl ein Lauf durchgelaufen ist:**
Backups landen unter `/etc/oxicloud/db-backups/${DB_NAME}-<timestamp>.sql.gz`.
Prüfen, ob genug Diskspace für `pg_dump` vorhanden war — schlägt das
Backup fehl, bricht das Script bewusst **vor** der Migration ab, es gäbe
also ohnehin keinen weitergehenden Lauf ohne Backup.

**Webhook-Benachrichtigung kommt nicht an:**
`NOTIFY_WEBHOOK_URL` muss gesetzt und vom Zielserver aus erreichbar sein
(ausgehender Zugriff, ggf. Firewall/Proxy). Die Benachrichtigung selbst
ist bewusst fehlertolerant (`curl ... || true`, 10s Timeout) und wird
niemals selbst laut fehlschlagen — im Zweifel manuell testen:
```bash
curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
  -d '{"text":"Testnachricht"}' "<eure NOTIFY_WEBHOOK_URL>"
```

**Firewall-Hinweis erscheint, obwohl ufw inaktiv ist (behoben seit 1.18):**
Vorher wurde bei `ENV_OVERRIDE_SERVER_HOST=0.0.0.0`/`::` und installiertem,
aber **inaktivem** ufw fälschlich vor einem angeblich nicht freigegebenen
Port gewarnt — inaktives ufw blockiert aber ohnehin nichts. Seit 1.18
prüft das Script zuerst den ufw-Status und gibt bei inaktivem ufw
stattdessen einen allgemeineren, korrekten Hinweis aus.

**„Ein anderer Lauf dieses Scripts ist bereits aktiv":**
`flock` auf `/var/run/oxicloud-install.lock` verhindert parallele Läufe
(z. B. zwei gleichzeitige SSH-Sessions). Prüfen, ob wirklich noch ein Lauf
aktiv ist (`ps aux | grep install-oxicloud`), sonst Lock-Datei manuell
entfernen.

**Tag/Referenz aus `OXICLOUD_VERSION_PIN` existiert nicht:**
Script bricht bewusst hart ab (`git checkout` schlägt fehl) statt
stillschweigend auf `main` zurückzufallen — Tag-Namen im Repo prüfen.

**Repo-URL unsicher:**
`DioCrafts/OxiCloud` und `AtalayaLabs/OxiCloud` sind aktuell beide aktiv
mit identischem Release-Stand. Siehe Kommentar direkt über `REPO_URL` im
Script — einmal selbst verifizieren, welcher Remote für euch verbindlich
sein soll.

**„Konnte aktuelle Node.js-Version nicht ermitteln, falle zurück auf Node 24":**
Normales, beabsichtigtes Verhalten bei Netzwerkproblemen zu nodejs.org.
Kein Handlungsbedarf, außer eine bestimmte Node-Version wird zwingend
benötigt (`NODE_VERSION_PIN` setzen).

**„Verbindung zur Datenbank ... schlägt fehl, obwohl Rolle/Datenbank/
Passwort gerade eben gesetzt wurden":**
Meist eine `pg_hba.conf`-Authentifizierungsmethode, die kein
Passwort-Login für `localhost` erlaubt (z. B. `peer` statt `md5`/
`scram-sha-256`). Prüfen:
```bash
cat /etc/postgresql/*/main/pg_hba.conf | grep -v '^#'
```
Zeile für `host ... 127.0.0.1/32 ...` bzw. `local` auf `md5` oder
`scram-sha-256` umstellen, danach `systemctl restart postgresql`.

**Möchte einen Lauf vorab testen, ohne das System zu verändern:**
`DRY_RUN=true` im Konfigurationsblock setzen (neu in 1.18) und das Script
normal ausführen — siehe Abschnitt „Aufruf" und „Neuerungen in 1.18",
Punkt 13.

---

Lizenz: **MIT**
