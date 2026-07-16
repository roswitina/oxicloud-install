Aufruf dann von überall:
bash~/oxicloud-tooling/build-package.sh ~/src/OxiCloud
# oder mit fester Version und eigenem Ausgabeort:
~/oxicloud-tooling/build-package.sh ~/src/OxiCloud v0.8.1 /srv/oxicloud-packages
Das Script prüft jetzt auch defensiv: bricht ab, wenn im angegebenen Quellordner keine Cargo.toml liegt (falscher Pfad erwischt), und bricht ab, wenn install.sh/update.sh nicht direkt neben ihm liegen (falls du sie versehentlich woanders hinlegst). install.sh und update.sh selbst bleiben unverändert — die waren ja bereits self-locating über BASH_SOURCE[0], nur build-package.sh musste das nachziehen.
Kleine Sache am Rande: Ich habe die Versionsnummer auf 2.0 gesetzt (nicht 1.2), weil sich die Aufrufsyntax geändert hat (./build-package.sh <source-dir> statt ./build-package.sh im Repo-Root) — ein Breaking Change für alles, was das Script bisher automatisiert aufruft.
