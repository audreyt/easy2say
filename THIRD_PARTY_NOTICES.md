# Third-party notices

## Silero VAD

This repository includes a converted model derived from [Silero VAD](https://github.com/snakers4/silero-vad) by the Silero Team and contributors.

- Pinned upstream commit: [`806dcba3f0b5d95282d0889a074954a2f8c6397b`](https://github.com/snakers4/silero-vad/tree/806dcba3f0b5d95282d0889a074954a2f8c6397b)
- Pinned upstream model: [`src/silero_vad/data/silero_vad.jit`](https://github.com/snakers4/silero-vad/blob/806dcba3f0b5d95282d0889a074954a2f8c6397b/src/silero_vad/data/silero_vad.jit)
- License: [MIT](LICENSES/Silero-VAD.txt) ([upstream source](https://github.com/snakers4/silero-vad/blob/806dcba3f0b5d95282d0889a074954a2f8c6397b/LICENSE))

`Sources/V2SApp/Resources/SileroVAD.mlpackage` is a Core ML conversion of the pinned 16 kHz Silero VAD model for on-device voice activity detection. The conversion preserves the original model weights and math. It can be reproduced with [`scripts/convert_silero_vad_coreml.py`](scripts/convert_silero_vad_coreml.py).

## Breeze-ASR-26 / BreezeASR-Taigi

The iOS and macOS builds can include a 4-bit Core ML conversion of [MediaTek Research's Breeze-ASR-26](https://huggingface.co/MediaTek-Research/Breeze-ASR-26), a Whisper-large-v2-derived model for Taiwanese Hokkien speech.

- Converted model: [`weiren119/Breeze-ASR-26-coreml-4bit-palette`](https://huggingface.co/weiren119/Breeze-ASR-26-coreml-4bit-palette/tree/ccce05d878df112eece85c13827a8fb16c790843)
- Pinned converted-model revision: `ccce05d878df112eece85c13827a8fb16c790843`
- Base model: [`MediaTek-Research/Breeze-ASR-26`](https://huggingface.co/MediaTek-Research/Breeze-ASR-26)
- License declared by both model cards: [Apache-2.0](LICENSES/Breeze-ASR-26.txt)
- Local asset size: about 890 MB; the three weight files are verified by SHA-256 in [`scripts/fetch_breeze_asr_26.sh`](scripts/fetch_breeze_asr_26.sh)
- `BreezeASR26Tokenizer.json` was generated locally with Transformers 5.12.1 from the pinned model's vocabulary, merges, added tokens, and tokenizer configuration; SHA-256: `7b469ff15eb7816315aa45eec391f5943d639b9d73d110f5c003df5192fd54e3`

Breeze-ASR-26 intentionally maps Taigi speech to Mandarin Chinese-character transcriptions rather than native Taibun orthography. The app labels this explicitly as `台語（華文轉寫）`; it must not be described as native Taibun recognition.

## WhisperKit

Taigi decoding uses [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) version 1.1.0 by Argmax, Inc. WhisperKit loads the bundled Core ML encoder, decoder, mel-spectrogram model, and tokenizer without downloading models at runtime.

- License: [MIT](LICENSES/WhisperKit.txt)

## FluidAudio / Sortformer diarization

Live speaker labels use [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.5 by Fluid Inference, which wraps NVIDIA's streaming Sortformer v2.1 diarizer.

- FluidAudio license: [Apache-2.0](LICENSES/FluidAudio.txt)
- Bundled model: `ios/Resources/Diarization/Sortformer_v2.1.mlmodelc`, the fp16 combined-pipeline Core ML build from [`FluidInference/diar-streaming-sortformer-coreml`](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml) (`v3/fp16`, CC-BY-4.0), fetched by [`scripts/fetch-diarization-model.sh`](scripts/fetch-diarization-model.sh). Downloaded weights are excluded from this repository.
- Upstream model: [`nvidia/diar_streaming_sortformer_4spk-v2.1`](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1), governed by the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/).

## OpenCC Taiwan phrases

[`Sources/V2SApp/Resources/TWPhrases.txt`](Sources/V2SApp/Resources/TWPhrases.txt) is derived from OpenCC's Taiwan phrase dictionary at commit [`7e7f746d5c870a122339e43696a7974c91e567bf`](https://github.com/BYVoid/OpenCC/blob/7e7f746d5c870a122339e43696a7974c91e567bf/data/dictionary/TWPhrases.txt).

- License: [Apache-2.0](LICENSES/OpenCC.txt)

The app applies ICU's native Hans→Hant transform first, then longest-match Taiwan phrase replacement. This supplies Taiwan terms such as `軟體`, `記憶體`, and `螢幕` without bundling OpenCC's full 1 MB dictionary set.
