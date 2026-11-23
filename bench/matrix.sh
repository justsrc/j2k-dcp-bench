#!/bin/bash
# Run the full local benchmark matrix: every output mode, every candidate,
# interleaved, with logs and raw rows kept under OUTDIR.
#
# usage:
#   APP=/path/to/mpv.app/Contents/MacOS/mpv \
#   MEDIA=/path/to/clip.mxf \
#   bench/matrix.sh
#
# Environment:
#   APP        patched player (required)
#   MEDIA      benchmark clip (required)
#   INSTALLED  baseline player, default /opt/homebrew/bin/mpv; set to an
#              empty string to skip the baseline
#   REPS       rounds per mode, default 5
#   FRAMES     frames per run, default 240
#   THREADS    decoder threads, default 8
#   FPS        media frame rate, default 24
#   OUTDIR     output directory, default results
#
# Each mode writes OUTDIR/MODE.tsv. Player output is in OUTDIR/logs.
set -euo pipefail

app=${APP:?set APP to the patched mpv binary}
media=${MEDIA:?set MEDIA to the benchmark clip}
installed=${INSTALLED-/opt/homebrew/bin/mpv}
reps=${REPS:-5}
frames=${FRAMES:-240}
threads=${THREADS:-8}
fps=${FPS:-24}
outdir=${OUTDIR:-results}

[[ -x "$app" ]] || { echo "not executable: $app" >&2; exit 2; }
[[ -f "$media" ]] || { echo "not a file: $media" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$outdir/logs"

candidates=()
if [[ -n "$installed" ]]; then
    [[ -x "$installed" ]] || { echo "not executable: $installed" >&2; exit 2; }
    candidates+=("installed=$installed:jpeg2000")
fi
candidates+=("native=$app:jpeg2000" "libj2k=$app:libj2k")

modes=(headless headless-audio gpu gpu-audio playback-video playback)
summary="$outdir/summary.txt"
: > "$summary"

for mode in "${modes[@]}"; do
    echo "=== $mode ===" | tee -a "$summary"
    MODE=$mode \
    FPS=$fps \
    LOG_DIR="$outdir/logs" \
    OUT="$outdir/$mode.tsv" \
        "$here/ab.sh" "$reps" "$frames" "$threads" "$media" \
        "${candidates[@]}" 2>&1 | tee -a "$summary"
    echo | tee -a "$summary"
done

echo "wrote $summary"
