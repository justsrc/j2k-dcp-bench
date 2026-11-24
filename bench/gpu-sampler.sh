#!/bin/bash
# Sample the Apple GPU "Device Utilization %" once per second until a process
# exits. Writes "epoch<TAB>percent" rows, one per sample.
#
# usage: gpu-sampler.sh OUTPUT_FILE PID
#
# This is the only GPU utilization counter macOS exposes without root.
# powermetrics needs sudo and would prompt on every run, so the benchmark does
# not use it. The value is the whole-GPU instantaneous percentage reported by
# IOAccelerator; on Apple silicon there is a single accelerator.
#
# `set -u` only: this runs in the background while the player is measured, and
# must never take the run down with it. Missing samples are simply skipped.
set -u

out=${1:?usage: gpu-sampler.sh OUTPUT_FILE PID}
pid=${2:?usage: gpu-sampler.sh OUTPUT_FILE PID}

: > "$out"

while kill -0 "$pid" 2>/dev/null; do
    util=$(ioreg -r -d 1 -c IOAccelerator -l 2>/dev/null |
           grep -o '"Device Utilization %"=[0-9]*' | head -1 |
           cut -d= -f2)
    if [[ -n "$util" ]]; then
        printf '%s\t%s\n' "$(date +%s)" "$util" >> "$out"
    fi
    sleep 1
done
