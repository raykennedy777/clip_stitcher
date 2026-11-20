#!/bin/bash

set -euo pipefail

SAMPLES_DIR="${SAMPLES_DIR:-$HOME/clipstitcher-samples}"
OUT_DIR="${1:-$SAMPLES_DIR/corrupt_fixtures}"
MPEG2_SRC="${MPEG2_SRC:-$SAMPLES_DIR/source_mpeg2.mpg}"
H264_SRC="${H264_SRC:-$SAMPLES_DIR/source_h264.mkv}"
HEVC_SRC="${HEVC_SRC:-$SAMPLES_DIR/source_hevc.mkv}"

EXCERPT_SECONDS=90
DAMAGE_FRACTIONS="0.40 0.55 0.70"
DAMAGE_BYTES=$((256 * 1024))

mkdir -p "$OUT_DIR"
MANIFEST="$OUT_DIR/manifest.txt"
: > "$MANIFEST"

make_fixture() {
    local label="$1" src="$2" ext="$3"
    local clean="$OUT_DIR/clean_${label}.${ext}"
    local corrupt="$OUT_DIR/corrupt_${label}.${ext}"

    if [[ ! -f "$src" ]]; then
        echo "missing source for ${label}: $src" >&2
        exit 1
    fi

    echo "== ${label}: excerpting first ${EXCERPT_SECONDS}s of $(basename "$src")"
    ffmpeg -y -v error -i "$src" -t "$EXCERPT_SECONDS" \
        -map 0:v:0 -map 0:a:0 -c copy "$clean"

    cp "$clean" "$corrupt"
    local size
    size=$(stat -f%z "$corrupt")
    echo "${label}: clean=$(basename "$clean") corrupt=$(basename "$corrupt") size=${size}" >> "$MANIFEST"
    for frac in $DAMAGE_FRACTIONS; do
        local offset
        offset=$(python3 -c "print(int($size * $frac) // 4096 * 4096)")
        dd if=/dev/zero of="$corrupt" bs=4096 seek=$((offset / 4096)) \
            count=$((DAMAGE_BYTES / 4096)) conv=notrunc status=none
        echo "${label}: zeroed bytes ${offset}..$((offset + DAMAGE_BYTES)) (${frac} of file)" >> "$MANIFEST"
    done
    echo "== ${label}: done"
}

make_fixture mpeg2 "$MPEG2_SRC" mpg
make_fixture h264 "$H264_SRC" mkv
make_fixture hevc "$HEVC_SRC" mkv

echo
echo "Fixtures in $OUT_DIR:"
cat "$MANIFEST"
