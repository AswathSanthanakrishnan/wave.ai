#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Wave/VoiceModels"
download() {
  mkdir -p "$(dirname "$2")"
  curl --fail --location --retry 3 "$1" -o "$2"
}
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/analytics/coremldata.bin" "AudioEncoder.mlmodelc/analytics/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/coremldata.bin" "AudioEncoder.mlmodelc/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/metadata.json" "AudioEncoder.mlmodelc/metadata.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/model.mil" "AudioEncoder.mlmodelc/model.mil"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/model.mlmodel" "AudioEncoder.mlmodelc/model.mlmodel"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/weights/weight.bin" "AudioEncoder.mlmodelc/weights/weight.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/analytics/coremldata.bin" "MelSpectrogram.mlmodelc/analytics/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/coremldata.bin" "MelSpectrogram.mlmodelc/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/metadata.json" "MelSpectrogram.mlmodelc/metadata.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/model.mil" "MelSpectrogram.mlmodelc/model.mil"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/weights/weight.bin" "MelSpectrogram.mlmodelc/weights/weight.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/analytics/coremldata.bin" "TextDecoder.mlmodelc/analytics/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/coremldata.bin" "TextDecoder.mlmodelc/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/metadata.json" "TextDecoder.mlmodelc/metadata.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/model.mil" "TextDecoder.mlmodelc/model.mil"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/model.mlmodel" "TextDecoder.mlmodelc/model.mlmodel"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/weights/weight.bin" "TextDecoder.mlmodelc/weights/weight.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/config.json" "config.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/generation_config.json" "generation_config.json"
download "https://huggingface.co/openai/whisper-base.en/resolve/911407f4214e0e1d82085af863093ec0b66f9cd6/tokenizer.json" "tokenizer.json"
download "https://huggingface.co/openai/whisper-base.en/resolve/911407f4214e0e1d82085af863093ec0b66f9cd6/tokenizer_config.json" "tokenizer_config.json"
shasum -a 256 -c ../../Scripts/voice-model.sha256
