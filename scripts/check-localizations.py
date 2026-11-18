#!/usr/bin/env python3
"""Validate bundled localization tables without building or installing the app."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / 'Resources'
# No space flag: prose such as “+20% cost” is not a format argument.
FORMAT = re.compile(r'%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp%]')
LITERALS = (
    'Claude Code', 'Claude Desktop', 'Codex', 'ElevenLabs', 'Cohere',
    'Overheard', 'Obsidian', 'Logseq', 'Notion', 'YouTube', 'Spotify',
    'Apple Intelligence', 'Speech to Text', 'API Keys', 'elevenlabs.io',
    'brew install yt-dlp', 'yt-dlp', 'meeting-transcriber', '⌃⌥M', 'sk_…', 'Markdown',
)
# These translations correctly have the same spelling as English.
SAME_AS_ENGLISH = {
    'de': {'Nome'},
    'es': {'Errore: %@', 'Errore: ', '%lld min', '%lld s'},
    'fr': {'Notifiche', 'Trascrizione', '%@ (microfono)', '%lld min', '%lld s'},
    'pt': {'%lld min', '%lld s'},
}
TECHNICAL_KEY = 'ElevenLabs HTTP %lld: %@'



def load(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def main():
    baseline = load(RESOURCES / 'en.lproj/Localizable.strings')
    info = load(ROOT / 'Info.plist')
    permission_keys = {key for key in info if key.startswith('NS') and key.endswith('UsageDescription')}
    locales = {folder.stem: folder for folder in RESOURCES.glob('*.lproj')}
    errors = []
    if set(info['CFBundleLocalizations']) != set(locales):
        errors.append('Info.plist: CFBundleLocalizations must match the bundled .lproj folders')
    for locale, folder in sorted(locales.items()):
        table = load(folder / 'Localizable.strings')
        # Italian is the source language; its table is intentionally empty.
        if locale != 'it':
            for key in sorted(baseline.keys() - table.keys()):
                errors.append(f'{locale}: missing interface key {key!r}')
            for key in sorted(table.keys() - baseline.keys()):
                errors.append(f'{locale}: unknown interface key {key!r}')
            for key, value in table.items():
                if not value.strip():
                    errors.append(f'{locale}: empty translation for {key!r}')
                expected = FORMAT.findall(key)
                actual = FORMAT.findall(value)
                if expected != actual:
                    errors.append(f'{locale}: placeholders differ for {key!r}: {expected!r} != {actual!r}')
                reference = baseline.get(key, key)
                if locale not in ('en', 'it'):
                    if (value == reference and key != TECHNICAL_KEY
                            and key not in SAME_AS_ENGLISH.get(locale, set())):
                        errors.append(f'{locale}: untranslated English value for {key!r}')
                    for literal in LITERALS:
                        if literal in reference and literal not in value:
                            errors.append(f'{locale}: missing literal {literal!r} for {key!r}')
                    if re.search(r'ZXQ\d|QXZ', value):
                        errors.append(f'{locale}: leaked translation token for {key!r}')
                    if '(claude ' in reference and not re.search(r'\bclaude\b', value):
                        errors.append(f'{locale}: lowercase claude command missing for {key!r}')
                    if '(claude ' in reference and not re.search(r'\bcodex\b', value):
                        errors.append(f'{locale}: lowercase codex command missing for {key!r}')
                if value.count('\n') != reference.count('\n'):
                    errors.append(f'{locale}: line breaks differ for {key!r}')
                for whitespace in (str.lstrip, str.rstrip):
                    if len(value) - len(whitespace(value)) != len(reference) - len(whitespace(reference)):
                        errors.append(f'{locale}: boundary whitespace differs for {key!r}')
        # English permission prompts live in Info.plist.
        if locale != 'en':
            permissions = load(folder / 'InfoPlist.strings')
            if permissions.keys() != permission_keys:
                errors.append(f'{locale}: permission keys differ from Info.plist')
            if any(not value.strip() for value in permissions.values()):
                errors.append(f'{locale}: empty permission prompt')
        print(f'{locale}: {len(table)} interface translations checked')
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print('Localization keys, placeholders, literals, English leftovers, whitespace, and permission prompts OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
