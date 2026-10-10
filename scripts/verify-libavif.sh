#!/usr/bin/env bash
#
# Verifies an avifenc/avifdec pair, either built by scripts/build-libavif.sh or
# repackaged from the libavif release.
#
#   bash scripts/verify-libavif.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   --version / --help assertions plus real encode+decode smoke tests of
#         the container features the tools are published for (must run on the
#         target platform)
#   all   both (default)
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

AVIFENC="./avifenc-$TARGET$EXE"
AVIFDEC="./avifdec-$TARGET$EXE"
[ -f "$AVIFENC" ] || { echo "missing $AVIFENC" >&2; exit 1; }
[ -f "$AVIFDEC" ] || { echo "missing $AVIFDEC" >&2; exit 1; }
chmod +x "$AVIFENC" "$AVIFDEC" 2>/dev/null || true

# The test images are written byte by byte with tr and printf.
export LC_ALL=C
# Git Bash on Windows rewrites arguments that look like POSIX paths; values
# such as --cicp 9/16/9 must reach the tools untouched.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

msg()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$*"; }

# No `echo ... | grep -q` in this script: grep closes the pipe early, the
# writer takes SIGPIPE, and `set -o pipefail` turns that into a spurious failure.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Linkage
# ---------------------------------------------------------------------------

find_objdump() {
  for candidate in objdump llvm-objdump; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

assert_linkage() {
  bin="$1"
  case "$TARGET" in
    linux-*)
      description="$(file "$bin")"
      contains "$description" 'statically linked' || contains "$description" 'static-pie linked' \
        || fail "$bin is not statically linked: $description"
      # ldd exits non-zero on a static binary, hence no `set -e` trip here.
      if ldd "$bin" 2>/dev/null | grep -q '=>'; then
        fail "$bin has dynamic dependencies: $(ldd "$bin" 2>/dev/null)"
      fi
      ok "$bin is fully static"
      ;;
    osx-arm64)
      # macOS has no static libSystem; assert only system dylibs are referenced.
      deps="$(otool -L "$bin" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*(.*$//' \
              | grep -v '^/usr/lib/' | grep -v '^/System/Library/' || true)"
      [ -z "$deps" ] || fail "$bin links non-system dylibs: $deps"
      ok "$bin links only system dylibs"
      ;;
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $bin"
      imports="$("$objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $bin"
      bad=""
      for dll in $imports; do
        # The libavif release is built with MSVC against the dynamic CRT:
        # kernel32, the UCRT (a Windows component since Windows 10) and the
        # Visual C++ runtime. Anything else means a dependency leaked in
        # dynamically -- a codec DLL or the C++ standard library (msvcp140).
        case "$dll" in
          kernel32.dll|ucrtbase.dll|api-ms-win-*|vcruntime*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Version, codecs and command-line options
# ---------------------------------------------------------------------------

# Both tools print the same banner, for instance:
#   Version: 1.4.2 (dav1d [dec]:1.5.3-0-gb546257, aom [enc]:3.14.1)
assert_version() {
  tool="$1"; bin="$2"
  banner="$("$bin" --version 2>&1)" || fail "$tool --version failed: $banner"
  banner="${banner%%$'\n'*}"
  banner="${banner%$'\r'}"
  echo "  $tool: $banner"

  if [ -z "$LIBAVIF_VERSION" ]; then
    echo "  LIBAVIF_VERSION is not set; skipping the $tool version check"
  else
    case "$banner" in
      "Version: $LIBAVIF_VERSION ("*) ok "$tool reports version $LIBAVIF_VERSION" ;;
      *) fail "$tool does not report version $LIBAVIF_VERSION: $banner" ;;
    esac
  fi

  # libaom is the encoder that covers lossless, 4:4:4, 4:2:2, 4:0:0, 10/12-bit
  # and grids.
  contains "$banner" 'aom [enc' || fail "$tool has no libaom encoder: $banner"
  contains "$banner" 'dav1d [dec]' || contains "$banner" 'aom [enc/dec]' \
    || fail "$tool has no AV1 decoder: $banner"
  ok "$tool has an AV1 encoder (libaom) and an AV1 decoder"
}

assert_options() {
  tool="$1"; bin="$2"; shift 2
  help="$("$bin" --help 2>&1)" || fail "$tool --help failed"
  for option in "$@"; do
    contains "$help" "$option" || fail "$tool --help does not list $option"
  done
  ok "$tool --help lists $*"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# Prints <count> bytes of value <octal>.
bytes() { head -c "$1" /dev/zero | tr '\000' "\\$2"; }

# Prints a <width>x<height> plane: a horizontal ramp starting at 0 and growing
# by <step>, so that the lossless round-trips have something to get wrong.
ramp() {
  width="$1"; height="$2"; step="$3"
  row=""
  x=0
  while [ "$x" -lt "$width" ]; do
    printf -v octal '%03o' $(((x * step) % 256))
    row="$row\\$octal"
    x=$((x + 1))
  done
  y=0
  while [ "$y" -lt "$height" ]; do
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# enc <label> <avifenc arguments...>: the last argument is the output file.
enc() {
  label="$1"; shift
  eval "out=\${$#}"
  rm -f "$out"
  "$AVIFENC" --speed 10 "$@" > avifenc.log 2>&1 || { cat avifenc.log >&2; fail "$label: avifenc failed"; }
  [ -s "$out" ] || fail "$label: avifenc produced no file"
}

# dec <label> <avifdec arguments...>: the last argument is the output file.
dec() {
  label="$1"; shift
  eval "out=\${$#}"
  rm -f "$out"
  "$AVIFDEC" "$@" > avifdec.log 2>&1 || { cat avifdec.log >&2; fail "$label: avifdec failed"; }
  [ -s "$out" ] || fail "$label: avifdec produced no file"
}

# expect_info <file> <text>...: every text is in `avifdec --info`, spaces removed.
expect_info() {
  file="$1"; shift
  info="$("$AVIFDEC" --info "$file" 2>&1 | tr -d ' \r')" || { echo "$info" >&2; fail "avifdec --info $file failed"; }
  for text in "$@"; do
    contains "$info" "$text" || { echo "$info" >&2; fail "$file: avifdec --info does not report '$text'"; }
  done
  ok "$file: $*"
}

expect_png() {
  [ "$(head -c 4 "$1" | tail -c 3)" = "PNG" ] || fail "$1 is not a PNG file"
}

# expect_y4m <file> <width> <height> <yuv format> <depth>: the header announces
# the format and the file holds exactly one frame with every plane.
expect_y4m() {
  file="$1"; width="$2"; height="$3"; yuv="$4"; depth="$5"
  case "$yuv" in
    444) samples=$((width * height * 3)); chroma="C444" ;;
    422) samples=$((width * height * 2)); chroma="C422" ;;
    420) samples=$((width * height * 3 / 2)); chroma="C420" ;;
    400) samples=$((width * height)); chroma="Cmono" ;;
  esac
  case "$yuv-$depth" in
    420-8) chroma="C420jpeg" ;;
    400-8) ;;
    400-*) chroma="$chroma$depth" ;;
    *-8) ;;
    *) chroma="${chroma}p$depth" ;;
  esac
  if [ "$depth" -gt 8 ]; then samples=$((samples * 2)); fi

  read -r header < "$file" || true
  contains "$header " "YUV4MPEG2 W$width H$height " || fail "$file: unexpected y4m header: $header"
  contains "$header " " $chroma " || fail "$file: expected $chroma in the y4m header: $header"
  # header line, then "FRAME\n", then the planes
  expected=$((${#header} + 1 + 6 + samples))
  actual=$(($(wc -c < "$file")))
  [ "$actual" -eq "$expected" ] || fail "$file: expected $expected bytes, got $actual"
}

# same_pixels <y4m> <y4m> <plane bytes>: the last frame of both files is identical.
same_pixels() {
  tail -c "$3" "$1" > expected.raw
  tail -c "$3" "$2" > actual.raw
  cmp -s expected.raw actual.raw
}

smoke_test() {
  workdir="smoke-libavif-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  AVIFENC="../$(basename "$AVIFENC")"
  AVIFDEC="../$(basename "$AVIFDEC")"

  msg "test images"
  # 128x128: the smallest image that splits into a 2x2 grid (cells are at least 64x64).
  {
    printf 'YUV4MPEG2 W128 H128 F25:1 Ip A1:1 C444\nFRAME\n'
    ramp 128 128 2; ramp 128 128 1; bytes 16384 200
  } > still.y4m
  {
    printf 'YUV4MPEG2 W128 H128 F25:1 Ip A1:1 C444alpha\nFRAME\n'
    ramp 128 128 2; ramp 128 128 1; bytes 16384 200; ramp 128 128 3
  } > alpha.y4m
  # Three frames that only differ by their luma.
  printf 'YUV4MPEG2 W64 H64 F10:1 Ip A1:1 C444\n' > sequence.y4m
  index=0
  for luma in 040 100 140; do
    { bytes 4096 "$luma"; bytes 4096 200; bytes 4096 200; } > "source-frame-$index.raw"
    printf 'FRAME\n' >> sequence.y4m
    cat "source-frame-$index.raw" >> sequence.y4m
    index=$((index + 1))
  done
  # The smallest payloads libavif accepts: an empty TIFF directory, an XMP
  # packet, and an ICC header for an RGB profile without any tag.
  printf 'II*\000\010\000\000\000\000\000\000\000\000\000' > exif.bin
  printf '<x:xmpmeta xmlns:x="adobe:ns:meta/"></x:xmpmeta>' > xmp.xml
  {
    printf '\000\000\000\204'; bytes 4 000; printf '\004\060\000\000mntrRGB XYZ '
    bytes 12 000; printf 'acsp'; bytes 88 000; bytes 4 000
  } > profile.icc
  ok "wrote the y4m inputs and the Exif/XMP/ICC payloads"

  msg "y4m input, lossless, y4m and PNG output"
  enc "lossless" --lossless still.y4m lossless.avif
  expect_info lossless.avif "Resolution:128x128" "BitDepth:8" "Format:YUV444" "Alpha:Absent"
  dec "y4m output" lossless.avif lossless.y4m
  expect_y4m lossless.y4m 128 128 444 8
  same_pixels still.y4m lossless.y4m 49152 || fail "the lossless round-trip changed the planes"
  ok "the lossless round-trip is bit-exact"
  dec "PNG output" lossless.avif still.png
  expect_png still.png
  ok "avifdec wrote still.png"

  msg "PNG input, --depth and --yuv"
  for depth in 8 10 12; do
    for yuv in 444 422 420 400; do
      name="png-$depth-$yuv"
      enc "$name" --depth "$depth" --yuv "$yuv" still.png "$name.avif"
      expect_info "$name.avif" "Resolution:128x128" "BitDepth:$depth" "Format:YUV$yuv"
      dec "$name y4m" "$name.avif" "$name.y4m"
      expect_y4m "$name.y4m" 128 128 "$yuv" "$depth"
      dec "$name PNG" --depth 16 "$name.avif" "$name.png"
      expect_png "$name.png"
    done
  done

  msg "color information"
  enc "cicp" --cicp 9/16/9 --range limited --depth 10 still.png cicp.avif
  expect_info cicp.avif "ColorPrimaries:9" "TransferChar.:16" "MatrixCoeffs.:9" "Range:Limited"
  enc "range" --range full still.png full.avif
  expect_info full.avif "Range:Full"

  msg "grid"
  enc "grid" --grid 2x2 still.y4m grid.avif
  grep -q -a 'grid' grid.avif || fail "grid.avif has no grid item"
  expect_info grid.avif "Resolution:128x128"
  dec "grid" grid.avif grid.y4m
  expect_y4m grid.y4m 128 128 444 8
  enc "lossless grid" --lossless --grid 2x2 still.y4m grid-lossless.avif
  dec "lossless grid" grid-lossless.avif grid-lossless.y4m
  same_pixels still.y4m grid-lossless.y4m 49152 || fail "the lossless grid round-trip changed the planes"
  ok "the 2x2 grid is reassembled bit-exactly"

  msg "transformations"
  enc "transformations" --irot 1 --imir 0 --clap 64,1,64,1,0,1,0,1 still.png transformations.avif
  expect_info transformations.avif "W:64/1,H:64/1,hOff:0/1,vOff:0/1" "X:32,Y:32,W:64,H:64" \
    "irot(Rotation):1" "imir(Mirror):0"
  dec "transformations" transformations.avif transformations.png
  expect_png transformations.png

  msg "metadata"
  enc "metadata" --exif exif.bin --xmp xmp.xml --icc profile.icc still.png metadata.avif
  expect_info metadata.avif "ICCProfile:Present(132bytes)" "XMPMetadata:Present(48bytes)" "ExifMetadata:Present(14bytes)"
  dec "metadata" metadata.avif metadata.png
  expect_png metadata.png

  msg "alpha"
  enc "alpha" --lossless alpha.y4m alpha.avif
  expect_info alpha.avif "Alpha:Notpremultiplied"
  dec "alpha" alpha.avif alpha.png
  expect_png alpha.png
  enc "premultiplied alpha" --premultiply alpha.png premultiplied.avif
  expect_info premultiplied.avif "Alpha:Premultiplied"
  dec "premultiplied alpha" premultiplied.avif premultiplied.png
  expect_png premultiplied.png

  msg "image sequence"
  enc "sequence" --lossless --timescale 10 --repetition-count 2 sequence.y4m sequence.avif
  expect_info sequence.avif "RepeatCount:2" "10timescalespersecond" "3frames"
  for index in 0 1 2; do
    dec "frame $index" --index "$index" sequence.avif "frame-$index.y4m"
    expect_y4m "frame-$index.y4m" 64 64 444 8
    same_pixels "source-frame-$index.raw" "frame-$index.y4m" 12288 || fail "--index $index did not decode frame $index"
  done
  ok "--index selects each of the 3 frames"
  # avifdec inserts the frame number: all.y4m becomes all-0000000000.y4m, ...
  "$AVIFDEC" --index all sequence.avif all.y4m > avifdec.log 2>&1 || { cat avifdec.log >&2; fail "all frames: avifdec failed"; }
  for index in 0 1 2; do
    [ -s "all-000000000$index.y4m" ] || fail "--index all did not write frame $index"
    same_pixels "frame-$index.y4m" "all-000000000$index.y4m" 12288 || fail "--index all: frame $index differs"
  done
  ok "--index all writes the 3 frames"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$AVIFENC"
    assert_linkage "$AVIFDEC"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version avifenc "$AVIFENC"
    assert_version avifdec "$AVIFDEC"
    msg "command-line options"
    assert_options avifenc "$AVIFENC" --grid --irot --imir --clap --exif --xmp --icc --cicp \
      --premultiply --lossless --depth --yuv --range --timescale --repetition-count y4m png
    assert_options avifdec "$AVIFDEC" --info --index --depth y4m png
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
