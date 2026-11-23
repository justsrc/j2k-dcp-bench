#!/bin/bash
# Coding-style regression gate for the FFmpeg JPEG 2000 decoder.
# usage: ./j2kstyles.sh /path/to/ffmpeg
#
# Compares every stream's framemd5 against refs/ and, for the reversible 5/3
# streams, against the source pixels. The streams are synthetic and small.
set -u

FF=${1:?usage: j2kstyles.sh FFMPEG}
case "$FF" in
    /*) ;;
    *) FF="$PWD/$FF" ;;
esac
[[ -x "$FF" ]] || { echo "not executable: $FF" >&2; exit 2; }

here=$(cd "$(dirname "$0")/j2kstyles" && pwd)
cd "$here" || exit 1
shopt -s nullglob
streams=(*.j2k)
refs=(refs/*.md5)
[[ ${#streams[@]} -gt 0 ]] || {
    echo "no streams found in $here" >&2
    exit 2
}
[[ ${#refs[@]} -gt 0 ]] || {
    echo "no reference hashes found in $here/refs" >&2
    exit 2
}
fail=0

for f in "${streams[@]}"; do
    [[ -f "refs/$f.md5" ]] || continue
    got=$("$FF" -hide_banner -nostats -loglevel quiet -threads 1 \
            -f image2pipe -c:v jpeg2000 -i "$f" -f framemd5 - 2>/dev/null \
          | grep -v '^#' | awk -F', ' '{print $6}' | tr '\n' ' ' \
          | sed 's/ $//')
    want=$(cat "refs/$f.md5")
    if [[ "$got" != "$want" ]]; then
        echo "FAIL $f"
        fail=1
    fi
done

# Reversible 5/3 streams must reproduce the source pixels.
python3 - "$FF" <<'PY' || fail=1
import glob
import os
import subprocess
import sys

ff = sys.argv[1]


def read_pnm(path):
    data = open(path, 'rb').read()
    magic, size, maximum, pixels = data.split(b'\n', 3)
    if magic not in (b'P5', b'P6'):
        raise SystemExit(f'unsupported source format: {path}')
    width, height = map(int, size.split())
    return width, height, int(maximum), pixels


for src in glob.glob('src*.ppm') + glob.glob('src*.pgm'):
    width, height, maximum, pixels = read_pnm(src)
    big = maximum > 255
    channels = 3 if src.endswith('.ppm') else 1
    base = os.path.splitext(src)[0]
    for stream in sorted(glob.glob(f'll_{base}_m*.j2k')):
        pix_fmt = ('rgb24' if channels == 3 and not big else
                   'gray' if channels == 1 and not big else
                   'rgb48le' if channels == 3 else 'gray16le')
        out = subprocess.run(
            [ff, '-hide_banner', '-nostats', '-loglevel', 'quiet',
             '-threads', '1', '-f', 'image2pipe', '-c:v', 'jpeg2000',
             '-i', stream, '-f', 'rawvideo', '-pix_fmt', pix_fmt, '-'],
            capture_output=True).stdout
        if not big:
            ok = out == pixels
        elif len(out) != len(pixels):
            ok = False
        else:
            ok = True
            # The source is big-endian at its own precision. FFmpeg returns
            # 16-bit little-endian after scaling, so compare after reversing
            # the scale.
            shift = 16 - maximum.bit_length()
            for i in range(0, len(pixels), 2):
                got = int.from_bytes(out[i:i + 2], 'little') >> shift
                want = int.from_bytes(pixels[i:i + 2], 'big')
                if got != want:
                    ok = False
                    break
        if not ok:
            print(f'SOURCE-MISMATCH {stream} '
                  f'({len(out)} vs {len(pixels)} bytes)')
            sys.exit(1)

print('source-exact: ok')
PY

if [[ $fail -eq 0 ]]; then
    echo "ALL PASS"
fi
exit $fail
