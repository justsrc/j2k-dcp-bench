# Method

## Pins

Every revision used by the build is in `versions.env`.

| Component | Revision |
| --- | --- |
| mpv-build | `9443097290e82008f26f1597590926c63e7ae053` |
| mpv | `f92afa75cdb06e077a9ecd9a9ec2eb36b16327c2` |
| FFmpeg base | `359c82515228774eb683dffce9d623b6b4a2fa53` |
| libass | `21b5a54fceff49c126c201d4b51c6445287a5072` |
| libplacebo | `f2e04cb1840ef1f1586b71050bff40b04cbd8d91` |
| j2k | `0c61cb298a66b94c8536db5e2220cce4d8112200` |
| Rust | `1.99.0` |

The j2k patches add a `staticlib` target and a `metal` feature to the j2k C
crate. The FFmpeg wiring patch adds `--enable-libj2k` and the decoder wrapper.

## Build

The workflow checks out mpv-build, fetches the pinned mpv, FFmpeg, libass and
libplacebo sources, applies the patches, and runs mpv-build's `build` target.
It builds on a GitHub-hosted `xcode-27` arm64 runner and writes to
`/private/tmp`, so build-machine paths do not end up in the binary.

FFmpeg and mpv are built with the same compiler and flags as the reference
build. The 9/7 float DWT patches reorder lifting operations but keep their
operand and evaluation order, so the output stays bit-identical to the
unpatched decoder when both trees use the same flags. The frame-hash gate
would not be meaningful across different floating-point flags.

The workflow checks:

- the runner is arm64 and the expected toolchain is present;
- both `jpeg2000` and `libj2k` appear in `--vd=help`;
- the FFmpeg configuration has no `--enable-nonfree` and no library reports a
  nonfree license;
- libj2k is linked statically, not bundled as a dylib;
- every bundled Mach-O file has only bundle-relative or system dependencies,
  no absolute rpath, and no build-machine path in its strings;
- the 44-stream style and source gate passes;
- both decoders decode a synthetic 9/7 MXF clip.

## Native decoder gates

The main gate compares the patched decoder with the unpatched decoder built
from the same FFmpeg commit. The test input is a 240-frame 4K scope DCP excerpt
(4096x1714, 12-bit XYZ, three-level 9/7). It is not distributed here.

```sh
decode() {
    "$1" -hide_banner -nostats -loglevel quiet -threads 1 \
        -f image2pipe -c:v jpeg2000 -i corpus.j2kpipe \
        -f framemd5 - 2>/dev/null \
      | grep -v '^#' | awk -F', ' '{print $6}'
}

decode /path/to/base/ffmpeg    > base.md5
decode /path/to/patched/ffmpeg > patched.md5
cmp base.md5 patched.md5
```

`corpus.j2kpipe` is a concatenation of JPEG 2000 codestreams. The check
compares the decoded samples after FFmpeg's colour conversion, so a difference
anywhere in tier-1, tier-2, DWT or output is visible.

The style gate uses 44 small synthetic streams in `tests/j2kstyles/`. It covers
coding styles, gray and colour images, odd dimensions and origins, several
decomposition levels, and reversible 5/3. Each stream has a stored frame hash,
and each 5/3 stream is compared with its source PPM or PGM.

```sh
tests/j2kstyles.sh /path/to/ffmpeg
```

## Benchmark

CI does not run the benchmark. The workflow builds the app and runs correctness
checks; timing on a shared runner is not comparable between runs. Run the
benchmark on your own machine.

`bench/make-clip.sh` encodes a synthetic clip with the same geometry and
transform as the DCP excerpt:

```sh
bench/make-clip.sh clip.mxf 10 4096x1714
```

That produces 240 frames at 24 fps, 4K scope, `yuv444p12le`, irreversible 9/7,
with SOP and EPH markers, wrapped in MXF. To measure real programme material,
cut a stream copy from a DCP picture MXF instead. Do not re-encode it.

`bench/run-one.sh` runs one player and decoder pair:

```sh
mpv --no-config --no-audio --vd=jpeg2000 --vo=null --ao=null --untimed \
    --vd-lavc-threads=8 --frames=240 --really-quiet clip.mxf
```

`--no-config` keeps the user's mpv configuration out of the measurement.
`--vo=null` and `--ao=null` remove presentation and audio. `--untimed` decodes
as fast as the machine allows.

`bench/ab.sh` runs every candidate once per round, in the same order, for five
rounds. It reports the minimum real and user time per candidate, frames per
second from the real time, and speedup relative to the first candidate.

Minimum is used because scheduling, thermal and background-load noise only add
time. The raw rows stay in `bench-results.tsv` so the distribution can be
checked.

For stable numbers, run on AC power with no other heavy work, and let the
machine cool between rounds if the fan ramps up. Do not compare runs made with
different thread counts or different clips.

## Baseline caveat

The installed Homebrew mpv is a different distribution with a different
FFmpeg revision. Comparing it with this app measures the two distributions, not
the patch series alone. `docs/RESULTS.md` also reports the same-source FFmpeg
comparison, where both binaries come from the same commit and differ only by
the patches.

## Repository size

No DCP or large media is stored here. The 44 style streams and their sources
are 5.5 MB. The benchmark clip is generated locally or cut from media you
already own.
