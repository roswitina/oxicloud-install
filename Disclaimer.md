# Disclaimer / Haftungsausschluss

**English version below / englische Fassung weiter unten.**

## Deutsch

Dieses Repository und alle darin enthaltenen Skripte, Dokumentationen und
sonstigen Inhalte ("die Software") werden unter der [MIT-Lizenz](LICENSE)
kostenlos zur Verfügung gestellt. Dieser Disclaimer ergänzt die MIT-Lizenz
um zusätzliche, in Klartext formulierte Hinweise – er ersetzt sie nicht und
schränkt sie nicht ein.

### 1. Keine Gewährleistung, keine Garantie

Die Software wird **"wie sie ist" ("as is")** bereitgestellt, ohne
Gewährleistung oder Garantie jedweder Art – weder ausdrücklich noch
stillschweigend. Das umfasst insbesondere, aber nicht ausschließlich:

- Richtigkeit, Vollständigkeit oder Aktualität der Inhalte
- Fehlerfreiheit oder Eignung für einen bestimmten Zweck
- Kompatibilität mit bestimmten Systemen, Software-Versionen oder Umgebungen
- Sicherheit im Sinne von Informationssicherheit/IT-Security

Die Software wird **unentgeltlich** überlassen. Gewährleistungsansprüche
nach §§ 922 ff ABGB setzen einen entgeltlichen Vertrag voraus und kommen
bei unentgeltlicher Überlassung von vornherein grundsätzlich nicht in
Betracht.

### 2. Haftungsausschluss

Soweit gesetzlich zulässig, wird jegliche Haftung – gleich aus welchem
Rechtsgrund (Vertrag, Verschulden bei Vertragsabschluss, unerlaubte
Handlung oder sonstige Anspruchsgrundlagen) – für Schäden jeder Art
ausgeschlossen, die aus der Nutzung, Nichtnutzung oder fehlerhaften Nutzung
der Software entstehen. Das umfasst insbesondere:

- Datenverlust oder Datenbeschädigung (z.B. durch Skripte, die Datenbanken
  leeren/neu anlegen, Dateisysteme überschreiben oder Systemkonfigurationen
  verändern)
- Ausfallzeiten oder Betriebsunterbrechungen
- Sicherheitsvorfälle, die durch Verwendung, Fehlkonfiguration oder
  Anpassung der Software entstehen
- mittelbare Schäden, Folgeschäden oder entgangenen Gewinn

**Ausgenommen von diesem Haftungsausschluss** sind Schäden, die auf
**Vorsatz oder grober Fahrlässigkeit** beruhen – ein Ausschluss der
Haftung dafür ist nach österreichischem Recht (u.a. § 6 Abs 1 Z 9 KSchG,
allgemein auch über § 879 ABGB) nicht wirksam möglich und wird hiermit
auch nicht beansprucht. Ebenso unberührt bleibt eine allfällige, gesetzlich
zwingende Haftung nach dem Produkthaftungsgesetz (PHG), soweit dessen
Anwendungsbereich im Einzelfall eröffnet ist.

### 3. Besonderer Hinweis zu destruktiven Operationen

Ein Teil der in diesem Repository enthaltenen Skripte führt **destruktive,
potenziell nicht umkehrbare Operationen** aus, unter anderem:

- Löschen/Neuanlegen von Datenbanken
- Überschreiben von Konfigurationsdateien und Datenverzeichnissen
- Verteilen von SSH-Schlüsseln und Ändern von Zugriffsberechtigungen
- Eingriffe in System- und Netzwerkkonfiguration

**Vor jedem Einsatz in einer Produktivumgebung** wird ausdrücklich
empfohlen:

- die Skripte zuerst in einer isolierten Test-/Staging-Umgebung
  auszuprobieren,
- vor der Ausführung ein aktuelles, verifiziertes Backup der betroffenen
  Systeme/Daten anzulegen,
- den Quellcode vor der Ausführung selbst zu prüfen bzw. prüfen zu lassen,
  insbesondere wenn Skripte mit erhöhten Rechten (root/sudo) oder auf
  produktiven Systemen ausgeführt werden sollen.

Die Verantwortung für die konkrete Prüfung, Anpassung und den Einsatz der
Software im jeweiligen Kontext liegt vollständig bei der nutzenden Person.

### 4. Kein Support, keine Wartungszusage

Es besteht keine Verpflichtung zu Support, Wartung, Fehlerbehebung,
Weiterentwicklung oder Beantwortung von Anfragen (z.B. über Issues oder
Pull Requests). Beiträge und Rückmeldungen sind willkommen, begründen aber
keinen Anspruch auf Bearbeitung in einem bestimmten Zeitraum oder
überhaupt.

### 5. Keine Rechtsberatung

Dieses Dokument stellt selbst keine Rechtsberatung dar und wurde ohne
anwaltliche Prüfung erstellt. Bei konkreten rechtlichen Fragen zur Nutzung,
Weitergabe oder Lizenzierung der Software wird empfohlen, fachkundigen Rat
einzuholen.

### 6. Verhältnis zur MIT-Lizenz

Im Fall eines Widerspruchs zwischen diesem Disclaimer und dem englischen
Lizenztext in [`LICENSE`](LICENSE) geht der Lizenztext vor, soweit der
Widerspruch die unter der MIT-Lizenz eingeräumten Rechte (Nutzung, Kopie,
Modifikation, Weitergabe) betrifft. Dieser Disclaimer dient der Klarstellung
und Ergänzung der bereits in der MIT-Lizenz enthaltenen
Gewährleistungs- und Haftungsausschlüsse, nicht deren Einschränkung.

---

## English

This repository and all scripts, documentation, and other content within
it ("the Software") are made available free of charge under the
[MIT License](LICENSE). This disclaimer supplements the MIT License with
additional plain-language notes; it does not replace or restrict it.

### 1. No Warranty

The Software is provided **"AS IS"**, without warranty of any kind, express
or implied, including but not limited to accuracy, completeness,
merchantability, fitness for a particular purpose, or security.

### 2. Limitation of Liability

To the maximum extent permitted by applicable law, all liability for any
damages arising from the use, inability to use, or improper use of the
Software is excluded, including data loss, downtime, security incidents,
and consequential damages. This exclusion does **not** apply to damages
caused by intent or gross negligence, to the extent such an exclusion would
be invalid under applicable mandatory law (e.g., Austrian law).

### 3. Destructive Operations

Some scripts in this repository perform destructive, potentially
irreversible operations (dropping/recreating databases, overwriting
configuration and data directories, distributing SSH keys, modifying
system/network configuration). Test in an isolated environment, take
verified backups, and review the source code before running any script
against production systems or with elevated privileges.

### 4. No Support Obligation

There is no obligation to provide support, maintenance, bug fixes, or
responses to issues/pull requests.

### 5. Not Legal Advice

This document is not legal advice and was not reviewed by a lawyer. Seek
qualified legal counsel for specific questions regarding use, distribution,
or licensing of the Software.

### 6. Relationship to the MIT License

In case of conflict between this disclaimer and the license text in
[`LICENSE`](LICENSE) regarding the rights granted (use, copy, modification,
distribution), the license text prevails. This disclaimer clarifies and
supplements — but does not narrow — the warranty and liability disclaimers
already contained in the MIT License.
