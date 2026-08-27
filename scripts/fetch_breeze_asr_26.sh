#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="download"
if [[ "${1:-}" == "--verify-only" ]]; then
  mode="verify"
  shift
fi
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--verify-only] [destination]" >&2
  exit 2
fi

target="${1:-$repo_root/ios/Resources/BreezeASR26}"
model="weiren119/Breeze-ASR-26-coreml-4bit-palette"
revision="ccce05d878df112eece85c13827a8fb16c790843"

if [[ "$mode" == "download" ]]; then
  if ! command -v hf >/dev/null 2>&1; then
    echo "Missing Hugging Face CLI. Install it with: brew install huggingface-cli" >&2
    exit 1
  fi

  hf download "$model" --revision "$revision" --local-dir "$target"
  rm -rf "$target/.cache"
fi

verify() {
  local expected="$1"
  local file="$2"
  if [[ ! -f "$target/$file" ]]; then
    echo "Missing Breeze-ASR-26 asset: $target/$file" >&2
    exit 1
  fi
  local actual
  actual="$(shasum -a 256 "$target/$file" | cut -d ' ' -f 1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $file" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

verify "8bd20627b191027dd6fad681bfb4b05876a75b6bac8004130d37d36e37cd309d" \
  "AudioEncoder.mlmodelc/weights/weight.bin"
verify "981ef43c1801d1a208058b792016a90637b905a3c314a14b0a17eb31708f0aff" \
  "TextDecoder.mlmodelc/weights/weight.bin"
verify "801024dbc7a89c677be1f8b285de3409e35f7d1786c9c8d9d0d6842ac57a1c83" \
  "MelSpectrogram.mlmodelc/weights/weight.bin"
verify "a09eba19e94cc98b5f21525169741eae3ec185ce87fe19e0a2cead149e87b9ab" \
  "config.json"
verify "7847d293b436a6d190000b643e653a9f5527cae162988253103436fda9004d3e" \
  "generation_config.json"
verify "21a4fc0483c14b87f4e0bbc177a9a357479bfa7c95aaf21ad53d71e9c5afafb9" \
  "tokenizer_config.json"
verify "50d6a919f0a0601d56a04eb583c780d18553aa388254ba3158eb6a00f13e2c1a" \
  "vocab.json"
verify "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6" \
  "merges.txt"
verify "9715fd2243b6f06a5858b5e32950d2853f73dd5bc201aafcf76f5082a2d8acd1" \
  "added_tokens.json"
verify "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd" \
  "normalizer.json"
verify "e67ae3a0aaa99abcd9f187138e12db1f65c16a14761c50ef10eef2c174a7a691" \
  "special_tokens_map.json"
verify "a6a76d28c93edb273669eb9e0b0636a2bddbb1272c3261e47b7ca6dfdbac1b8d" \
  "preprocessor_config.json"

echo "Breeze-ASR-26 Core ML assets are ready at $target"
