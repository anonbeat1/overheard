#!/bin/bash
# Pubblica una nuova versione: DMG su GitHub Releases + appcast.xml (Sparkle) nel repo.
# Uso: ./release.sh 0.2
# La chiave privata per firmare gli aggiornamenti è nel Portachiavi (Sparkle generate_keys).
set -euo pipefail
cd "$(dirname "$0")"
VER=${1:?"uso: ./release.sh <versione>, es. 0.2"}
[[ -z "$(git status --porcelain -- Sources Resources Info.plist Package.swift CHANGELOG.md)" ]] || { echo "Prima fai commit delle modifiche"; exit 1; }
# note di rilascio: la sezione "## <versione>" di CHANGELOG.md (finestra di Sparkle e release su GitHub)
NOTES=$(awk -v v="## $VER" '$0 == v {on=1; next} on && /^## / {exit} on' CHANGELOG.md | sed '/./,$!d')
[[ -n "$NOTES" ]] || { echo "Manca la sezione \"## $VER\" in CHANGELOG.md"; exit 1; }

# versione: CFBundleVersion cresce di 1 a ogni release (Sparkle confronta questo)
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VER" -c "Set CFBundleVersion $BUILD" Info.plist

NOTARY_PROFILE=${NOTARY_PROFILE:-$(xcrun notarytool history --keychain-profile overheard >/dev/null 2>&1 && echo overheard)} ./package.sh
DMG="dist/Overheard-$VER.dmg"

# appcast: generate_appcast tiene lo storico se trova l'appcast precedente nella cartella
UP=build/updates && rm -rf "$UP" && mkdir -p "$UP"
cp "$DMG" "$UP/"
[[ -f appcast.xml ]] && cp appcast.xml "$UP/"
printf '%s\n' "$NOTES" > "$UP/Overheard-$VER.md"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --embed-release-notes \
  --download-url-prefix "https://github.com/anonbeat1/overheard/releases/download/v$VER/" \
  --link "https://github.com/anonbeat1/overheard" "$UP"
cp "$UP/appcast.xml" appcast.xml
# le app dalla 0.3.1 leggono getoverheard.dev/appcast.xml (docs/, GitHub Pages); quella alla radice resta per le versioni precedenti
cp appcast.xml docs/appcast.xml

gh release create "v$VER" "$DMG" --title "Overheard $VER" --notes "$NOTES"

# Homebrew (brew install --cask anonbeat1/tap/overheard): versione e sha256 del cask nel tap
TAP=build/homebrew-tap
[[ -d "$TAP/.git" ]] || gh repo clone anonbeat1/homebrew-tap "$TAP" -- -q
git -C "$TAP" pull -q
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VER\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/overheard.rb"
git -C "$TAP" commit -qam "overheard $VER" && git -C "$TAP" push -q
git add Info.plist appcast.xml docs/appcast.xml
git commit -m "Release $VER"
git push
echo "Pubblicata $VER: chi ha l'app la riceve al prossimo controllo (o da Controlla aggiornamenti…)"
