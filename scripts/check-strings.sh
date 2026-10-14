#!/bin/bash
# Controlla che ogni stringa dell'interfaccia (chiave italiana nel codice) abbia la traduzione in Resources/en.lproj.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
swift build -c release -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null 2>&1 \
  || { echo "build fallita: swift build -c release"; exit 1; }
plutil -convert json -o "$OUT/en.json" Resources/en.lproj/Localizable.strings
python3 -I - "$OUT" "$OUT/en.json" <<'PY'
import sys, glob, json
keys = {e["key"] for f in glob.glob(sys.argv[1] + "/*.stringsdata")
        for t in json.load(open(f)).get("tables", {}).values() for e in t}
table = json.load(open(sys.argv[2]))
# senza traduzione perché uguali in ogni lingua: nomi propri, simboli, formati
same = {k for k in keys if not any(c.isalpha() for c in k.replace("%lld", "").replace("%@", ""))}
same |= {"Claude", "Codex", "ElevenLabs", "Google Meet", "Microsoft Teams", "Slack", "Stop", "Transcript", "Meeting", "https://…", "sk_…", "⌃⌥M"}
missing = sorted(k for k in keys - same if k.strip() and k not in table)
unused = sorted(k for k in table if k not in keys)
for k in missing: print("manca:", json.dumps(k, ensure_ascii=False))
for k in unused: print("non usata:", json.dumps(k, ensure_ascii=False))
sys.exit(1 if missing else 0)
PY
echo "Stringhe OK"
