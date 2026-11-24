#!/bin/bash
# Render the TSV files written by ab.sh as Markdown tables.
#
# usage: report.sh [RESULTS_DIR] [FRAMES]
#
# Reads RESULTS_DIR/<mode>.tsv for the standard mode list and prints one table
# per mode. FRAMES defaults to 240 and is used for the fps column.
set -euo pipefail

dir=${1:-results}
frames=${2:-240}

modes=(headless headless-audio gpu gpu-audio playback-video playback)

for mode in "${modes[@]}"; do
    file="$dir/$mode.tsv"
    [[ -f "$file" ]] || continue
    echo "### $mode"
    echo
    awk -F'\t' -v frames="$frames" -v mode="$mode" '
        NR == 1 { next }
        {
            if (!seen[$2]++) order[++n] = $2
            if (!($2 in best_user) || $4 < best_user[$2]) {
                best_user[$2] = $4
                best_real[$2] = $3
                best_sys[$2] = $5
            }
            if ($6 != "") {
                d = $6 + 0
                if (!($2 in drops) || d > drops[$2])
                    drops[$2] = d
            }
        }
        END {
            if (n == 0) exit 1
            realtime = (mode ~ /^playback/)
            audioclocked = (mode == "gpu-audio")
            base_user = best_user[order[1]]
            if (realtime) {
                print "| Candidate | min real (s) | min user (s) | sys (s) | cores | CPU speedup | dropped frames |"
                print "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
            } else if (audioclocked) {
                print "| Candidate | min real (s) | min user (s) | sys (s) | cores | CPU speedup |"
                print "| --- | ---: | ---: | ---: | ---: | ---: |"
            } else {
                print "| Candidate | min real (s) | min user (s) | sys (s) | cores | fps | speedup |"
                print "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
            }
            for (i = 1; i <= n; i++) {
                l = order[i]
                cores = (best_user[l] + best_sys[l]) / best_real[l]
                if (realtime) {
                    printf "| %s | %.3f | %.3f | %.3f | %.2f | %.2fx | %s |\n",
                           l, best_real[l], best_user[l], best_sys[l], cores,
                           base_user / best_user[l],
                           (l in drops) ? drops[l] : "-"
                } else if (audioclocked) {
                    printf "| %s | %.3f | %.3f | %.3f | %.2f | %.2fx |\n",
                           l, best_real[l], best_user[l], best_sys[l], cores,
                           base_user / best_user[l]
                } else {
                    printf "| %s | %.3f | %.3f | %.3f | %.2f | %.2f | %.2fx |\n",
                           l, best_real[l], best_user[l], best_sys[l], cores,
                           frames / best_real[l],
                           best_real[order[1]] / best_real[l]
                }
            }
        }
    ' "$file"
    echo
done
