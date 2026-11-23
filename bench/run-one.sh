#!/bin/bash
# Run one player/decoder pair over a fixed number of frames and print
# real, user and sys seconds as a tab-separated row.
#
# usage: run-one.sh PLAYER DECODER MEDIA FRAMES THREADS
set -euo pipefail

player=${1:?usage: run-one.sh PLAYER DECODER MEDIA FRAMES THREADS}
decoder=${2:?}
media=${3:?}
frames=${4:?}
threads=${5:?}

[[ -x "$player" ]] || { echo "not executable: $player" >&2; exit 2; }
[[ -f "$media" ]]   || { echo "not a file: $media" >&2; exit 2; }

time_file=$(mktemp)
trap 'rm -f "$time_file"' EXIT

# --no-config keeps the measurement independent of the user's mpv.conf.
# --vo=null and --ao=null remove GPU and audio from the path; --untimed
# decodes as fast as the machine allows instead of at the presentation rate.
/usr/bin/time -p -o "$time_file" \
    "$player" --no-config --no-audio \
    --vd="$decoder" --vo=null --ao=null --untimed \
    --vd-lavc-threads="$threads" \
    --frames="$frames" --really-quiet \
    "$media" >/dev/null 2>&1

awk '
    $1 == "real" { real = $2 }
    $1 == "user" { user = $2 }
    $1 == "sys"  { sys  = $2 }
    END {
        if (real == "")
            exit 1
        printf "%.3f\t%.3f\t%.3f\n", real, user, sys
    }
' "$time_file"
