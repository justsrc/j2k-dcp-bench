#!/bin/bash
# Interleaved A/B benchmark: every candidate runs once per round, in the
# same order, so slow drift and thermal changes hit all candidates alike.
# Reports the minimum user and real time per candidate.
#
# usage:
#   ab.sh REPS FRAMES THREADS MEDIA LABEL=PLAYER:DECODER [LABEL=PLAYER:DECODER ...]
#
# example:
#   ab.sh 5 240 8 clip.mxf \
#     installed=/opt/homebrew/bin/mpv:jpeg2000 \
#     native=./mpv.app/Contents/MacOS/mpv:jpeg2000 \
#     libj2k=./mpv.app/Contents/MacOS/mpv:libj2k
#
# The raw rows are written to $OUT (default: bench-results.tsv).
set -euo pipefail

reps=${1:?usage: ab.sh REPS FRAMES THREADS MEDIA LABEL=PLAYER:DECODER ...}
frames=${2:?}
threads=${3:?}
media=${4:?}
shift 4

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

out=${OUT:-bench-results.tsv}
printf 'round\tlabel\treal\tuser\tsys\n' > "$out"

for ((round = 1; round <= reps; round++)); do
    for spec in "${specs[@]}"; do
        label=${spec%%=*}
        rest=${spec#*=}
        player=${rest%%:*}
        decoder=${rest#*:}
        row=$("$here/run-one.sh" "$player" "$decoder" "$media" "$frames" "$threads")
        printf '%s\t%s\t%s\n' "$round" "$label" "$row" >> "$out"
        printf 'round %d/%d  %-16s %s\n' "$round" "$reps" "$label" "$row" >&2
    done
done

awk -F'\t' -v frames="$frames" '
    NR == 1 { next }
    {
        if (!seen[$2]++) order[++n] = $2
        if (!($2 in best_user) || $4 < best_user[$2]) {
            best_user[$2] = $4
            best_real[$2] = $3
        }
        if (!($2 in best_sys) || $5 < best_sys[$2])
            best_sys[$2] = $5
    }
    END {
        if (n == 0) exit 1
        base = best_real[order[1]]
        printf "\n%-18s %10s %12s %10s %9s %9s\n",
               "candidate", "min_real", "min_user", "sys", "fps", "speedup"
        for (i = 1; i <= n; i++) {
            l = order[i]
            printf "%-18s %10.3f %12.3f %10.3f %9.2f %8.2fx\n",
                   l, best_real[l], best_user[l], best_sys[l],
                   frames / best_real[l], base / best_real[l]
        }
        printf "\nraw rows: %s\n", ENVIRON["OUT"] ? ENVIRON["OUT"] : "bench-results.tsv"
    }
' "$out"
