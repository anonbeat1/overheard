#!/bin/bash
# Build + installa in ~/Applications/Overheard.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Overheard.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp .build/release/Overheard "$APP/Contents/MacOS/"
# Aggiornamenti automatici (Sparkle)
mkdir -p "$APP/Contents/Frameworks" && cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
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
# Se il toolchain Metal di Xcode non c'è (capita dopo un aggiornamento: xcodebuild -downloadComponent MetalToolchain)
# riusa il trascrittore già compilato, purché i sorgenti non siano più nuovi del binario.
if ! (cd Transcriber && swift build -c release --disable-sandbox && BUILD_DIR="$PWD/.build" .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh release); then
  [[ -f "$T/meeting-transcriber" && -f "$T/mlx.metallib" && -z "$(find Transcriber/Sources Transcriber/Package.swift -newer "$T/meeting-transcriber")" ]] \
    || { echo "Build del trascrittore fallita e nessun binario valido da riusare"; exit 1; }
  echo "ATTENZIONE: build del trascrittore fallita (toolchain Metal?), riuso quello già compilato"
fi
TR="$APP/Contents/Resources/transcriber" && mkdir -p "$TR"
cp "$T/meeting-transcriber" "$T/mlx.metallib" "$TR/" && cp -R "$T"/*.bundle "$TR/"
# back-deploy di Swift per macOS < 26 (rpath @loader_path)
cp "$(xcrun --find swift | sed 's|/bin/swift$||')/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib" "$TR/" 2>/dev/null || true
for f in "$TR"/libswiftCompatibilitySpan.dylib "$TR/meeting-transcriber"; do [[ -f "$f" ]] && codesign --force --sign - "$f"; done

# Con un certificato stabile i permessi (mic, registrazione schermo) e il Portachiavi sopravvivono ai rebuild; ad-hoc no.
# Va bene anche un certificato locale autofirmato "Overheard Local Signing" (non "trusted", quindi senza -v).
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
[[ -z "$ID" ]] && security find-identity -p codesigning | grep -q '"Overheard Local Signing"' && ID="Overheard Local Signing"
# Sparkle prima dell'app, dai componenti interni verso l'esterno
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for f in "$SP"/XPCServices/*.xpc "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [[ -e "$f" ]] && codesign --force --options runtime --sign "${ID:--}" "$f"
done
if [[ -n "$ID" ]]; then
  codesign --force --sign "$ID" "$APP"
else
  # Ad-hoc: il requisito di default è il cdhash, che cambia a ogni build e invalida i permessi (registrazione schermo, mic).
  # Un requisito sul solo bundle id resta uguale tra le build.
  codesign --force --sign - -r='designated => identifier "com.anonbeat.overheard"' "$APP"
fi
# NO_INSTALL=1: solo build (es. release durante una registrazione: non sostituisce l'app in uso)
if [[ -n "${NO_INSTALL:-}" ]]; then echo "Build: $APP (firma: ${ID:-ad-hoc})"; exit 0; fi
mkdir -p ~/Applications && rm -rf ~/Applications/Overheard.app && cp -R "$APP" ~/Applications/
echo "Installata: ~/Applications/Overheard.app (firma: ${ID:-ad-hoc})"
