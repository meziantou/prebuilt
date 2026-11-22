#!/usr/bin/env bash
#
# Verifies pngquant, built by scripts/build-pngquant.sh.
#
#   bash scripts/verify-pngquant.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests of what the tool is published for
#         (must run on the target platform)
#   all   both (default)
#
# The PNG inputs are written by scripts/png-writer.sh, uncompressed: a
# truecolor gradient of 1024 colors, the same with an alpha channel, and a
# 1x1 grayscale image that no palette image can be smaller than.
#
# PNGQUANT_VERSION and LIBPNG_VERSION come from the environment (see
# .github/workflows/ci.yml); without them, their checks are skipped.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PNGQUANT="./pngquant-$TARGET$EXE"
[ -f "$PNGQUANT" ] || { echo "missing $PNGQUANT" >&2; exit 1; }
chmod +x "$PNGQUANT" 2>/dev/null || true

# The samples are written byte by byte with printf.
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

# shellcheck source=verify-common.sh
. "$SCRIPT_DIR/verify-common.sh"
# shellcheck source=png-writer.sh
. "$SCRIPT_DIR/png-writer.sh"

# ---------------------------------------------------------------------------
# Linkage
# ---------------------------------------------------------------------------

# As assert_linkage of scripts/verify-common.sh, with the system DLLs the
# standard library of Rust imports: bcryptprimitives.dll (ProcessPrng),
# userenv.dll and ws2_32.dll.
assert_pngquant_linkage() {
  bin="$1"
  case "$TARGET" in
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $bin"
      imports="$("$objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $bin"
      bad=""
      for dll in $imports; do
        # Anything that is not a part of Windows means a dependency leaked in
        # dynamically -- most likely libunwind.dll of llvm-mingw.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|userenv.dll|ws2_32.dll|bcrypt.dll|bcryptprimitives.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
    *)
      assert_linkage "$bin"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

assert_version() {
  version="$("$PNGQUANT" --version 2>&1 | tr -d '\r')" || fail "pngquant --version failed: $version"
  if [ -z "$PNGQUANT_VERSION" ]; then
    echo "  PNGQUANT_VERSION is not set; skipping the version check ($version)"
  else
    expect "pngquant --version prints $PNGQUANT_VERSION" "$version" "$PNGQUANT_VERSION"
  fi

  # Without an argument, pngquant prints its banner and its usage, and fails.
  status=0
  usage="$("$PNGQUANT" 2>&1 | tr -d '\r')" || status=$?
  [ "$status" -eq 1 ] || fail "pngquant without an argument exits with $status, not 1"
  contains "$usage" "pngquant, $version (Rust)" || fail "pngquant without an argument does not print its banner: $usage"
  contains "$usage" "--skip-if-larger" || fail "the usage of pngquant does not list --skip-if-larger"
  ok "pngquant without an argument prints its banner and its usage (exit code 1)"

  # libpng-sys bundles libpng 1.6.37: the build links the libpng of the
  # release instead, whose version string png_create_read_struct checks.
  if [ -z "$LIBPNG_VERSION" ]; then
    echo "  LIBPNG_VERSION is not set; skipping the libpng check"
  else
    LC_ALL=C grep -a -q -F "$LIBPNG_VERSION" "$PNGQUANT" || fail "$PNGQUANT does not hold the version of libpng $LIBPNG_VERSION"
    if LC_ALL=C grep -a -q -F "1.6.37" "$PNGQUANT"; then fail "$PNGQUANT holds the libpng 1.6.37 of libpng-sys"; fi
    ok "pngquant is linked with libpng $LIBPNG_VERSION"
  fi
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

SIZE=32

# gradient <with alpha>: prints the scanlines of a $SIZE x $SIZE image, each
# one its filter byte (none) and its RGB or RGBA samples: red along x, green
# along y, blue along the diagonal, 1024 colors; the alpha is a diagonal ramp.
gradient() {
  y=0
  while [ "$y" -lt "$SIZE" ]; do
    row='\000'
    x=0
    while [ "$x" -lt "$SIZE" ]; do
      printf -v r '%03o' $((x * 8))
      printf -v g '%03o' $((y * 8))
      printf -v b '%03o' $(((x + y) * 4))
      row="$row\\$r\\$g\\$b"
      if [ "$1" = "alpha" ]; then
        printf -v a '%03o' $(((x + y) * 4))
        row="$row\\$a"
      fi
      x=$((x + 1))
    done
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# quantize <label> <output> <option>...: pngquant succeeds and writes a
# palette PNG file of $SIZE x $SIZE pixels with 8-bit indices.
quantize() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  "$PNGQUANT" --force --output "$out" "$@" > tool.log 2>&1 || { cat tool.log >&2; fail "$label: pngquant failed"; }
  [ -s "$out" ] || fail "$label: pngquant wrote no $out"
  info="$(png_info "$out")"
  contains "$info" "${SIZE}x$SIZE depth 8 type 3: IHDR PLTE " || fail "$label: $out is not a palette PNG file of ${SIZE}x$SIZE: $info"
}

# smaller <label> <output> <input>: the output is smaller than the input.
smaller() {
  [ "$(file_size "$2")" -lt "$(file_size "$3")" ] \
    || fail "$1: $2 ($(file_size "$2") bytes) is not smaller than $3 ($(file_size "$3") bytes)"
  ok "$1: $(file_size "$3") -> $(file_size "$2") bytes ($(png_info "$2"))"
}

# refuses <label> <exit code> <output> <option>...: pngquant exits with the
# code, and writes no output file.
refuses() {
  label="$1"; expected="$2"; out="$3"; shift 3
  rm -f "$out"
  status=0
  "$PNGQUANT" --force --output "$out" "$@" > tool.log 2>&1 || status=$?
  [ "$status" -eq "$expected" ] || { cat tool.log >&2; fail "$label: pngquant exits with $status, not $expected"; }
  [ ! -f "$out" ] || fail "$label: pngquant wrote $out"
  ok "$label: exit code $expected, no output file"
}

smoke_test() {
  workdir="smoke-pngquant-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  PNGQUANT="../$(basename "$PNGQUANT")"

  gradient > rgb.raw
  write_png rgb.png "$SIZE" "$SIZE" 8 2 rgb.raw
  gradient alpha > rgba.raw
  write_png rgba.png "$SIZE" "$SIZE" 8 6 rgba.raw
  printf '\000\200' > gray.raw
  write_png gray.png 1 1 8 0 gray.raw
  ok "wrote the PNG inputs ($(png_info rgb.png); $(png_info rgba.png); $(png_info gray.png))"

  msg "quantization"
  quantize "RGB" rgb-256.png rgb.png
  contains "$(png_info rgb-256.png)" " tRNS " && fail "rgb-256.png has a tRNS chunk"
  smaller "RGB" rgb-256.png rgb.png

  quantize "RGBA" rgba-256.png rgba.png
  contains "$(png_info rgba-256.png)" " PLTE tRNS IDAT " || fail "rgba-256.png has no tRNS chunk: $(png_info rgba-256.png)"
  smaller "RGBA, with a tRNS chunk" rgba-256.png rgba.png

  # What a site build runs: a quality range, the slowest speed, no metadata,
  # and the original kept when the result is not worth it.
  quantize "--quality 65-80 --speed 1 --strip --skip-if-larger" options.png \
    --quality 65-80 --speed 1 --strip --skip-if-larger rgb.png
  smaller "--quality 65-80 --speed 1 --strip --skip-if-larger" options.png rgb.png

  # pngquant reads a palette PNG file, its own output.
  quantize "a palette input" requantized.png rgb-256.png
  ok "pngquant reads the palette PNG files it writes"

  # Standard input and output, the - file name.
  rm -f stdout.png
  "$PNGQUANT" - < rgb.png > stdout.png 2> tool.log || { cat tool.log >&2; fail "pngquant - failed"; }
  contains "$(png_info stdout.png)" "${SIZE}x$SIZE depth 8 type 3: IHDR PLTE " || fail "pngquant - did not write a palette PNG file: $(png_info stdout.png)"
  smaller "pngquant - < rgb.png > stdout.png" stdout.png rgb.png

  msg "exit codes"
  # 98: the palette image is not smaller than a 1x1 grayscale image.
  refuses "--skip-if-larger, a larger output" 98 larger.png --skip-if-larger gray.png
  # 99: 1024 colors do not fit in a palette without a loss.
  refuses "--quality 100-100, a minimum that cannot be met" 99 perfect.png --quality 100-100 rgb.png
  refuses "a missing input" 2 missing-out.png missing.png
  printf 'not a PNG file' > not-png.png
  refuses "an input that is not a PNG file" 25 not-png-out.png not-png.png

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_pngquant_linkage "$PNGQUANT"
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
