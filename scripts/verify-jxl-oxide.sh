#!/usr/bin/env bash
#
# Verifies the jxl-oxide binary built by scripts/build-jxl-oxide.sh.
#
#   bash scripts/verify-jxl-oxide.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   --version assertion plus smoke tests (must run on the target platform)
#   all   both (default)
#
# jxl-oxide only decodes, and it is published to cross-check libjxl. So the
# smoke tests need the cjxl, djxl and jxl_from_tree of the same target next to
# it (scripts/build-libjxl.sh): they write the files jxl-oxide decodes, and
# djxl gives the pixels to compare with.
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

JXL_OXIDE="./jxl-oxide-$TARGET$EXE"
[ -f "$JXL_OXIDE" ] || { echo "missing $JXL_OXIDE" >&2; exit 1; }
chmod +x "$JXL_OXIDE" 2>/dev/null || true

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
        # DLLs that ship with Windows itself, the ones the Rust standard
        # library imports. The C runtime is linked statically, so the Visual
        # C++ runtime (vcruntime140.dll), which is not a part of Windows, must
        # not be there.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|userenv.dll|ws2_32.dll|bcrypt.dll|bcryptprimitives.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

# For instance: jxl-oxide-cli 0.12.6
assert_version() {
  banner="$("$JXL_OXIDE" --version 2>&1)" || fail "jxl-oxide --version failed: $banner"
  banner="${banner%%$'\n'*}"
  banner="${banner%$'\r'}"
  echo "  jxl-oxide: $banner"

  if [ -z "$JXL_OXIDE_VERSION" ]; then
    echo "  JXL_OXIDE_VERSION is not set; skipping the version check"
  else
    [ "$banner" = "jxl-oxide-cli $JXL_OXIDE_VERSION" ] || fail "jxl-oxide does not report version $JXL_OXIDE_VERSION: $banner"
    ok "jxl-oxide reports version $JXL_OXIDE_VERSION"
  fi
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# Prints the samples of a <width>x<height> image with <channels> channels: a
# horizontal ramp with a different step for every channel.
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

# oxide_decode <label> <jxl> <pnm>: decodes with jxl-oxide. It writes PNG, so
# the PNG is turned into a PNM file by a lossless trip through cjxl and djxl.
oxide_decode() {
  label="$1"; jxl="$2"; pnm="$3"
  run "$label" "$pnm.png" "$JXL_OXIDE" decode "$jxl" --output "$pnm.png" --output-format png8 --quiet
  [ "$(head -c 4 "$pnm.png" | tail -c 3)" = "PNG" ] || fail "$label: jxl-oxide did not write a PNG file"
  run "$label" "$pnm.jxl" "$CJXL" "$pnm.png" "$pnm.jxl" --distance=0 --effort=1
  run "$label" "$pnm" "$DJXL" "$pnm.jxl" "$pnm"
}

# max_difference <file> <file> <sample bytes>: prints the largest difference
# between the samples both files end with.
max_difference() {
  tail -c "$3" "$1" > expected.raw
  tail -c "$3" "$2" > actual.raw
  [ "$(($(wc -c < expected.raw)))" -eq "$3" ] || fail "$1 holds less than $3 bytes"
  [ "$(($(wc -c < actual.raw)))" -eq "$3" ] || fail "$2 holds less than $3 bytes"
  # cmp -l prints one line per difference: the offset and the two bytes, in
  # octal. It exits with 1 when there is any.
  { cmp -l expected.raw actual.raw || true; } | awk '
    function octal(text,    value, i) {
      value = 0
      for (i = 1; i <= length(text); i++) value = value * 8 + substr(text, i, 1)
      return value
    }
    {
      difference = octal($2) - octal($3)
      if (difference < 0) difference = -difference
      if (difference > max) max = difference
    }
    END { print max + 0 }'
}

# expect_close <label> <file> <file> <sample bytes> <tolerance>
expect_close() {
  difference="$(max_difference "$2" "$3" "$4")"
  [ "$difference" -le "$5" ] || fail "$1: jxl-oxide and djxl differ by $difference, more than $5"
  ok "$1: jxl-oxide and djxl differ by at most $difference"
}

smoke_test() {
  CJXL="./cjxl-$TARGET$EXE"
  DJXL="./djxl-$TARGET$EXE"
  JXL_FROM_TREE="./jxl_from_tree-$TARGET$EXE"
  for bin in "$CJXL" "$DJXL" "$JXL_FROM_TREE"; do
    [ -f "$bin" ] || fail "missing $bin, which the smoke tests write and compare their files with"
    chmod +x "$bin" 2>/dev/null || true
  done

  workdir="smoke-jxl-oxide-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  JXL_OXIDE="../$(basename "$JXL_OXIDE")"
  CJXL="../$(basename "$CJXL")"
  DJXL="../$(basename "$DJXL")"
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

  msg "lossless"
  run "lossless" lossless.jxl "$CJXL" still.ppm lossless.jxl --distance=0 --effort=3
  info="$("$JXL_OXIDE" info lossless.jxl 2>&1 | tr -d '\r')" || { echo "$info" >&2; fail "jxl-oxide info failed"; }
  contains "$info" "Image dimension: 64x48" || { echo "$info" >&2; fail "jxl-oxide info does not report 64x48"; }
  ok "jxl-oxide info reports 64x48"
  oxide_decode "lossless" lossless.jxl lossless.ppm
  [ "$(max_difference still.ppm lossless.ppm 9216)" -eq 0 ] || fail "jxl-oxide did not decode the pixels that were encoded"
  ok "jxl-oxide decodes the lossless file bit-exactly"

  msg "alpha"
  run "alpha" alpha.jxl "$CJXL" alpha.pam alpha.jxl --distance=0 --effort=3
  oxide_decode "alpha" alpha.jxl alpha-decoded.pam
  [ "$(max_difference alpha.pam alpha-decoded.pam 12288)" -eq 0 ] || fail "jxl-oxide did not decode the pixels and the alpha channel that were encoded"
  ok "jxl-oxide decodes the lossless file with alpha bit-exactly"

  # Two decoders do not round a lossy image the same way: they are expected
  # to be one apart here and there.
  msg "lossy (VarDCT)"
  run "lossy" lossy.jxl "$CJXL" still.ppm lossy.jxl --distance=1
  run "lossy" lossy-djxl.ppm "$DJXL" lossy.jxl lossy-djxl.ppm
  oxide_decode "lossy" lossy.jxl lossy.ppm
  expect_close "lossy" lossy-djxl.ppm lossy.ppm 9216 2

  msg "spline"
  zeros='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
  {
    printf 'Width 64\nHeight 64\nBitdepth 8\nXYB\n'
    printf 'Spline\n0.3 %s\n0.3 %s\n0.3 %s\n2.0 %s\n8 8\n32 56\n56 8\nEndSpline\n' "$zeros" "$zeros" "$zeros" "$zeros"
    printf -- '- Set 0\n'
  } > spline.txt
  run "spline" spline.jxl "$JXL_FROM_TREE" spline.txt spline.jxl
  run "spline" spline-djxl.ppm "$DJXL" spline.jxl spline-djxl.ppm
  oxide_decode "spline" spline.jxl spline.ppm
  expect_close "spline" spline-djxl.ppm spline.ppm 12288 2

  msg "JPEG reconstruction"
  run "JPEG transcoding" jpeg.jxl "$CJXL" source.jpg jpeg.jxl --lossless_jpeg=1
  run "JPEG reconstruction" reconstructed.jpg "$JXL_OXIDE" decode jpeg.jxl --output reconstructed.jpg --output-format jpeg --quiet
  cmp -s source.jpg reconstructed.jpg || fail "jxl-oxide did not reconstruct the original JPEG file"
  ok "jxl-oxide reconstructs the JPEG file byte for byte"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$JXL_OXIDE"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
