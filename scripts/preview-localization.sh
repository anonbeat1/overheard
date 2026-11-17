#!/bin/bash
# Build and launch the interface for visual localization review.
# Usage: bash scripts/preview-localization.sh [es|fr|de|pt|zh-Hans|hi|ar|ja|ru|bn|en|it]
# This preview has its own preferences and does not bundle the local transcriber.
set -euo pipefail
cd "$(dirname "$0")/.."
LANGUAGE_CODE="${1:-es}"
case "$LANGUAGE_CODE" in
  es|fr|de|pt|zh-Hans|hi|ar|ja|ru|bn|en|it) ;;
  *) echo "Unsupported language: $LANGUAGE_CODE" >&2; exit 1 ;;
esac
swift build -c release
APP="$PWD/build/Overheard Local.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/Overheard "$APP/Contents/MacOS/"
cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
cp -R Resources/. "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.anonbeat.overheard.localization-preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Overheard Local' "$APP/Contents/Info.plist"
# Do not register the production app's URL scheme from this preview.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
# Quit this preview before switching languages. Arguments affect this launch only.
open -n "$APP" --args -AppleLanguages "($LANGUAGE_CODE)" \
  -autoDetect NO -retentionDays 0 -dock.visible YES \
  -SUEnableAutomaticChecks NO -onboarding.done NO -engine elevenlabs
printf 'Opened %s (language: %s)\n' "$APP" "$LANGUAGE_CODE"
