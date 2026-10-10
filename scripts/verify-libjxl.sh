#!/usr/bin/env bash
#
# Verifies the cjxl/djxl/jxlinfo/jxl_from_tree set built by scripts/build-libjxl.sh.
#
#   bash scripts/verify-libjxl.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   --version assertions plus real encode+decode smoke tests of what the
#         tools are published for (must run on the target platform)
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

CJXL="./cjxl-$TARGET$EXE"
DJXL="./djxl-$TARGET$EXE"
JXLINFO="./jxlinfo-$TARGET$EXE"
JXL_FROM_TREE="./jxl_from_tree-$TARGET$EXE"
for bin in "$CJXL" "$DJXL" "$JXLINFO" "$JXL_FROM_TREE"; do
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done

# The test images are written byte by byte with printf.
export LC_ALL=C
# Git Bash on Windows rewrites arguments that look like POSIX paths.
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

# The llvm-mingw objdump comes first: the Windows binaries are checked on the
# Linux machine that cross-compiles them.
find_objdump() {
  for candidate in x86_64-w64-mingw32-objdump objdump llvm-objdump; do
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
        # DLLs that ship with Windows itself; ucrtbase and the api-ms-win-crt-*
        # stubs are the UCRT, a Windows component since Windows 10. Anything
        # else means a dependency leaked in dynamically -- most likely
        # libc++.dll, libunwind.dll or libwinpthread-1.dll.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|shell32.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Version and command-line options
# ---------------------------------------------------------------------------

# cjxl and djxl print the same banner, for instance:
#   cjxl v0.12.0 0.12.0 [_NEON_,NEON_WITHOUT_AES]
# jxlinfo and jxl_from_tree have no --version.
assert_version() {
  tool="$1"; bin="$2"
  banner="$("$bin" --version 2>&1)" || fail "$tool --version failed: $banner"
  banner="${banner%%$'\n'*}"
  banner="${banner%$'\r'}"
  echo "  $tool: $banner"

  if [ -z "$JXL_VERSION" ]; then
    echo "  JXL_VERSION is not set; skipping the $tool version check"
  else
    case "$banner" in
      "$tool v$JXL_VERSION "*) ok "$tool reports version $JXL_VERSION" ;;
      *) fail "$tool does not report version $JXL_VERSION: $banner" ;;
    esac
  fi
}

# assert_options <tool> <binary> <option>...: the full help lists every option.
assert_options() {
  tool="$1"; bin="$2"; shift 2
  help="$("$bin" --help -v -v -v -v 2>&1)" || fail "$tool --help failed"
  for option in "$@"; do
    contains "$help" "$option" || fail "$tool --help does not list $option"
  done
  ok "$tool --help lists $*"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# Prints the samples of a <width>x<height> image with <channels> channels: a
# horizontal ramp with a different step for every channel, so that the lossless
# round-trips have something to get wrong.
pixels() {
  width="$1"; height="$2"; channels="$3"
  row=""
  x=0
  while [ "$x" -lt "$width" ]; do
    channel=0
    while [ "$channel" -lt "$channels" ]; do
      printf -v octal '%03o' $(((x * (channel * 2 + 3) + channel * 40) % 256))
      row="$row\\$octal"
      channel=$((channel + 1))
    done
    x=$((x + 1))
  done
  y=0
  while [ "$y" -lt "$height" ]; do
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# run <label> <output file> <command...>: the command succeeds and writes the file.
run() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$label: $(basename "$1") failed"; }
  [ -s "$out" ] || { cat tool.log >&2; fail "$label: $(basename "$1") produced no file"; }
}

# expect_info <file> <text>...: every text is in the output of `jxlinfo -v`.
expect_info() {
  file="$1"; shift
  info="$("$JXLINFO" -v "$file" 2>&1 | tr -d '\r')" || { echo "$info" >&2; fail "jxlinfo $file failed"; }
  for text in "$@"; do
    contains "$info" "$text" || { echo "$info" >&2; fail "$file: jxlinfo does not report '$text'"; }
  done
  ok "$file: $*"
}

# same_pixels <file> <file> <sample bytes>: both files end with the same samples.
# The headers are left out: the tools are free to lay them out differently.
same_pixels() {
  tail -c "$3" "$1" > expected.raw
  tail -c "$3" "$2" > actual.raw
  [ "$(($(wc -c < expected.raw)))" -eq "$3" ] || return 1
  cmp -s expected.raw actual.raw
}

expect_png() {
  [ "$(head -c 4 "$1" | tail -c 3)" = "PNG" ] || fail "$1 is not a PNG file"
}

smoke_test() {
  workdir="smoke-libjxl-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  CJXL="../$(basename "$CJXL")"
  DJXL="../$(basename "$DJXL")"
  JXLINFO="../$(basename "$JXLINFO")"
  JXL_FROM_TREE="../$(basename "$JXL_FROM_TREE")"

  msg "test images"
  { printf 'P6\n64 48\n255\n'; pixels 64 48 3; } > still.ppm
  {
    printf 'P7\nWIDTH 64\nHEIGHT 48\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n'
    pixels 64 48 4
  } > alpha.pam
  # A 16x16 baseline JPEG (4:2:0, optimized Huffman tables).
  base64 -d > source.jpg <<'EOF'
/9j/4AAQSkZJRgABAgAAAQABAAD/2wBDAAgQEBMQExYWFhYWFhoYGhsbGxoaGhobGxsdHR0iIiId
HR0bGx0dICAiIiUmJSMjIiMmJigoKDAwLi44ODpFRVP/xABYAAEBAQAAAAAAAAAAAAAAAAAFBgcB
AQAAAAAAAAAAAAAAAAAAAAYQAAMBAQAAAAAAAAAAAAAAAAABAhEDEQABBQEBAQAAAAAAAAAAAAAB
AAQCBRNxEhH/wAARCAAQABADASIAAhEAAxEA/9oADAMBAAIRAxEAPwDOesAjWFVS1AHWMGFE+9DK
R4mFyz+HWIX/2Q==
EOF
  [ "$(($(wc -c < source.jpg)))" -eq 238 ] || fail "source.jpg was not written correctly"
  ok "wrote the PPM, PAM and JPEG inputs"

  msg "PPM input, lossless, PPM output"
  run "lossless" lossless.jxl "$CJXL" still.ppm lossless.jxl --distance=0 --effort=3
  expect_info lossless.jxl "JPEG XL image, 64x48, (possibly) lossless, 8-bit RGB" "Have animation: 0"
  run "lossless" lossless.ppm "$DJXL" lossless.jxl lossless.ppm
  same_pixels still.ppm lossless.ppm 9216 || fail "the lossless round-trip changed the pixels"
  ok "the lossless round-trip is bit-exact"

  msg "alpha"
  run "alpha" alpha.jxl "$CJXL" alpha.pam alpha.jxl --distance=0 --effort=3
  expect_info alpha.jxl "64x48, (possibly) lossless, 8-bit RGB+Alpha"
  run "alpha" alpha-decoded.pam "$DJXL" alpha.jxl alpha-decoded.pam
  same_pixels alpha.pam alpha-decoded.pam 12288 || fail "the lossless round-trip changed the pixels or the alpha channel"
  ok "the lossless round-trip with alpha is bit-exact"

  msg "PNG output and input"
  run "PNG output" still.png "$DJXL" lossless.jxl still.png
  expect_png still.png
  run "PNG input" png.jxl "$CJXL" still.png png.jxl --distance=0
  run "PNG input" png.ppm "$DJXL" png.jxl png.ppm
  same_pixels still.ppm png.ppm 9216 || fail "the PNG round-trip changed the pixels"
  ok "djxl writes a PNG that cjxl reads back bit-exactly"

  msg "lossy (VarDCT)"
  run "lossy" lossy.jxl "$CJXL" still.ppm lossy.jxl --distance=1
  expect_info lossy.jxl "JPEG XL image, 64x48, lossy, 8-bit RGB"
  run "lossy" lossy.ppm "$DJXL" lossy.jxl lossy.ppm
  [ "$(($(wc -c < lossy.ppm)))" -eq "$(($(wc -c < still.ppm)))" ] || fail "lossy.ppm is not a 64x48 8-bit PPM"
  ok "djxl decodes the lossy file to 64x48"

  msg "container"
  [ "$(head -c 2 lossless.jxl | od -An -tx1 | tr -d ' \n')" = "ff0a" ] || fail "lossless.jxl is not a bare codestream"
  run "container" container.jxl "$CJXL" still.ppm container.jxl --distance=0 --container=1
  expect_info container.jxl "JPEG XL file format container" 'type: "jxlc"'
  run "container" container.ppm "$DJXL" container.jxl container.ppm
  same_pixels still.ppm container.ppm 9216 || fail "the container round-trip changed the pixels"
  ok "cjxl writes a bare codestream by default and a container with --container=1"

  # No libjpeg is linked: this is the transcoding libjxl implements itself.
  msg "lossless JPEG transcoding"
  run "JPEG transcoding" jpeg.jxl "$CJXL" source.jpg jpeg.jxl --lossless_jpeg=1
  expect_info jpeg.jxl "JPEG XL image, 16x16" 'type: "jbrd"' "JPEG bitstream reconstruction data available"
  run "JPEG reconstruction" reconstructed.jpg "$DJXL" jpeg.jxl reconstructed.jpg
  cmp -s source.jpg reconstructed.jpg || fail "djxl did not reconstruct the original JPEG file"
  ok "djxl reconstructs the JPEG file byte for byte"
  run "JPEG to pixels" jpeg.ppm "$DJXL" jpeg.jxl jpeg.ppm
  # "P6\n16 16\n255\n", then 16x16 RGB samples
  [ "$(($(wc -c < jpeg.ppm)))" -eq $((13 + 768)) ] || fail "jpeg.ppm is not a 16x16 8-bit PPM"
  ok "djxl decodes the transcoded JPEG to pixels"

  msg "jxl_from_tree: tree"
  # The red channel is 200 everywhere, the green and blue ones are 100.
  printf 'Width 16\nHeight 16\nBitdepth 8\nif c > 0\n  - Set 100\n  - Set 200\n' > solid.txt
  run "tree" solid.jxl "$JXL_FROM_TREE" solid.txt solid.jxl
  expect_info solid.jxl "JPEG XL image, 16x16, (possibly) lossless, 8-bit RGB"
  run "tree" solid.ppm "$DJXL" solid.jxl solid.ppm
  pixel=0
  while [ "$pixel" -lt 256 ]; do printf '\310\144\144'; pixel=$((pixel + 1)); done > solid-expected.raw
  same_pixels solid-expected.raw solid.ppm 768 || fail "solid.jxl does not decode to the pixels of its tree"
  ok "djxl decodes the pixels the tree describes"

  msg "jxl_from_tree: spline"
  # The 32 DCT coefficients of X, Y, B and of the thickness, then the control points.
  zeros='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
  {
    printf 'Width 64\nHeight 64\nBitdepth 8\nXYB\n'
    printf 'Spline\n0.3 %s\n0.3 %s\n0.3 %s\n2.0 %s\n8 8\n32 56\n56 8\nEndSpline\n' "$zeros" "$zeros" "$zeros" "$zeros"
    printf -- '- Set 0\n'
  } > spline.txt
  printf 'Width 64\nHeight 64\nBitdepth 8\nXYB\n- Set 0\n' > no-spline.txt
  run "spline" spline.jxl "$JXL_FROM_TREE" spline.txt spline.jxl
  run "spline" spline.ppm "$DJXL" spline.jxl spline.ppm
  run "no spline" no-spline.jxl "$JXL_FROM_TREE" no-spline.txt no-spline.jxl
  run "no spline" no-spline.ppm "$DJXL" no-spline.jxl no-spline.ppm
  [ "$(($(wc -c < spline.ppm)))" -eq "$(($(wc -c < no-spline.ppm)))" ] || fail "spline.ppm is not a 64x64 8-bit PPM"
  if cmp -s spline.ppm no-spline.ppm; then fail "the spline was not drawn"; fi
  ok "djxl draws the spline"

  msg "jxl_from_tree: animation, APNG output and input"
  printf 'Width 16\nHeight 16\nBitdepth 8\nAnimation\nDuration 100\nNotLast\n- Set 50\nDuration 200\n- Set 150\n' > animation.txt
  run "animation" animation.jxl "$JXL_FROM_TREE" animation.txt animation.jxl
  expect_info animation.jxl "JPEG XL animation, 16x16" "Ticks per second (numerator / denominator): 1000 / 1" \
    "duration: 100.0 ms" "duration: 200.0 ms"
  # djxl inserts the frame number: frame.ppm becomes frame.ppm-0.ppm, ...
  "$DJXL" animation.jxl frame.ppm --output_frames > tool.log 2>&1 || { cat tool.log >&2; fail "all frames: djxl failed"; }
  index=0
  for octal in 062 226; do
    [ -s "frame.ppm-$index.ppm" ] || fail "--output_frames did not write frame $index"
    pixel=0
    while [ "$pixel" -lt 768 ]; do printf "\\$octal"; pixel=$((pixel + 1)); done > "frame-$index-expected.raw"
    same_pixels "frame-$index-expected.raw" "frame.ppm-$index.ppm" 768 || fail "--output_frames: frame $index has the wrong pixels"
    index=$((index + 1))
  done
  ok "--output_frames writes the 2 frames"
  run "APNG output" animation.apng "$DJXL" animation.jxl animation.apng
  expect_png animation.apng
  grep -q -a 'acTL' animation.apng || fail "animation.apng has no animation control chunk"
  run "APNG input" animation-apng.jxl "$CJXL" animation.apng animation-apng.jxl --distance=0
  expect_info animation-apng.jxl "JPEG XL animation, 16x16" "duration: 100.0 ms" "duration: 200.0 ms"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$CJXL"
    assert_linkage "$DJXL"
    assert_linkage "$JXLINFO"
    assert_linkage "$JXL_FROM_TREE"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version cjxl "$CJXL"
    assert_version djxl "$DJXL"
    msg "command-line options"
    assert_options cjxl "$CJXL" --distance --effort --modular --lossless_jpeg --container --compress_boxes \
      --modular_predictor --modular_group_size --patches --noise --gaborish --epf --resampling --progressive_dc
    # APNG: the tools are linked with libpng.
    assert_options djxl "$DJXL" --bits_per_sample --output_frames --no_coalescing --color_space --icc_out APNG
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
