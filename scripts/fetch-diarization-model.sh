#!/usr/bin/env bash
# Fetches the streaming Sortformer diarization model (FluidInference, Apache-2.0)
# into ios/Resources/Diarization/ so it ships inside the app bundle.
#
# Source: https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml
# Pinned to the v3 fp16 combined-pipeline build used by FluidAudio 0.15.5.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/ios/Resources/Diarization/Sortformer_v2.1.mlmodelc"
BASE="https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml/resolve/main/v3/fp16/Sortformer_v2.1.mlmodelc"

FILES=(
  "analytics/coremldata.bin"
  "coremldata.bin"
  "model0/analytics/coremldata.bin"
  "model0/coremldata.bin"
  "model0/model.mil"
  "model0/weights/0-weight.bin"
  "model1/analytics/coremldata.bin"
  "model1/coremldata.bin"
  "model1/model.mil"
  "model1/weights/1-weight.bin"
)

if [[ -f "$DEST/model1/weights/1-weight.bin" ]]; then
  echo "Sortformer_v2.1.mlmodelc already present at $DEST"
  exit 0
fi

mkdir -p "$DEST"/{analytics,model0/{analytics,weights},model1/{analytics,weights}}
for f in "${FILES[@]}"; do
  echo "Fetching $f"
  curl -sfL "$BASE/$f" -o "$DEST/$f"
done

echo "Done: $(du -sh "$DEST" | cut -f1) at $DEST"
