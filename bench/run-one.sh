#!/bin/bash
# Run one player/decoder pair and print real, user and sys seconds plus the
# last frame-drop count and its label, as a tab-separated row.
#
# usage: run-one.sh PLAYER DECODER MEDIA FRAMES THREADS [MODE]
#
# Modes:
#   headless        null video, no audio, untimed
#   headless-audio  null video and audio output, audio decoded, untimed
#   gpu             GPU video, no audio, untimed
#   gpu-audio       GPU video, CoreAudio output, untimed
#   playback-video  GPU video, no audio, real time
#   playback        GPU video, CoreAudio output, real time
#
# MODE is used when the sixth argument is omitted.
#
# Set LOG_DIR to keep the player output for each run. Set LOG_NAME to name
# the file inside that directory. Set TOKEN to add a report marker to the
# status line so a run can be found in a windowed player. Set AUDIO_FILE to
# add an external audio track, for example a DCP sound MXF next to a picture
# MXF; it is used by the audio modes.
#
# Set SAMPLE_GPU=1 to record GPU utilization while the player runs; this needs
# LOG_DIR. Samples go to <log>.gpu.tsv and an average and peak are appended to
# the log. Set EXTRA_ARGS to append more player arguments, for example
# "--vd-lavc-o=backend=metal".
set -euo pipefail

player=${1:?usage: run-one.sh PLAYER DECODER MEDIA FRAMES THREADS [MODE]}
decoder=${2:?}
media=${3:?}
frames=${4:?}
threads=${5:?}
mode=${6:-${MODE:-headless}}

[[ -x "$player" ]] || { echo "not executable: $player" >&2; exit 2; }
[[ -f "$media" ]]   || { echo "not a file: $media" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)

extra_args=()
if [[ -n ${EXTRA_ARGS:-} ]]; then
    read -r -a extra_args <<< "$EXTRA_ARGS"
fi

status_msg='STATUS drop=${=frame-drop-count} mistimed=${=mistimed-frame-count} vf=${=estimated-vf-fps} time=${=playback-time}'

args=(--no-config --no-audio --vd="$decoder" --vd-lavc-threads="$threads")
case "$mode" in
    headless)
        args+=(--vo=null --ao=null --untimed)
        ;;
    headless-audio)
        args=(--no-config --vd="$decoder" --vd-lavc-threads="$threads")
        args+=(--vo=null --ao=null --ao-null-untimed --untimed)
        ;;
    gpu)
        args+=(--vo=gpu-next --ao=null --untimed)
        ;;
    gpu-audio)
        args=(--no-config --vd="$decoder" --vd-lavc-threads="$threads")
        args+=(--vo=gpu-next --ao=coreaudio --untimed)
        ;;
    playback-video)
        args+=(--vo=gpu-next --ao=null)
        args+=(--term-osd=force "--term-status-msg=$status_msg")
        ;;
    playback)
        args=(--no-config --vd="$decoder" --vd-lavc-threads="$threads")
        args+=(--vo=gpu-next --ao=coreaudio)
        args+=(--term-osd=force "--term-status-msg=$status_msg")
        ;;
    *)
        echo "unknown mode: $mode" >&2
        exit 2
        ;;
esac

args+=(--frames="$frames")
if [[ "$mode" != playback* ]]; then
    args+=(--really-quiet)
fi
if [[ -n ${TOKEN:-} ]]; then
    args+=(--title="$TOKEN")
fi
if [[ -n ${AUDIO_FILE:-} ]]; then
    [[ -f "$AUDIO_FILE" ]] || { echo "not a file: $AUDIO_FILE" >&2; exit 2; }
    args+=(--audio-file="$AUDIO_FILE")
fi
if [[ ${#extra_args[@]} -gt 0 ]]; then
    args+=("${extra_args[@]}")
fi
args+=("$media")

time_file=$(mktemp)
trap 'rm -f "$time_file"' EXIT

run_log=
if [[ -n ${LOG_DIR:-} ]]; then
    mkdir -p "$LOG_DIR"
    run_log="$LOG_DIR/${LOG_NAME:-$mode}.log"
    {
        printf 'command:'
        printf ' %q' "$player" "${args[@]}"
        printf '\n'
    } > "$run_log"
fi

set +e
gpu_pid=
if [[ ${SAMPLE_GPU:-0} == 1 ]]; then
    if [[ -n "$run_log" ]]; then
        gpu_file="${run_log%.log}.gpu.tsv"
    else
        gpu_file=
        echo "SAMPLE_GPU needs LOG_DIR; not sampling" >&2
    fi
else
    gpu_file=
fi

if [[ -n "$run_log" ]]; then
    /usr/bin/time -p -o "$time_file" "$player" "${args[@]}" \
        >> "$run_log" 2>&1 &
else
    /usr/bin/time -p -o "$time_file" "$player" "${args[@]}" \
        > /dev/null 2>&1 &
fi
player_pid=$!
if [[ -n "$gpu_file" ]]; then
    "$here/gpu-sampler.sh" "$gpu_file" "$player_pid" &
    gpu_pid=$!
fi
wait "$player_pid"
status=$?
set -e

if [[ -n "$gpu_file" ]]; then
    wait "$gpu_pid" 2>/dev/null || true
    if [[ -s "$gpu_file" ]]; then
        awk -F'\t' '
            { n++; s += $2; if ($2 > m) m = $2 }
            END {
                if (n)
                    printf "gpu: avg=%.1f%% peak=%d%% samples=%d\n",
                           s / n, m, n
            }
        ' "$gpu_file" >> "$run_log"
    fi
fi

drops=
if [[ -n "$run_log" ]]; then
    printf 'exit: %d\n' "$status" >> "$run_log"
    cat "$time_file" >> "$run_log"
    drops=$(tr '\r' '\n' < "$run_log" |
            sed -n 's/.*STATUS drop=\([0-9][0-9]*\).*/\1/p' |
            tail -1)
    if [[ -z "$drops" ]] && tr '\r' '\n' < "$run_log" | grep -q 'STATUS drop='; then
        drops=0
    fi
    printf 'drops: %s\n' "${drops:-none}" >> "$run_log"
fi

if [[ $status -ne 0 ]]; then
    echo "player exited with $status ($mode, $decoder)" >&2
    exit "$status"
fi

awk -v drops="${drops:-}" '
    $1 == "real" { real = $2 }
    $1 == "user" { user = $2 }
    $1 == "sys"  { sys  = $2 }
    END {
        if (real == "")
            exit 1
        printf "%.3f\t%.3f\t%.3f\t%s\n", real, user, sys, drops
    }
' "$time_file"
