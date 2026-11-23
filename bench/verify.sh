#!/bin/bash
# Local verification for a built app and a benchmark clip.
#
# Checks both decoders decode the full clip, the audio track is decoded, and
# the two decoders agree on sampled frames. Writes a report to stdout.
#
# usage:
#   APP=/path/to/mpv.app/Contents/MacOS/mpv \
#   MEDIA=/path/to/clip.mxf \
#   bench/verify.sh
#
# Environment:
#   APP       patched player (required)
#   MEDIA     clip with a JPEG 2000 video track (required)
#   FFMPEG    ffmpeg used to hash and compare extracted frames, default ffmpeg
#   FRAMES    video frames to decode, default 240
#   THREADS   decoder threads, default 8
#   WORKDIR   scratch directory, default mktemp -d
set -euo pipefail

app=${APP:?set APP to the patched mpv binary}
media=${MEDIA:?set MEDIA to the benchmark clip}
ffmpeg=${FFMPEG:-ffmpeg}
frames=${FRAMES:-240}
threads=${THREADS:-8}
work=${WORKDIR:-$(mktemp -d)}
keep=${KEEP:-0}

cleanup() {
    [[ "$keep" == 1 ]] || rm -rf "$work"
}
trap cleanup EXIT

[[ -x "$app" ]] || { echo "not executable: $app" >&2; exit 2; }
[[ -f "$media" ]] || { echo "not a file: $media" >&2; exit 2; }
mkdir -p "$work/frames"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== player"
"$app" --no-config --version | sed -n '1,4p'

echo
echo "== decoder list"
"$app" --no-config --vd=help > "$work/vd_help.txt"
grep -qw jpeg2000 "$work/vd_help.txt" || fail "native jpeg2000 missing"
grep -qw libj2k "$work/vd_help.txt" || fail "libj2k missing"
echo "native jpeg2000: present"
echo "libj2k:          present"

echo
echo "== full decode, $frames frames, $threads threads"
for dec in jpeg2000 libj2k; do
    start=$(date +%s)
    "$app" --no-config --no-audio --vd="$dec" \
        --vd-lavc-threads="$threads" --vo=null --ao=null --untimed \
        --frames="$frames" --really-quiet "$media" \
        || fail "$dec did not decode $frames frames"
    elapsed=$(( $(date +%s) - start ))
    echo "$dec: $frames frames, exit 0, ${elapsed}s"
done

echo
echo "== audio decode"
"$app" --no-config --vd=jpeg2000 --aid=1 --vd-lavc-threads="$threads" \
    --vo=null --ao=null --untimed --frames="$frames" \
    --msg-level=all=info "$media" > "$work/audio.log" 2>&1 \
    || fail "audio decode failed"
grep -q 'Audio.*pcm' "$work/audio.log" || fail "no PCM audio track in log"
grep -q 'AO: \[null\]' "$work/audio.log" || fail "audio output did not open"
grep -q 'Audio device underrun' "$work/audio.log" \
    && fail "audio underrun while decoding to null output"
echo "PCM audio track decoded, no underruns"

echo
echo "== sampled frame agreement"
if ! command -v "$ffmpeg" >/dev/null 2>&1; then
    echo "skip: $ffmpeg not found"
    exit 0
fi

times=(0 2.5 5 7.5 9.958333)
for dec in jpeg2000 libj2k; do
    for t in "${times[@]}"; do
        out="$work/frames/$dec-$t"
        mkdir -p "$out"
        "$app" --no-config --no-audio --vd="$dec" \
            --vd-lavc-threads="$threads" --vo=image --vo-image-format=png \
            --vo-image-outdir="$out" --frames=1 --start="$t" --untimed \
            --really-quiet "$media" >/dev/null 2>&1 \
            || fail "$dec failed at $t s"
        png=$(find "$out" -name '*.png' -print -quit)
        [[ -n "$png" ]] || fail "$dec wrote no frame at $t s"
        "$ffmpeg" -v error -i "$png" -f rawvideo -pix_fmt rgb24 - \
            | shasum -a 256 | cut -d' ' -f1 > "$work/frames/$dec-$t.hash"
        if ! "$ffmpeg" -v error -i "$png" -frames:v 1 -f null - 2>/dev/null; then
            fail "$dec frame at $t s is not decodable"
        fi
    done
done

equal=0
worse=1000
for t in "${times[@]}"; do
    a="$work/frames/jpeg2000-$t/$(basename "$(find "$work/frames/jpeg2000-$t" -name '*.png' -print -quit)")"
    b="$work/frames/libj2k-$t/$(basename "$(find "$work/frames/libj2k-$t" -name '*.png' -print -quit)")"
    if [[ "$(cat "$work/frames/jpeg2000-$t.hash")" == "$(cat "$work/frames/libj2k-$t.hash")" ]]; then
        echo "$t s: identical"
        equal=$((equal + 1))
        continue
    fi
    psnr=$("$ffmpeg" -v info -i "$a" -i "$b" -lavfi psnr -f null - 2>&1 \
        | sed -n 's/.*average:\([0-9.]*\).*/\1/p' | head -1)
    [[ -n "$psnr" ]] || fail "could not compare frames at $t s"
    echo "$t s: PSNR ${psnr} dB"
    awk -v p="$psnr" 'BEGIN{exit !(p < 80)}' && fail "frames at $t s differ too much"
    awk -v p="$psnr" -v w="$worse" 'BEGIN{exit !(p < w)}' && worse=$psnr
done

echo "identical frames: $equal/${#times[@]}"
echo "lowest PSNR:      $worse dB"
echo
echo "PASS"
