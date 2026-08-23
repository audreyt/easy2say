#!/usr/bin/env bash
set -euo pipefail

# Internal evaluation only. Monlam granted access to this private checkpoint for
# local testing; this script never uploads or redistributes the source or converted
# weights. Run it only if your Hugging Face account has the corresponding access.
MODEL_REPO="MonlamAI/monlam-whisper-large-v3-turbo-v1.0"
MODEL_REVISION="06a44b447a0bba9a9ecf86d25dc31f5a36230141"
WHISPERKITTOOLS_REVISION="84f77a83c8f530022ae55fbb1a64b3351ef63c7a"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$ROOT_DIR/macOS/Resources/MonlamWhisperTibetan"

if [[ "${MONLAM_INTERNAL_USE_AUTHORIZED:-}" != "1" ]]; then
    printf '%s\n' \
        "Refusing to fetch private Monlam weights without explicit authorization." \
        "Set MONLAM_INTERNAL_USE_AUTHORIZED=1 only for Monlam-authorized internal testing." >&2
    exit 2
fi

for tool in git hf uv ditto; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing required tool: %s\n' "$tool" >&2
        exit 1
    fi
done

hf auth whoami >/dev/null
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/v2s-monlam.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

git clone --quiet --filter=blob:none \
    https://github.com/argmaxinc/whisperkittools.git \
    "$WORK_DIR/whisperkittools"
git -C "$WORK_DIR/whisperkittools" checkout --quiet --detach \
    "$WHISPERKITTOOLS_REVISION"

hf download "$MODEL_REPO" \
    --revision "$MODEL_REVISION" \
    --local-dir "$WORK_DIR/model" >/dev/null

uv venv --quiet --python 3.11 "$WORK_DIR/.venv"
uv pip install --quiet \
    --python "$WORK_DIR/.venv/bin/python" \
    -e "$WORK_DIR/whisperkittools"

(
    cd "$WORK_DIR"
    "$WORK_DIR/.venv/bin/whisperkit-generate-model" \
        --model-version model \
        --output-dir "$WORK_DIR/generated" \
        --text-decoder-max-sequence-length 224 \
        --disable-default-tests
)

CONVERTED_MODEL="$WORK_DIR/generated/model"
if [[ ! -d "$CONVERTED_MODEL" ]]; then
    printf 'Converted model folder was not produced\n' >&2
    exit 1
fi

for component in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc; do
    if [[ ! -d "$CONVERTED_MODEL/$component" ]]; then
        printf 'Converted model is missing %s\n' "$component" >&2
        exit 1
    fi
done
for metadata in config.json generation_config.json tokenizer.json tokenizer_config.json; do
    if [[ ! -f "$WORK_DIR/model/$metadata" ]]; then
        printf 'Private checkpoint is missing %s\n' "$metadata" >&2
        exit 1
    fi
done

STAGING="$WORK_DIR/MonlamWhisperTibetan"
ditto "$CONVERTED_MODEL" "$STAGING"
for metadata in config.json generation_config.json tokenizer.json tokenizer_config.json processor_config.json; do
    if [[ -f "$WORK_DIR/model/$metadata" ]]; then
        ditto "$WORK_DIR/model/$metadata" "$STAGING/$metadata"
    fi
done
if [[ -f "$WORK_DIR/model/processor_config.json" ]]; then
    ditto \
        "$WORK_DIR/model/processor_config.json" \
        "$STAGING/preprocessor_config.json"
fi

rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
ditto "$STAGING" "$DESTINATION"
printf 'Prepared private local Tibetan ASR at %s\n' "$DESTINATION"
