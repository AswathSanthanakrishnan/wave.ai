#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Wave/VoiceModels"

download() {
  mkdir -p "$(dirname "$2")"
  echo "Downloading $2..."
  curl --fail --location --retry 3 "$1" -o "$2"
}

echo "=== Fetching Picovoice Porcupine macOS arm64 assets ==="

# 1. Download dynamic library for Apple Silicon (arm64)
download "https://raw.githubusercontent.com/Picovoice/porcupine/master/lib/mac/arm64/libpv_porcupine.dylib" "libpv_porcupine.dylib"

# 2. Download base model parameters (.pv)
download "https://raw.githubusercontent.com/Picovoice/porcupine/master/lib/common/porcupine_params.pv" "porcupine_params.pv"

# 3. Download default keyword file (.ppn)
download "https://raw.githubusercontent.com/Picovoice/porcupine/master/resources/keyword_files/mac/porcupine_mac.ppn" "porcupine_mac.ppn"

echo "=== Picovoice Porcupine assets downloaded successfully to Wave/VoiceModels ==="
echo "Note: If you trained a custom 'Hey-Wave_en_mac_*.ppn' in console.picovoice.ai, place it in Wave/VoiceModels/ or configure its path in Wave menu."
