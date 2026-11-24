# Results

These numbers come from one machine, one build and the media described below.
They describe that setup, not a guarantee for other hardware or content.

## Build

| Item | Value |
| --- | --- |
| Workflow run | [45264544189](https://github.com/justsrc/j2k-dcp-bench/actions/runs/45264544189) |
| Artifact | `mpv-j2k-dcp-macos-arm64.zip` |
| SHA-256 | `cc852c2e044db3265a91d1e4b0da16752970a9a565d3695fc28bb91480f7f1bb` |
| mpv | `f92afa75cdb06e077a9ecd9a9ec2eb36b16327c2` |
| FFmpeg base | `359c82515228774eb683dffce9d623b6b4a2fa53` plus the 11 patches |
| libj2k | `0c61cb298a66b94c8536db5e2220cce4d8112200` plus the two fork patches |
| Runner | GitHub-hosted `xcode-27`, `macos27`, arm64 |

The downloaded zip matched `SHA256SUMS.txt`. The app reports
`mpv v0.42.0-dev-gf92afa75c`, `FFmpeg N-129219-g359c825152`, and lists both
`jpeg2000` and `libj2k` in `--vd=help`. `libj2k` is linked statically: there is
no `libj2k` dylib in the bundle and `_j2k_abi_version` is present in the mpv
binary. The build metadata and FFmpeg configuration are in
[`results/ci/`](results/ci/).

## Machine and media

- MacBook Pro, Apple M1 Pro, 10 cores (8 performance, 2 efficiency), 16 GB.
- macOS 27.2.1, Apple clang 21.0.0.
- The 240-frame runs were on battery power at 43%, with no thermal or
  performance warning recorded. The full-feature runs were on AC power with
  `caffeinate -dimsu` and the display on. Absolute times from the two groups are
  not directly comparable.
- Media: 240 frames of a 4K scope DCP excerpt, 4096x1714, 24 fps, 12-bit XYZ
  (`xyz12le`), three-level irreversible 9/7, wrapped as a 193 MB MXF with a
  silent 5.1 PCM track. The full-feature runs use the whole 17,616-frame feature
  and its separate 5.1 PCM sound MXF. Neither file is distributed here.
- Eight decoder threads, `--no-config`, five interleaved rounds, minimum time.
  The same clip and settings were used for all candidates.

## Same-source FFmpeg decoder

This comparison isolates the patch series. All three binaries were built from
this repository's FFmpeg tree with the same minimal configuration, compiler and
flags (`-O3`, Apple clang 21.0.0). The input is the 240-frame DCP codestream
concatenation, decoded with `-threads 8 -f null -`.

| Build | min real (s) | min user (s) | sys (s) | fps | wall speedup | CPU speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| stock `359c825152` | 18.540 | 141.170 | 0.740 | 12.94 | 1.00x | 1.00x |
| DWT and MCT commits (`04e2a2e8f2`) | 7.790 | 58.690 | 0.420 | 30.81 | 2.38x | 2.41x |
| Full series (`59cca28912`) | 5.640 | 42.800 | 0.360 | 42.55 | 3.29x | 3.30x |

The first six commits, which cover the DWT and multi-component transforms, give
most of the gain. The tier-1 and output commits add another 1.38x over that
intermediate build. The full series is 3.3x faster than stock in CPU time.

The decoded output is unchanged: all 240 frames from the stock and full-series
builds produced identical `framemd5` values.

Raw rows: [`results/ffmpeg-samesource-8t.tsv`](results/ffmpeg-samesource-8t.tsv).

## End-to-end mpv

`bench/matrix.sh` ran the installed Homebrew mpv and both decoders in the CI
app, in every output mode. Each row is the minimum of five interleaved rounds.
In the playback modes, real time includes player startup and the 10 s clip, so
the table shows CPU speedup and the largest final `frame-drop-count` across the
five runs instead.

### Headless (null video, no audio)

| Candidate | min real (s) | min user (s) | sys (s) | cores | fps | speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 22.840 | 151.950 | 1.860 | 6.73 | 10.51 | 1.00x |
| native `jpeg2000` | 7.920 | 49.350 | 0.890 | 6.34 | 30.30 | 2.88x |
| `libj2k` | 7.830 | 38.750 | 2.330 | 5.25 | 30.65 | 2.92x |

### Headless with audio (null video and audio)

| Candidate | min real (s) | min user (s) | sys (s) | cores | fps | speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 20.720 | 152.490 | 1.120 | 7.41 | 11.58 | 1.00x |
| native `jpeg2000` | 7.070 | 48.630 | 0.680 | 6.97 | 33.95 | 2.93x |
| `libj2k` | 7.310 | 39.060 | 2.530 | 5.69 | 32.83 | 2.83x |

### GPU output, no audio

| Candidate | min real (s) | min user (s) | sys (s) | cores | fps | speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 21.310 | 153.030 | 1.640 | 7.26 | 11.26 | 1.00x |
| native `jpeg2000` | 7.690 | 50.180 | 1.090 | 6.67 | 31.21 | 2.77x |
| `libj2k` | 7.740 | 39.580 | 2.620 | 5.45 | 31.01 | 2.75x |

### GPU output with CoreAudio

| Candidate | min real (s) | min user (s) | sys (s) | cores | CPU speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| installed | 22.870 | 153.600 | 1.930 | 6.80 | 1.00x |
| native `jpeg2000` | 11.150 | 48.470 | 0.850 | 4.42 | 3.17x |
| `libj2k` | 10.910 | 39.530 | 2.650 | 3.87 | 3.89x |

### Real-time playback, no audio

| Candidate | min real (s) | min user (s) | sys (s) | cores | CPU speedup | dropped frames |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 20.590 | 152.110 | 1.170 | 7.44 | 1.00x | 80 |
| native `jpeg2000` | 11.030 | 48.280 | 0.950 | 4.46 | 3.15x | 4 |
| `libj2k` | 10.670 | 39.580 | 2.750 | 3.97 | 3.84x | 13 |

### Real-time playback with CoreAudio

| Candidate | min real (s) | min user (s) | sys (s) | cores | CPU speedup | dropped frames |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 20.870 | 152.360 | 1.370 | 7.37 | 1.00x | 112 |
| native `jpeg2000` | 11.140 | 48.230 | 0.880 | 4.41 | 3.16x | 3 |
| `libj2k` | 10.800 | 39.320 | 2.600 | 3.88 | 3.87x | 7 |

The app held 24 fps far better than the installed build. Across five runs,
`playback-video` dropped 69 to 80 frames for installed mpv, 1 to 4 for native
`jpeg2000`, and 1 to 13 for `libj2k`. `playback` dropped 88 to 112 frames for
installed mpv, 0 to 3 for native, and 0 to 7 for `libj2k`. The installed player
also logged audio underruns in every `playback` run; neither bundled decoder
did.

On CPU time the gap is larger than wall time. `cores` is the mean number of
cores busy, `(user + sys) / real`. In the headless mode the installed player used
154 CPU-seconds across 6.7 cores, native `jpeg2000` 50 across 6.3, and `libj2k`
41 across 5.3. That is 3.1x and 3.7x less CPU for the same 240 frames. Real time
flattens near 8 s for both bundled decoders, so the remaining limit is shared
across threads rather than one core.

`libj2k` uses less CPU but drops more frames than native `jpeg2000` in real-time
playback. Both decoders run on the CPU in these results: the wrapper's default
`auto` backend picks libj2k's CPU decoder for classic JPEG 2000 and reserves
Metal for HTJ2K, where the GPU backend is faster. The drop difference comes from
the two CPU implementations and their thread scheduling, not from GPU
contention.

The installed Homebrew mpv is `v0.42.0-dev-g1eb941fdb` with FFmpeg
`N-129225-gdd86debdbc`. It is a different distribution and a different FFmpeg
revision, so that row measures the two builds, not the patch series alone. The
same-source section above is the controlled comparison.

## Full feature

The excerpt is short and fits in memory. To check sustained playback, each
candidate also played a whole feature: 17,616 frames, 734.0 s (12 min 14 s),
4096x1714 `xyz12le` at 146.8 Mbps, with 5.1 24-bit 48 kHz PCM in a separate
sound MXF. Each mode is one round, because a round lasts as long as the
programme.

### Video only

| Candidate | real (s) | user (s) | sys (s) | cores | dropped | drop rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 1470.590 | 10494.520 | 94.220 | 7.20 | 4674 | 26.5% |
| native `jpeg2000` | 735.220 | 3108.390 | 32.340 | 4.27 | 27 | 0.15% |
| `libj2k` | 734.850 | 2581.960 | 174.680 | 3.75 | 17 | 0.10% |

All three reached 733.96 s of playback time, so all played to the end. The two
bundled decoders ran at 1.00x: wall time is the 734 s programme plus about a
second of startup. Installed mpv took 1470 s, or 0.50x. It could not decode
24 fps, fell behind, and the player stretched the clock; its 26.5% drop count
understates how much of the picture a viewer would lose. Over 17,616 frames the
native decoder dropped 27 and `libj2k` 17, and their wall times differ by 0.4 s.

CPU time separates the decoders more clearly than wall time, because both
bundled candidates are limited by the frame clock rather than by throughput.
Installed mpv burned 10,589 CPU-seconds, native `jpeg2000` 3,141 and `libj2k`
2,757. That is 3.4x and 3.8x less CPU for the same 12 minutes. The native
decoder uses 14% more CPU time than `libj2k` and drops fewer frames.

### With CoreAudio

| Candidate | real (s) | user (s) | sys (s) | cores | dropped | drop rate | underruns |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| installed | 1428.900 | 10567.000 | 87.680 | 7.46 | 7883 | 44.8% | 737 |
| native `jpeg2000` | 735.230 | 3091.330 | 40.590 | 4.26 | 61 | 0.35% | 1 |
| `libj2k` | 735.350 | 2627.570 | 180.920 | 3.82 | 38 | 0.22% | 0 |

With audio the gap widens. Installed mpv needed 1429 s for the 734 s programme,
or 0.51x, and dropped 44.8% of the frames. Its CoreAudio output underran 737
times, so the audio clock fell behind and dragged wall time out. Native
`jpeg2000` and `libj2k` both finished in 735 s and dropped 61 and 38 frames
(0.35% and 0.22%); native logged one audio underrun and `libj2k` none.

Audio costs the bundled decoders about 1 s of wall time and no measurable CPU:
their `user` and `sys` totals are within 2% of the video-only run.

### GPU utilization

`bench/gpu-sampler.sh` read the GPU's `Device Utilization %` once per second
while the full feature played with audio. The idle desktop on this machine
reports about 10-14%, so these values include compositor work.

| Candidate | samples | average | peak |
| --- | ---: | ---: | ---: |
| installed | 467 | 25.3% | 86% |
| native `jpeg2000` | 718 | 28.2% | 95% |
| `libj2k` | 652 | 24.9% | 93% |

The installed samples start partway into its run; the two bundled rows cover
their whole run. The peaks are single one-second samples, not sustained load.
The GPU was never the bottleneck: even while the installed player ran at 0.5x,
the GPU averaged a quarter of its capacity and spent most of its time waiting
for CPU-decoded frames. A 4096x1714 12-bit frame is about 42 MB, and `gpu-next`
renders 24 of them per second, but that is well inside this GPU's budget. The
decoder, not the renderer, decides whether the feature plays in real time.

## libj2k Metal backend

`libj2k` has a CPU decoder and a Metal decoder. Its `auto` backend keeps classic
JPEG 2000 on the CPU and uses Metal for HTJ2K, where the GPU wins. To check that
choice on this content, the 240-frame excerpt was decoded with the CPU backend
and again with `--vd-lavc-o=backend=metal`, three interleaved rounds each, on AC
power in one session.

| Backend | headless (fps) | playback real (s) | dropped | CPU seconds (headless) | GPU busy (playback) |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU (`auto`) | 34.3 | 10.54 | 6 | 36.2 | 17% |
| Metal (forced) | 14.0 | 17.32 | 96 | 2.6 | 90% |

Metal does what it says: it moves the decode to the GPU, cuts CPU time by 14x,
and drives the GPU to about 90%. It is also 2.4x slower in headless throughput
and 1.6x slower in real-time playback, and it drops 96 of 240 frames against 6.
Part of the cost is unavoidable in this wrapper: every decoded picture has to
arrive in system memory for the output path, which is a 42 MB frame at this
resolution. `auto` is right to keep classic JPEG 2000 on the CPU here; Metal
remains useful for HTJ2K, where the transform suits the GPU.

These runs used the same excerpt as the matrix above but a different power
source, so compare the two backends with each other, not with the battery
tables.

## Correctness

`bench/verify.sh` passed against the downloaded app and the benchmark clip:

- both decoders are listed and each decoded all 240 frames with exit status 0;
- the PCM audio track decoded and `AO: [null]` opened with no underruns;
- five sampled frames from `jpeg2000` and `libj2k` were compared: frame 0 was
  byte-identical, and the other four had PSNR between 93.6 dB and 96.8 dB. The
  two decoders differ only by small rounding in the irreversible 9/7 transform.

The full report is in [`results/verify.txt`](results/verify.txt).

CI also ran the 44-stream style and source gate against the patched FFmpeg and
reported `ALL PASS`, then decoded a synthetic 9/7 MXF with both decoders. The
240-frame DCP excerpt is not in CI because it is not distributed.

## Caveats

- The 240-frame excerpt is long enough to measure decoder throughput, but not to
  show sustained playback. The full-feature section covers 12 minutes of real
  material; longer programmes may still differ.
- The playback modes open a real window through `gpu-next` and, with audio,
  CoreAudio. `gpu-next` renders on the GPU. Both bundled decoders decode classic
  JPEG 2000 on the CPU in these runs; libj2k's default `auto` backend only uses
  Metal for HTJ2K. The Metal decoder can be forced with
  `--vd-lavc-o=backend=metal`.
- GPU utilization comes from IOAccelerator's `Device Utilization %`, sampled
  once per second. It is a whole-GPU instantaneous percentage, not a breakdown,
  and it includes `gpu-next` rendering as well as decoding.
- The app is ad-hoc signed and not notarized, as described in the README.
- The five-round excerpt matrix was on battery and the full-feature runs on AC
  power. Both comparisons are internally consistent, but absolute times from
  this page should not be compared with runs on another machine or power
  source.
