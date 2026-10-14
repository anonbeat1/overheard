#!/bin/bash
# Compila meeting-transcriber e mlx.metallib (MLX lo cerca accanto all'eseguibile), installa in ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --disable-sandbox
BUILD_DIR="$PWD/.build" .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh release
DEST=~/.local/share/meeting-transcriber
mkdir -p "$DEST" ~/.local/bin
cp .build/release/meeting-transcriber .build/release/mlx.metallib "$DEST/"
cp -R .build/release/*.bundle "$DEST/" 2>/dev/null || true
ln -sf "$DEST/meeting-transcriber" ~/.local/bin/meeting-transcriber
echo "Installato: ~/.local/bin/meeting-transcriber"
