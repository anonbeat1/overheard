#!/bin/bash
# Crea dist/Overheard-<versione>.dmg (trascina in Applicazioni), con le istruzioni in inglese e italiano.
# Uso: ./package.sh            (ricompila con build.sh e impacchetta)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=build/dmg && rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R build/Overheard.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<'TXT'
Overheard — install

1. Drag Overheard to Applications.
2. First launch: open it, then System Settings → Privacy & Security → "Open Anyway".
   (If macOS says it is damaged, run in Terminal:
    xattr -dr com.apple.quarantine /Applications/Overheard.app )
3. Allow Microphone and System Audio Recording when asked.
4. Click the menu bar icon → gear → Settings: your name, labels,
   the ElevenLabs key (or "On this Mac"), and optionally "Connect to Claude".

Requirements: Apple Silicon Mac, macOS 14.2+ (15+ for on-device transcription).
Optional: Claude Code or Codex (summaries and chat), yt-dlp (import from links).
https://github.com/anonbeat1/overheard

────────────────────────────────────────

Overheard — installazione

1. Trascina Overheard in Applicazioni.
2. Primo avvio: aprila, poi Impostazioni di Sistema → Privacy e sicurezza → "Apri comunque".
   (Se macOS dice che è danneggiata: nel Terminale
    xattr -dr com.apple.quarantine /Applications/Overheard.app )
3. Concedi Microfono e Registrazione audio di sistema quando li chiede.
4. Clic sull'icona nella barra in alto → ingranaggio → Impostazioni:
   il tuo nome, le etichette, la chiave ElevenLabs (oppure "Sul Mac"),
   e se vuoi "Collega a Claude".

Requisiti: Mac con Apple Silicon, macOS 14.2+ (15+ per la trascrizione sul Mac).
Opzionali: Claude Code o Codex (riassunti e chat), yt-dlp (import da link).
TXT
DMG="dist/Overheard-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Overheard $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Pronto: $DMG ($(du -h "$DMG" | cut -f1))"
