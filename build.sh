#!/bin/bash
# Build + installa in ~/Applications/Overheard.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Overheard.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp .build/release/Overheard "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp -R Resources/* "$APP/Contents/Resources/"
# Icona app da Resources/AppIcon.png (1024x1024), se presente
if [[ -f Resources/AppIcon.png ]]; then
  SET=build/AppIcon.iconset && rm -rf "$SET" && mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
# Trascrizione sul Mac (Cohere): meeting-transcriber + mlx.metallib + risorse SwiftPM dentro l'app.
# I modelli (~2,5 GB) non sono inclusi: l'app li scarica quando si sceglie "Sul Mac" nelle Impostazioni.
T=Transcriber/.build/release
(cd Transcriber && swift build -c release --disable-sandbox && BUILD_DIR="$PWD/.build" .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh release)
TR="$APP/Contents/Resources/transcriber" && mkdir -p "$TR"
cp "$T/meeting-transcriber" "$T/mlx.metallib" "$TR/" && cp -R "$T"/*.bundle "$TR/"
# back-deploy di Swift per macOS < 26 (rpath @loader_path)
cp "$(xcrun --find swift | sed 's|/bin/swift$||')/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib" "$TR/" 2>/dev/null || true
for f in "$TR"/libswiftCompatibilitySpan.dylib "$TR/meeting-transcriber"; do [[ -f "$f" ]] && codesign --force --sign - "$f"; done

# Con un certificato Apple Development i permessi (mic, registrazione schermo) sopravvivono ai rebuild; ad-hoc no.
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
if [[ -n "$ID" ]]; then
  codesign --force --sign "$ID" "$APP"
else
  # Ad-hoc: il requisito di default è il cdhash, che cambia a ogni build e invalida i permessi (registrazione schermo, mic).
  # Un requisito sul solo bundle id resta uguale tra le build.
  codesign --force --sign - -r='designated => identifier "com.anonbeat.overheard"' "$APP"
fi
mkdir -p ~/Applications && rm -rf ~/Applications/Overheard.app && cp -R "$APP" ~/Applications/
echo "Installata: ~/Applications/Overheard.app (firma: ${ID:-ad-hoc})"
