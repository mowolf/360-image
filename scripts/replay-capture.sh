#!/usr/bin/env bash
# Replays an exported capture zip (from the app's "Export capture data") on a desktop.
# Usage: scripts/replay-capture.sh capture.zip [pano-replay options]
set -euo pipefail
ZIP=$(realpath "$1"); shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
unzip -q "$ZIP" -d "$WORK"
DIR=$(dirname "$(find "$WORK" -name manifest.json | head -1)")
python3 -I - "$DIR" <<'PY'
import sys, pathlib
from PIL import Image
d = pathlib.Path(sys.argv[1])
for jpg in d.glob("*.jpg"):
    Image.open(jpg).convert("RGB").save(jpg.with_suffix(".ppm"))
PY
(cd "$ROOT/Packages/PanoramaCore" && swift run -c release pano-replay "$DIR" "$@")
echo "Capture unpacked at $DIR"
