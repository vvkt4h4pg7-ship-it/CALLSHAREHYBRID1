#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AMR_ROOT="$ROOT/J7Bridge/OpenCoreAMR/opencore-amr-master"
MANIFEST="$ROOT/Scripts/amr_sources.txt"
OUT_DIR="$ROOT/build/opencore-amrnb"
OBJ_DIR="$OUT_DIR/obj"
LIB="$OUT_DIR/libopencore-amrnb.a"

rm -rf "$OUT_DIR"
mkdir -p "$OBJ_DIR"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
AR="$(xcrun --sdk iphoneos -f ar)"
RANLIB="$(xcrun --sdk iphoneos -f ranlib)"

INCLUDES=(
  "-I$AMR_ROOT/oscl"
  "-I$AMR_ROOT/amrnb"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/common/dec/include"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/amr_nb/common/include"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/amr_nb/dec/include"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/amr_nb/enc/include"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/amr_nb/common/src"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/amr_nb/dec/src"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/amr_nb/enc/src"
  "-I$AMR_ROOT/opencore/codecs_v2/audio/gsm_amr/common/dec/include"
)

CXXFLAGS=(
  -arch arm64
  -isysroot "$SDK"
  -miphoneos-version-min=16.0
  -std=gnu++14
  -O2
  -fPIC
  -Wno-unused-parameter
  -Wno-unused-variable
  -Wno-deprecated-register
)

objects=()
index=0

while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  src="$AMR_ROOT/$rel"
  index=$((index + 1))
  safe_name="${rel//\//__}"
  obj="$OBJ_DIR/${safe_name%.cpp}.o"

  echo "[AMR] $index/150 $rel"
  "$CXX" "${CXXFLAGS[@]}" "${INCLUDES[@]}" -c "$src" -o "$obj"
  objects+=("$obj")
done < "$MANIFEST"

echo "[AMR] Archiving ${#objects[@]} objects"
"$AR" -rcs "$LIB" "${objects[@]}"
"$RANLIB" "$LIB"

echo "[AMR] Verifying exported wrapper symbols"
nm -g "$LIB" | grep -E 'Encoder_Interface_(init|exit|Encode)|Decoder_Interface_(init|exit|Decode)' >/dev/null

echo "[AMR] READY: $LIB"
