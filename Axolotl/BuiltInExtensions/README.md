# Built-in extensions

Extensions in this folder ship inside Axolotl.app and are installed for every
profile on first launch (`ExtensionLibrary.installBuiltIns`). Users can turn
them off or remove them in Settings → Extensions; a newer bundled version
replaces an older installed one in place, keeping the extension's settings.

## uBlock Origin Lite (`uBOLite/`)

- Author: Raymond Hill (gorhill) — https://github.com/uBlockOrigin/uBOL-home
- Version: 2026.1012.1545 (Safari build, `uBOLite_2026.1012.1545.safari.zip`)
- SHA-256 of the release zip: ac0ba2e1a4e286dea5ecbfa0232ad8077d24d39d4d0598d353f4cdfb31a8416e
- License: GPL-3.0 (see `uBOLite/LICENSE.txt`). It is bundled unmodified as a
  separate program; Axolotl's own code remains MIT-licensed.

To update: download the latest `*.safari.zip` from the uBOL-home releases,
replace the contents of `uBOLite/`, and update the version and checksum above.
