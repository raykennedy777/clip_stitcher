#!/bin/bash
# Manufactures corrupted test footage for the corruption-tolerant export work (issue #43).
#
# For each clean source it stream-copies a 90 s excerpt (video + first audio stream) in
# the source's own container, keeps that excerpt as the clean control fixture, then takes
# a corrupt copy and zeroes three byte ranges mid-file — what a reception dropout does to
# a broadcast stream. The excerpt starts at the file's beginning so an open-GOP source
# (the HEVC sprint) loses no leading pictures to a head cut; a tail-only cut is safe.
#
# Zeroed ranges land at fixed fractions of the file size (40 / 55 / 70 %), aligned to
# 4 KiB, 256 KiB each — deterministic, so the fixtures are reproducible from the same
# sources. The exact ranges are written to manifest.txt next to the fixtures.
#
# Usage: make_corrupt_fixtures.sh [output-dir]
#   You supply your own clean sources (no media is committed; ADR-0023). Set SAMPLES_DIR to a
#   folder holding source_mpeg2.mpg / source_h264.mkv / source_hevc.mkv, or override each path
#   individually with MPEG2_SRC / H264_SRC / HEVC_SRC.

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
        # 4 KiB-aligned offset at this fraction of the file.
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
