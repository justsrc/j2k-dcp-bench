# Result data

Each `*.tsv` file is the raw output of `bench/ab.sh`: one row per candidate per
round, with real, user and sys seconds, and the final frame-drop count for
real-time modes. `docs/RESULTS.md` is generated from the same rows.

| File | Content |
| --- | --- |
| `headless.tsv` | Null video and audio, untimed. |
| `headless-audio.tsv` | Null video and audio, PCM decoded, null audio untimed. |
| `gpu.tsv` | `gpu-next`, no audio, untimed. |
| `gpu-audio.tsv` | `gpu-next` and CoreAudio, audio-clocked. |
| `playback-video.tsv` | `gpu-next`, no audio, real time. |
| `playback.tsv` | `gpu-next` and CoreAudio, real time. |
| `ffmpeg-samesource-8t.tsv` | Standalone FFmpeg decoder, stock and patched builds. |
| `instrumented-headless.tsv` | Headless excerpt matrix with GPU sampling, AC power. |
| `instrumented-headless-metal.tsv` | Same, with forced `libj2k` Metal decode. |
| `instrumented-playback-video.tsv` | Real-time excerpt matrix with GPU sampling, AC power. |
| `instrumented-playback-video-metal.tsv` | Same, with forced `libj2k` Metal decode. |
| `instrumented-gpu/` | Per-run GPU samples for the instrumented rows. |
| `verify.txt` | `bench/verify.sh` on the DCP excerpt with silent 5.1 audio. |
| `verify-synthetic.txt` | `bench/verify.sh` on the synthetic clip. |
| `ci/` | Build metadata, artifact checksum, FFmpeg configuration and patches. |
| `full/` | One round per mode of the complete 17,616-frame feature. |

Player logs are not stored here. They contain local paths and are only useful
for the run that produced them.
