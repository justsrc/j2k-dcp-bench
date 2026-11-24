# Full-feature results

One round per mode of the complete feature: 17,616 frames, 734.0 s, 4096x1714
`xyz12le`, with a separate 5.1 PCM sound MXF in the audio mode. A round lasts as
long as the programme, so these runs are not repeated.

| File | Content |
| --- | --- |
| `playback-video.tsv` | `gpu-next`, no audio, real time. |
| `playback.tsv` | `gpu-next` and CoreAudio, real time. |
| `gpu/playback-installed.tsv` | GPU utilization samples from the installed baseline audio run. |
| `gpu/playback-native-libj2k.tsv` | GPU utilization samples from the two bundled-decoder audio runs. |

The timing rows have the same columns as `bench/ab.sh`: round, label, real,
user, sys and final dropped-frame count. `playback.tsv` combines the installed
baseline with the two bundled decoders; the other rows are as written by the
script.

The GPU files are `bench/gpu-sampler.sh` output: `epoch<TAB>percent<TAB>pid<TAB>label`,
one sample per second. The label records which player, decoder and mode was
running. `docs/RESULTS.md` quotes the averages and peaks.

Player logs are not stored here. They contain local paths and are only useful
for the run that produced them.
