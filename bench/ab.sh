#!/bin/bash
# Interleaved A/B benchmark: every candidate runs once per round, in the
# same order, so slow drift and thermal changes hit all candidates alike.
# Reports the minimum user and real time per candidate, plus the final
# frame-drop count for real-time playback modes.
#
# usage:
#   ab.sh REPS FRAMES THREADS MEDIA LABEL=PLAYER:DECODER [LABEL=PLAYER:DECODER ...]
#
# Set MODE to one of the modes accepted by run-one.sh. The default is
# headless. Logs are written to $LOG_DIR, default bench-logs.
#
# example:
#   MODE=headless ab.sh 5 240 8 clip.mxf \
#     installed=/opt/homebrew/bin/mpv:jpeg2000 \
#     native=./mpv.app/Contents/MacOS/mpv:jpeg2000 \
#     libj2k=./mpv.app/Contents/MacOS/mpv:libj2k
#
# The raw rows are written to $OUT, default bench-results-$MODE.tsv.
set -euo pipefail

reps=${1:?usage: ab.sh REPS FRAMES THREADS MEDIA LABEL=PLAYER:DECODER ...}
frames=${2:?}
threads=${3:?}
media=${4:?}
shift 4

mode=${MODE:-headless}
fps=${FPS:-24}
LOG_DIR=${LOG_DIR:-bench-logs}

[[ $# -gt 0 ]] || {
    echo "no candidates; use LABEL=PLAYER:DECODER" >&2
    exit 2
}
[[ -f "$media" ]] || { echo "not a file: $media" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
specs=("$@")

for spec in "${specs[@]}"; do
    label=${spec%%=*}
    rest=${spec#*=}
    if [[ "$label" == "$spec" || "$rest" != *:* ]]; then
        echo "bad candidate '$spec'; use LABEL=PLAYER:DECODER" >&2
        exit 2
    fi
done

out=${OUT:-bench-results-$mode.tsv}
printf 'round\tlabel\treal\tuser\tsys\tdrops\n' > "$out"

for ((round = 1; round <= reps; round++)); do
    for spec in "${specs[@]}"; do
        label=${spec%%=*}
        rest=${spec#*=}
        player=${rest%%:*}
        decoder=${rest#*:}
        row=$(LOG_DIR="$LOG_DIR" LOG_NAME="${mode}-r${round}-${label}" \
              "$here/run-one.sh" "$player" "$decoder" "$media" \
              "$frames" "$threads" "$mode")
        printf '%s\t%s\t%s\n' "$round" "$label" "$row" >> "$out"
        printf 'round %d/%d  %-16s %s\n' "$round" "$reps" "$label" "$row" >&2
    done
done

awk -F'\t' -v frames="$frames" -v fps="$fps" -v mode="$mode" -v out="$out" '
    NR == 1 { next }
    {
        if (!seen[$2]++) order[++n] = $2
        if (!($2 in best_user) || $4 < best_user[$2]) {
            best_user[$2] = $4
            best_real[$2] = $3
            best_sys[$2] = $5
        }
        if ($6 != "" && $6 + 0 > drops[$2])
            drops[$2] = $6 + 0
    }
    END {
        if (n == 0) exit 1
        realtime = (mode ~ /^playback/)
        base = best_real[order[1]]
        base_user = best_user[order[1]]
        printf "\nmode: %s\n", mode
        if (realtime) {
            printf "%-18s %10s %12s %10s %9s %8s\n",
                   "candidate", "min_real", "min_user", "sys", "cpu_speedup", "drops"
            for (i = 1; i <= n; i++) {
                l = order[i]
                printf "%-18s %10.3f %12.3f %10.3f %8.2fx %8s\n",
                       l, best_real[l], best_user[l], best_sys[l],
                       base_user / best_user[l],
                       (l in drops) ? drops[l] : "-"
            }
            printf "\nreal time includes player startup and the %.1f s media duration;\n",
                   frames / fps
            printf "compare dropped frames, not wall time.\n"
        } else {
            printf "%-18s %10s %12s %10s %9s %9s\n",
                   "candidate", "min_real", "min_user", "sys", "fps", "speedup"
            for (i = 1; i <= n; i++) {
                l = order[i]
                printf "%-18s %10.3f %12.3f %10.3f %9.2f %8.2fx\n",
                       l, best_real[l], best_user[l], best_sys[l],
                       frames / best_real[l], base / best_real[l]
            }
        }
        printf "\nraw rows: %s\n", out
    }
' "$out"
