# j2k-dcp-bench

Patched JPEG 2000 decoding for FFmpeg, built into an arm64 macOS mpv app by
GitHub Actions. The app contains the patched native `jpeg2000` decoder and an
optional `libj2k` decoder, so both can be measured on the same player build.

This is a benchmark and review repository. The FFmpeg patches are not upstream.

## What is in the repository

- `patches/ffmpeg/0001` to `0011`: the native decoder series, based on FFmpeg
  `359c82515228774eb683dffce9d623b6b4a2fa53`.
- `patches/ffmpeg/libj2k-wiring.patch` and `libj2kdec.c`: an optional decoder
  that calls the [frames-sg/j2k](https://github.com/frames-sg/j2k) C ABI.
- `patches/j2k/`: two patches that add a static library target and a Metal
  backend to the j2k fork.
- `.github/workflows/build.yml`: builds FFmpeg and mpv on a GitHub-hosted
  `xcode-27` arm64 runner, checks the decoders, and uploads a zip.
- `bench/`: scripts for generating a clip and running interleaved A/B tests.
- `tests/j2kstyles/`: 44 small synthetic streams and their reference hashes.
- `versions.env`: every pinned revision used by the build.
- `docs/`: build and benchmark method, plus measured results.

## Build

The workflow runs on every push to `main` and on manual dispatch. It builds
one app with both decoders. To build your own copy, fork this repository and
run the `build` workflow.

The `mpv-j2k-dcp-macos-arm64` artifact contains:

- `mpv-j2k-dcp-macos-arm64.zip`
- `SHA256SUMS.txt`
- `build-metadata.json`
- `ffmpeg_patches.txt`
- the embedded FFmpeg configuration and license strings
- `--vd`, `--ad`, `--af` and `--ao` feature lists

Artifacts expire after 30 days. There are no releases and no binary in the
repository. The zip is ad-hoc signed by the bundling script and not notarized.

## Run the app

```sh
unzip mpv-j2k-dcp-macos-arm64.zip
./mpv.app/Contents/MacOS/mpv --no-config --vd=jpeg2000 picture.mxf
./mpv.app/Contents/MacOS/mpv --no-config --vd=libj2k picture.mxf
```

`--vd=jpeg2000` selects the patched native decoder. `--vd=libj2k` selects the
libj2k decoder.

The native patches are CPU work: NEON transforms and more efficient tier-1 and
output loops. `jpeg2000` still decodes on the CPU. `gpu-next` uses the GPU to
render the decoded frames in every mode. `libj2k` also has a Metal backend, but
its default `auto` setting uses the CPU for classic JPEG 2000 and Metal only for
HTJ2K, where the GPU is faster. To force the Metal decoder anyway, add
`--vd-lavc-o=backend=metal`; `bench/run-one.sh` accepts the same through
`EXTRA_ARGS`. On the measured content the forced backend is 2.4x slower in
throughput and drops far more frames; `docs/RESULTS.md` has the comparison.

## Patches

The native series changes the DWT, the multi-component transform, tier-1 and
the output path.

| Patch | Change |
| --- | --- |
| 0001 | Processes the 9/7 float vertical pass in 16-column blocks through transposed scratch. |
| 0002 | Adds aarch64 NEON irreversible and reversible multi-component transforms. |
| 0003 | Fuses the two horizontal interleave copies into one loop. |
| 0004 | Fuses the 9/7 float vertical lifting passes. |
| 0005 | Extends the checkasm MCT test to all tail sizes from zero through `BUF_SIZE`. |
| 0006 | Adds a test-only reference implementation of the 9/7 synthesis schedule and compares it with the block and fused paths. |
| 0007 | Packs Qe, MPS and both next states into one table entry, keeps 48 bits of read-ahead in a 64-bit C register, and renormalizes in one batch. |
| 0008 | Packs the tier-1 context tables and the sign XOR bit, and makes the significance update inline. |
| 0009 | Replaces per-coefficient tier-1 flags with one 32-bit word per four-row stripe column, and skips all-zero cleanup columns. |
| 0010 | Returns early when the ROI shift is zero and writes three packed components in one interleaved pass. |
| 0011 | Fuses lifting steps 1 and 2, and steps 3 and 4, in the 9/7 float pass. |

Patch 0006 is a test. Patches 0005 and 0006 do not change decoder output.

To apply the series to a fresh FFmpeg tree:

```sh
git clone https://github.com/FFmpeg/FFmpeg.git ffmpeg
git -C ffmpeg checkout 359c82515228774eb683dffce9d623b6b4a2fa53
git -C ffmpeg am /path/to/j2k-dcp-bench/patches/ffmpeg/0*.patch
```

The series keeps the operand order and evaluation order of the floating-point
lifting steps. It was verified bit-identical to the unpatched decoder when both
were built with the same compiler and flags. If you compare frame hashes, use
the same compiler, optimization level and floating-point flags for both trees.

The wire patch adds `--enable-libj2k` and a decoder wrapper. It is independent
of the native series and can be omitted if only `--vd=jpeg2000` is needed.

## Correctness

The native series was checked on a 240-frame excerpt of a 4K scope DCP
(4096x1714, 12-bit XYZ, three-level 9/7) against the same FFmpeg base without
the patches. All 240 decoded frames had identical `framemd5` values.

A 44-stream gate covered coding styles, gray and colour sources, odd sizes and
origins, multiple decomposition levels, and reversible 5/3 streams. Every
stream matched the reference decoder output, and every 5/3 stream reproduced
its source pixels exactly. The streams and the gate are in `tests/`.

The CI workflow runs that gate against the patched FFmpeg, then encodes a
synthetic 9/7 clip and decodes it with both `--vd=jpeg2000` and `--vd=libj2k`.
The 240-frame DCP excerpt is not in the repository, so that check is not part
of CI.

## Benchmark

Generate a synthetic 240-frame 4K scope clip at 24 fps with the irreversible
9/7 transform:

```sh
bench/make-clip.sh clip.mxf 10 4096x1714
```

Check the app and the clip before timing anything:

```sh
APP=./mpv.app/Contents/MacOS/mpv MEDIA=clip.mxf bench/verify.sh
```

Run one interleaved comparison. Each candidate runs once per round, in the same
order, and the script reports the minimum real and user time:

```sh
MODE=headless bench/ab.sh 5 240 8 clip.mxf \
    installed=/opt/homebrew/bin/mpv:jpeg2000 \
    native=./mpv.app/Contents/MacOS/mpv:jpeg2000 \
    libj2k=./mpv.app/Contents/MacOS/mpv:libj2k
```

Run every output mode with logs and a combined summary:

```sh
APP=./mpv.app/Contents/MacOS/mpv MEDIA=clip.mxf bench/matrix.sh
```

`matrix.sh` covers these modes:

| Mode | Video output | Audio | Clock |
| --- | --- | --- | --- |
| `headless` | null | off | untimed |
| `headless-audio` | null | null, decoded | untimed |
| `gpu` | `gpu-next` | off | untimed |
| `gpu-audio` | `gpu-next` | CoreAudio | audio clock |
| `playback-video` | `gpu-next` | off | real time |
| `playback` | `gpu-next` | CoreAudio | real time |

The player runs with `--no-config` and eight decoder threads, so the user's mpv
configuration does not affect the result. The null-output modes measure decoding
throughput; `headless-audio` also sets `--ao-null-untimed` so the null audio
device does not pace playback. `gpu-audio` and `playback` use CoreAudio, so
their wall time is at least the audio duration. The playback modes measure
whether the player can hold the frame clock; `ab.sh` records the final
`frame-drop-count` for those runs. Real time in a playback mode includes player
startup and the clip duration, and a player that cannot keep up stretches it, so
compare dropped frames and CPU time there, not wall speedup.

Set `SAMPLE_GPU=1` before `bench/ab.sh` or `bench/matrix.sh` to record GPU
utilization next to the player logs. `bench/gpu-sampler.sh` reads the GPU's
`Device Utilization %` once per second, writes
`results/logs/<mode>-r<round>-<label>.gpu.tsv`, and appends a `gpu:` line with
the average and peak to the player log. CPU utilization is the `user + sys`
seconds divided by real seconds. `EXTRA_ARGS` passes more player arguments, for
example `EXTRA_ARGS="--vd-lavc-o=backend=metal"` to force the `libj2k` Metal
decoder.

Raw rows are written to `results/<mode>.tsv`, logs to `results/logs/`.
`bench/report.sh results` renders those rows as Markdown tables.
`docs/RESULTS.md` contains the measured numbers for one machine.

The synthetic clip is a dense test pattern, so its bitrate is higher than most
DCPs and its playback is a stress test. For representative playback numbers,
cut a stream copy from a picture MXF you own:

```sh
ffmpeg -ss 600 -i picture.mxf -t 10 -c copy -an clip.mxf
```

To play a whole feature, set the frame count. A DCP keeps picture and sound in
separate MXFs; `AUDIO_FILE` adds the sound MXF without remuxing. One round is
enough for a full feature because a round then takes as long as the programme:

```sh
MODE=playback FRAMES=17616 AUDIO_FILE=sound.mxf SAMPLE_GPU=1 \
    bench/ab.sh 1 17616 8 picture.mxf \
    installed=/opt/homebrew/bin/mpv:jpeg2000 \
    native=./mpv.app/Contents/MacOS/mpv:jpeg2000 \
    libj2k=./mpv.app/Contents/MacOS/mpv:libj2k
```

The workflow does not run this benchmark. Shared CI runners are not a stable
timing environment. The workflow builds the app and checks correctness; run the
timings on your own machine.

The installed Homebrew mpv bundles a different FFmpeg revision from this build.
That comparison measures two distributions, not the patch series alone.
`docs/RESULTS.md` reports both that comparison and a same-source FFmpeg
comparison.

## Scope

The build targets arm64 macOS. The NEON multi-component transforms are
aarch64-only. The rest of the native series is portable C, but only arm64
macOS was built and measured.

The native decoder handles the DCP cases covered by these patches. It is still
the FFmpeg decoder, with the same format and profile limits. The libj2k path
uses a separate decoder with its own limits; see `libj2kdec.c` for the accepted
subset.

No DCP or other large media is stored in this repository. The benchmark uses a
synthetic clip or media you supply.

## License

The repository contents are licensed under the GNU Lesser General Public
License, version 2.1 or later. See `LICENSE` and `NOTICE`.

The built application is GPL version 3 or later because the FFmpeg
configuration enables GPL components. The libj2k fork is dual-licensed MIT or
Apache-2.0. FFmpeg and mpv retain their own copyright and license notices.
