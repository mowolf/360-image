#!/usr/bin/env bash
# Downloads Apple's Core ML build of Depth Anything V2 (Small, FP16, Apache-2.0) into
# Models/ at a pinned revision and verifies checksums. Run before `xcodegen generate`.
set -euo pipefail
cd "$(dirname "$0")/.."

REV=cfef6f6f2a70783dedc0bfae40cecbc2052285d3
BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/$REV/DepthAnythingV2SmallF16.mlpackage"
DEST=Models/DepthAnythingV2SmallF16.mlpackage

files=(
  "Manifest.json 2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"
  "Data/com.apple.CoreML/model.mlmodel 44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"
  "Data/com.apple.CoreML/weights/weight.bin fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"
)

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

for entry in "${files[@]}"; do
  path=${entry% *}; want=${entry#* }
  out="$DEST/$path"
  if [ -f "$out" ] && [ "$(sha "$out")" = "$want" ]; then continue; fi
  mkdir -p "$(dirname "$out")"
  curl -fsSL --retry 4 -o "$out" "$BASE/$path"
  got=$(sha "$out")
  if [ "$got" != "$want" ]; then echo "Checksum mismatch for $path: $got" >&2; exit 1; fi
done
echo "Depth model ready at $DEST"
