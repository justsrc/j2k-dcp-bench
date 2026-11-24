#!/bin/bash
# Make a JPEG 2000 MXF clip for the benchmark. The default is a 4K scope
# frame at 24 fps with the irreversible 9/7 transform, 12-bit 4:4:4 samples,
# and a silent 5.1 PCM track, so the float DWT path and the audio modes are
# both exercised.
#
# usage: make-clip.sh OUTPUT [SECONDS] [WIDTHxHEIGHT]
#
# This is a synthetic clip. For numbers that match a real DCP, cut a
# stream copy of a picture MXF instead:
#   ffmpeg -ss 600 -i picture.mxf -t 10 -c copy -an clip.mxf
set -euo pipefail

out=${1:?usage: make-clip.sh OUTPUT [SECONDS] [WIDTHxHEIGHT]}
seconds=${2:-10}
size=${3:-4096x1714}

[[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || {
    echo "bad size '$size'; use WIDTHxHEIGHT" >&2
    exit 2
}
width=${size%x*}
height=${size#*x}

ffmpeg -y -v error -f lavfi \
    -i "testsrc2=size=$size:rate=24:duration=$seconds" \
    -f lavfi -i "anullsrc=channel_layout=5.1:sample_rate=48000" \
    -map 0:v:0 -map 1:a:0 \
    -pix_fmt yuv444p12le -c:v jpeg2000 -pred 0 -format j2k \
    -tile_width "$width" -tile_height "$height" -layer_rates 1 \
    -sop 1 -eph 1 -c:a pcm_s24le -shortest -f mxf "$out"

printf 'wrote %s (%s s, %s, silent 5.1 audio)\n' "$out" "$seconds" "$size"
