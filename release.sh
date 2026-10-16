#!/bin/bash
# Pubblica una nuova versione: DMG su GitHub Releases + appcast.xml (Sparkle) nel repo.
# Uso: ./release.sh 0.2
# La chiave privata per firmare gli aggiornamenti è nel Portachiavi (Sparkle generate_keys).
set -euo pipefail
cd "$(dirname "$0")"
VER=${1:?"uso: ./release.sh <versione>, es. 0.2"}
[[ -z "$(git status --porcelain -- Sources Resources Info.plist Package.swift)" ]] || { echo "Prima fai commit delle modifiche"; exit 1; }

# versione: CFBundleVersion cresce di 1 a ogni release (Sparkle confronta questo)
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VER" -c "Set CFBundleVersion $BUILD" Info.plist

NOTARY_PROFILE=${NOTARY_PROFILE:-$(xcrun notarytool history --keychain-profile overheard >/dev/null 2>&1 && echo overheard)} ./package.sh
DMG="dist/Overheard-$VER.dmg"

# appcast: generate_appcast tiene lo storico se trova l'appcast precedente nella cartella
UP=build/updates && rm -rf "$UP" && mkdir -p "$UP"
cp "$DMG" "$UP/"
[[ -f appcast.xml ]] && cp appcast.xml "$UP/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/anonbeat1/overheard/releases/download/v$VER/" \
  --link "https://github.com/anonbeat1/overheard" "$UP"
cp "$UP/appcast.xml" appcast.xml

gh release create "v$VER" "$DMG" --title "Overheard $VER" --generate-notes
git add Info.plist appcast.xml
git commit -m "Release $VER"
git push
echo "Pubblicata $VER: chi ha l'app la riceve al prossimo controllo (o da Controlla aggiornamenti…)"
