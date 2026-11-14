#!/usr/bin/env bash
#
# Verifies the Radiance picture tools built by scripts/build-radiance.sh:
# pvalue, getinfo, pflip, protate, ra_xyze, ra_rgbe, ra_ppm and ra_bmp.
#
#   bash scripts/verify-radiance.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage and version assertions only
#   run   usage assertions plus the behavior tests below (must run on the
#         target platform)
#   all   both (default)
#
# The tools print no version: build-radiance.sh links the string
# "RADIANCE <RADIANCE_VERSION> (<first 8 digits of RADIANCE_COMMIT>)", the
# release tag, into each of them, and this script looks for it.
#
# The tests pin what a test of a Radiance picture (.hdr) codec relies on, with
# the bytes and the values these tools give, so that every runtime identifier
# gives the same:
# - pvalue -r writes the new-style run-length encoding, or flat scan lines with
#   -u; scan lines shorter than 17 or longer than 32767 pixels are always flat.
#   ra_rgbe writes flat scan lines, and ra_rgbe -r the run-length encoding. No
#   tool writes the old-style run-length encoding: the files of the old-RLE
#   test are written here, byte by byte.
# - pvalue decodes a mantissa m with the exponent e to (m + 0.5) * 2^(e - 136),
#   and the exponent 0 to 0: -df dumps these values as little-endian floats
#   (-dF big-endian), in the order of the file.
# - the resolution string (-Y N +X M and the 7 other orders) of pvalue -r, and
#   the image coordinates pvalue gives each pixel (+di: x, then y with 0 at the
#   bottom). pflip and protate change the order of the scan lines and the
#   resolution string, and keep the coordinates of each pixel: the image does
#   not change. With -c, they change the image and keep the order.
# - ra_xyze converts to XYZE (flat by default, run-length encoded with -c), and
#   back to RGBE with -r; pvalue -r -pXYZ writes XYZE.
# - EXPOSURE: pvalue gives the values of the file, and divides them by the
#   exposure with -o.
#
# RADIANCE_COMMIT and RADIANCE_VERSION come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
MODE="${2:-all}"
[ -n "$TARGET" ] || { echo "usage: $0 <target> [link|run|all]" >&2; exit 2; }
for name in RADIANCE_COMMIT RADIANCE_VERSION; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

case "$TARGET" in
  linux-x64|linux-arm64|osx-arm64) EXE="" ;;
  win-x64) EXE=".exe" ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

TOOLS="pvalue getinfo pflip protate ra_xyze ra_rgbe ra_ppm ra_bmp"
for tool in $TOOLS; do
  bin="./$tool-$TARGET$EXE"
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done

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
# Linkage and version
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
        # libwinpthread-1.dll.
        case "$dll" in
          kernel32.dll|ntdll.dll|user32.dll|advapi32.dll|shell32.dll|ws2_32.dll|ucrtbase.dll|api-ms-win-*) ;;
          *) bad="$bad $dll" ;;
        esac
      done
      [ -z "$bad" ] || fail "$bin imports non-system DLLs:$bad"
      ok "$bin imports only system DLLs ($(echo $imports | tr ' ' ','))"
      ;;
  esac
}

assert_version() {
  bin="$1"
  expected="RADIANCE $RADIANCE_VERSION ($(printf '%s' "$RADIANCE_COMMIT" | cut -c1-8))"
  grep -a -q -F "$expected" "$bin" || fail "$bin does not contain '$expected'"
  ok "$bin: $expected"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

# usage <tool> <text>: an unknown option fails and prints the text.
usage() {
  tool="$1"; text="$2"
  status=0
  output="$("./$tool-$TARGET$EXE" -Q 2>&1 < /dev/null)" || status=$?
  [ "$status" -ne 0 ] || fail "$tool -Q exited with 0: $output"
  contains "$output" "$text" || fail "$tool -Q does not print '$text': $output"
  ok "$tool rejects an unknown option"
}

# ---------------------------------------------------------------------------
# Behavior
# ---------------------------------------------------------------------------

# The hexadecimal digits of the standard input.
hex() {
  od -An -v -tx1 | tr -d ' \n\r'
}

# The text output of a tool, with LF line ends and the blanks squeezed, one
# line per `|`.
lines() {
  tr -d '\r' | tr -s ' \t' ' ' | sed -e 's/^ //' | tr '\n' '|'
}

# expect <label> <actual> <expected>
expect() {
  [ "$2" = "$3" ] || fail "$1:
  actual:   $2
  expected: $3"
  ok "$1"
}

behavior_tests() {
  workdir="smoke-radiance-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  T="$TARGET$EXE"
  PVALUE="../pvalue-$T"
  GETINFO="../getinfo-$T"
  PFLIP="../pflip-$T"
  PROTATE="../protate-$T"
  RA_XYZE="../ra_xyze-$T"
  RA_RGBE="../ra_rgbe-$T"
  RA_PPM="../ra_ppm-$T"
  RA_BMP="../ra_bmp-$T"

  # getinfo - copies what follows the header: the resolution string and the
  # scan lines. The header has the command line, so it is never compared.
  body() { "$GETINFO" - | hex; }

  msg "pvalue -r: new-style run-length encoding"
  # 20 x 3 pixels: a run of 10, then 10 different values; 17 is the shortest
  # scan line Radiance encodes.
  awk 'BEGIN { for (y = 0; y < 3; y++) for (x = 0; x < 20; x++) if (x < 10) print "1 0.5 0"; else printf "%g %g %g\n", (x + y) / 8, (x + y) / 16, 1 / (x + 1) }' > wide.txt
  "$PVALUE" -r -d -h -H -y 3 +x 20 < wide.txt > wide.hdr || fail "pvalue -r failed"
  header="$("$GETINFO" < wide.hdr | lines)"
  contains "|$header" "|#?RADIANCE|" || fail "no #?RADIANCE line: $header"
  contains "$header" "|FORMAT=32-bit_rle_rgbe|" || fail "no FORMAT line: $header"
  ok "header: #?RADIANCE, FORMAT=32-bit_rle_rgbe"
  expect "getinfo -d" "$("$GETINFO" -d < wide.hdr | lines)" "-Y 3 +X 20|"
  WIDE_RLE="2d59202020202020202033202b582020202020202032300a020200148a800aa0b0c0d0e0f0808890988a400a5058606870784044484c8a00060b0a09090808840390818482020200148a800ab0c0d0e0f080889098a08a400a58606870784044484c508a00060b0a0909080484038f818582020200148a800ac0d0e0f080889098a0a88a400a606870784044484c50548a00060b0a0909040484038e818682"
  expect "run-length encoded scan lines (02 02, width, 4 runs of components)" "$(body < wide.hdr)" "$WIDE_RLE"

  msg "flat scan lines"
  "$PVALUE" -r -u -d -h -H -y 3 +x 20 < wide.txt > wide-flat.hdr || fail "pvalue -r -u failed"
  flat="$(body < wide-flat.hdr)"
  expect "pvalue -r -u: resolution string and 3 x 20 x 4 bytes" "${#flat}" "$(( (24 + 240) * 2 ))"
  expect "ra_rgbe writes the same flat scan lines" "$("$RA_RGBE" < wide.hdr | body)" "$flat"
  expect "ra_rgbe -r writes the run-length encoding again" "$("$RA_RGBE" -r < wide-flat.hdr | body)" "$WIDE_RLE"

  # 3 x 2 pixels: flat, whatever the options.
  printf '1 0 0\n0 1 0\n0 0 1\n0.5 0.25 0.125\n2 4 8\n1000 0.001 0\n' > colors.txt
  "$PVALUE" -r -d -h -H -y 2 +x 3 < colors.txt > colors.hdr
  COLORS="2d59202020202020202032202b582020202020202020330a8000008100800081000080818040208020408084fa00008a"
  expect "a scan line of 3 pixels is flat" "$(body < colors.hdr)" "$COLORS"

  msg "pvalue: decoding"
  COLORS_F32="0080803f0000803b0000803b0000803b0080803f0000803b0000803b0000803b0080803f0080003f0000813e0000023e00000240000081400080004100807a440000004000000040"
  expect "pvalue -df: little-endian floats, (m + 0.5) * 2^(e - 136)" "$("$PVALUE" -h -H -df < colors.hdr | hex)" "$COLORS_F32"
  expect "pvalue -dF: big-endian floats" "$("$PVALUE" -h -H -dF < colors.hdr | hex | cut -c1-24)" "3f8080003b8000003b800000"
  expect "pvalue -d: text" "$("$PVALUE" -h -H -d < colors.hdr | lines | cut -d'|' -f1,6)" "1.004e+00 3.906e-03 3.906e-03|1.002e+03 2.000e+00 2.000e+00"
  "$PVALUE" -h -H -df < wide.hdr > wide.f32
  "$PVALUE" -r -h -df -y 3 +x 20 < wide.f32 > wide-again.hdr || fail "pvalue -r -df failed"
  expect "pvalue -df then pvalue -r -df gives the same scan lines" "$(body < wide-again.hdr)" "$WIDE_RLE"
  "$PVALUE" -h -H -dF < wide.hdr > wide.f32be
  "$PVALUE" -r -h -dF -y 3 +x 20 < wide.f32be > wide-again.hdr || fail "pvalue -r -dF failed"
  expect "pvalue -dF then pvalue -r -dF gives the same scan lines" "$(body < wide-again.hdr)" "$WIDE_RLE"

  # Flat RGBE pixels written byte by byte: 80 40 20 81, a zero exponent, and
  # ff 01 80 7f.
  { printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 3\n'; printf '\200\100\040\201\000\000\000\000\377\001\200\177'; } > bytes.hdr
  expect "pvalue -df of given RGBE bytes" "$("$PVALUE" -h -H -df < bytes.hdr | hex)" \
    "0080803f0000013f0000823e0000000000000000000000000080ff3e0000403b0080803e"

  msg "pvalue: old-style run-length encoding"
  # 20 x 2 pixels: a pixel, 01 01 01 09 (9 more), a second pixel, 9 more of
  # it, then a zero pixel and 19 more.
  { printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 20\n'
    printf '\200\100\040\201\001\001\001\011\020\010\200\203\001\001\001\011'
    printf '\000\000\000\000\001\001\001\023'; } > old-rle.hdr
  p="0080803f0000013f0000823e"; q="0000043f0000883e00808040"; z="000000000000000000000000"
  expected=""
  for i in 1 2 3 4 5 6 7 8 9 10; do expected="$expected$p"; done
  for i in 1 2 3 4 5 6 7 8 9 10; do expected="$expected$q"; done
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do expected="$expected$z"; done
  expect "pvalue decodes the old-style run-length encoding" "$("$PVALUE" -h -H -df < old-rle.hdr | hex)" "$expected"
  expect "ra_rgbe -r writes it with the new one" "$("$RA_RGBE" -r < old-rle.hdr | body)" \
    "2d59202020202020202032202b582020202020202032300a020200148a808a108a408a088a208a808a818a83020200149400940094009400"

  msg "orientations"
  # 3 x 2 gray pixels: green 25, 51, 76, 102, 128 and 153 with -pG -di.
  printf '0.1 0.1 0.1\n0.2 0.2 0.2\n0.3 0.3 0.3\n0.4 0.4 0.4\n0.5 0.5 0.5\n0.6 0.6 0.6\n' > gray.txt
  # pvalue -r with each order: the resolution string, then "x y green" for
  # each pixel, in the order of the file.
  check_order() {
    "$PVALUE" -r -d -h -H $1 < gray.txt > order.hdr || fail "pvalue -r $1 failed"
    expect "pvalue -r $1" "$("$GETINFO" -d < order.hdr | lines) $("$PVALUE" -h -H -pG +di < order.hdr | lines)" "$2"
  }
  check_order "-y 2 +x 3" "-Y 2 +X 3| 0 1 25|1 1 51|2 1 76|0 0 102|1 0 128|2 0 153|"
  check_order "-y 2 -x 3" "-Y 2 -X 3| 2 1 25|1 1 51|0 1 76|2 0 102|1 0 128|0 0 153|"
  check_order "+y 2 +x 3" "+Y 2 +X 3| 0 0 25|1 0 51|2 0 76|0 1 102|1 1 128|2 1 153|"
  check_order "+y 2 -x 3" "+Y 2 -X 3| 2 0 25|1 0 51|0 0 76|2 1 102|1 1 128|0 1 153|"
  check_order "+x 3 -y 2" "+X 3 -Y 2| 0 1 25|0 0 51|1 1 76|1 0 102|2 1 128|2 0 153|"
  check_order "+x 3 +y 2" "+X 3 +Y 2| 0 0 25|0 1 51|1 0 76|1 1 102|2 0 128|2 1 153|"
  check_order "-x 3 -y 2" "-X 3 -Y 2| 2 1 25|2 0 51|1 1 76|1 0 102|0 1 128|0 0 153|"
  check_order "-x 3 +y 2" "-X 3 +Y 2| 2 0 25|2 1 51|1 0 76|1 1 102|0 0 128|0 1 153|"

  "$PVALUE" -r -d -h -H -y 2 +x 3 < gray.txt > gray.hdr
  # check_transform <label> <expected> <tool> <options...>
  check_transform() {
    label="$1"; expected="$2"; shift 2
    "$@" gray.hdr > transformed.hdr || fail "$label failed"
    expect "$label" "$("$GETINFO" -d < transformed.hdr | lines) $("$PVALUE" -h -H -pG +di < transformed.hdr | lines)" "$expected"
  }
  # Without -c: other order, same coordinates for each value.
  check_transform "pflip -h" "-Y 2 -X 3| 2 1 76|1 1 51|0 1 25|2 0 153|1 0 128|0 0 102|" "$PFLIP" -h
  check_transform "pflip -v" "+Y 2 +X 3| 0 0 102|1 0 128|2 0 153|0 1 25|1 1 51|2 1 76|" "$PFLIP" -v
  check_transform "pflip -h -v" "+Y 2 -X 3| 2 0 153|1 0 128|0 0 102|2 1 76|1 1 51|0 1 25|" "$PFLIP" -h -v
  check_transform "protate" "+X 3 +Y 2| 0 0 102|0 1 25|1 0 128|1 1 51|2 0 153|2 1 76|" "$PROTATE"
  check_transform "protate -r" "-X 3 -Y 2| 2 1 76|2 0 153|1 1 51|1 0 128|0 1 25|0 0 102|" "$PROTATE" -r
  # With -c: same order, the image is flipped or rotated.
  check_transform "pflip -c -h" "-Y 2 +X 3| 0 1 76|1 1 51|2 1 25|0 0 153|1 0 128|2 0 102|" "$PFLIP" -c -h
  check_transform "pflip -c -v" "-Y 2 +X 3| 0 1 102|1 1 128|2 1 153|0 0 25|1 0 51|2 0 76|" "$PFLIP" -c -v
  check_transform "protate -c" "-Y 3 +X 2| 0 2 102|1 2 25|0 1 128|1 1 51|0 0 153|1 0 76|" "$PROTATE" -c
  check_transform "protate -c -r" "-Y 3 +X 2| 0 2 76|1 2 153|0 1 51|1 1 128|0 0 25|1 0 102|" "$PROTATE" -c -r

  "$PFLIP" -h -v gray.hdr > flipped.hdr
  "$PFLIP" -h -v flipped.hdr > flipped-twice.hdr
  expect "pflip -h -v twice gives the scan lines back" "$(body < flipped-twice.hdr)" "$(body < gray.hdr)"
  "$PROTATE" gray.hdr > rotated.hdr
  "$PROTATE" -r rotated.hdr > rotated-back.hdr
  expect "protate then protate -r gives the scan lines back" "$(body < rotated-back.hdr)" "$(body < gray.hdr)"

  msg "XYZE"
  "$RA_XYZE" < colors.hdr > colors-xyze.hdr || fail "ra_xyze failed"
  header="$("$GETINFO" < colors-xyze.hdr | lines)"
  contains "$header" "|EXPOSURE=5.5866e-03|FORMAT=32-bit_rle_xyze|" || fail "ra_xyze header: $header"
  ok "ra_xyze header: EXPOSURE=5.5866e-03, FORMAT=32-bit_rle_xyze"
  COLORS_XYZE="2d59202020202020202032202b582020202020202020330a8444078053ac20802a11db80b89e4d7f7478ec838142068a"
  expect "ra_xyze: XYZE pixels" "$(body < colors-xyze.hdr)" "$COLORS_XYZE"
  expect "pvalue -df of XYZE: the values of the file" "$("$PVALUE" -h -H -df < colors-xyze.hdr | hex)" \
    "0080043f0000893e0000f03c0000a73e00802c3f0000023e00002a3e00008c3d00805b3f0080b83e00809e3e00001b3e00006940000071400080ec4000800144000085430000d041"
  "$RA_XYZE" -r < colors-xyze.hdr > colors-rgbe.hdr
  header="$("$GETINFO" < colors-rgbe.hdr | lines)"
  contains "$header" "|FORMAT=32-bit_rle_rgbe|" || fail "ra_xyze -r header: $header"
  expect "ra_xyze -r: back to RGBE" "$(body < colors-rgbe.hdr)" \
    "2d59202020202020202032202b582020202020202020330a8000008100800081000080818040208020408084fa00018a"
  "$RA_XYZE" < wide.hdr > wide-xyze.hdr
  wide_xyze="$(body < wide-xyze.hdr)"
  expect "ra_xyze writes flat scan lines" "${#wide_xyze}" "$(( (24 + 240) * 2 ))"
  wide_xyze_rle="$("$RA_XYZE" -c < wide.hdr | body)"
  expect "ra_xyze -c writes the run-length encoding" "$(printf '%s' "$wide_xyze_rle" | cut -c49-56)" "02020014"
  expect "ra_rgbe keeps the XYZE values" "$("$RA_XYZE" -c < wide.hdr | "$RA_RGBE" | body)" "$wide_xyze"

  printf '1 2 3\n0.5 0.25 4\n' > xyz.txt
  "$PVALUE" -r -pXYZ -d -h -H -y 1 +x 2 < xyz.txt > xyz.hdr || fail "pvalue -r -pXYZ failed"
  header="$("$GETINFO" < xyz.hdr | lines)"
  contains "$header" "|FORMAT=32-bit_rle_xyze|" || fail "pvalue -r -pXYZ header: $header"
  expect "pvalue -r -pXYZ: XYZE pixels" "$(body < xyz.hdr)" "2d59202020202020202031202b582020202020202020320a4080c08210088083"
  expect "pvalue -d of XYZE" "$("$PVALUE" -h -H -d < xyz.hdr | lines)" "1.008e+00 2.008e+00 3.008e+00|5.156e-01 2.656e-01 4.016e+00|"
  expect "pvalue -d -O of XYZE: divided by 179 lm/W" "$("$PVALUE" -h -H -d -O < xyz.hdr | lines)" "5.630e-03 1.122e-02 1.680e-02|2.881e-03 1.484e-03 2.243e-02|"

  msg "header"
  # A header with more lines, and no FORMAT line.
  { printf '#?RADIANCE\nEXPOSURE=0.5\nPIXASPECT=2\nVIEW= -vtv -vp 0 0 0\nSOFTWARE=test\n\n-Y 1 +X 3\n'
    printf '\200\100\040\201\000\000\000\000\377\001\200\177'; } > header.hdr
  expect "getinfo" "$("$GETINFO" < header.hdr | lines)" \
    "#?RADIANCE|EXPOSURE=0.5|PIXASPECT=2|VIEW= -vtv -vp 0 0 0|SOFTWARE=test||"
  expect "getinfo -d" "$("$GETINFO" -d < header.hdr | lines)" "-Y 1 +X 3|"
  expect "pvalue -d: the values of the file" "$("$PVALUE" -h -H -d < header.hdr | lines)" \
    "1.004e+00 5.039e-01 2.539e-01|0.000e+00 0.000e+00 0.000e+00|4.990e-01 2.930e-03 2.510e-01|"
  expect "pvalue -d -o: divided by EXPOSURE" "$("$PVALUE" -h -H -d -o < header.hdr | lines)" \
    "2.008e+00 1.008e+00 5.078e-01|0.000e+00 0.000e+00 0.000e+00|9.980e-01 5.859e-03 5.020e-01|"
  "$GETINFO" -a "EXPOSURE=2" < colors.hdr > exposure.hdr || fail "getinfo -a failed"
  header="$("$GETINFO" < exposure.hdr | lines)"
  contains "$header" "|EXPOSURE=2|FORMAT=32-bit_rle_rgbe|" || fail "getinfo -a header: $header"
  expect "getinfo -a adds a header line" "$(body < exposure.hdr)" "$COLORS"
  expect "pvalue -d -o of it" "$("$PVALUE" -h -H -d -o < exposure.hdr | lines | cut -d'|' -f1,6)" "5.020e-01 1.953e-03 1.953e-03|5.010e+02 1.000e+00 1.000e+00"

  msg "ra_ppm and ra_bmp"
  expect "ra_ppm: gamma 2.2" "$("$RA_PPM" < gray.hdr | hex)" "50360a3320320a3235350a5959597b7b7b949494a8a8a8bbbbbbcacaca"
  expect "ra_ppm -s 65535" "$("$RA_PPM" -s 65535 < gray.hdr | hex)" \
    "50360a3320320a36353533350a59d359d359d37b187b187b18940f940f940fa8aea8aea8aebb25bb25bb25cae5cae5cae5"
  "$RA_PPM" < gray.hdr > gray.ppm
  expect "ra_ppm -r" "$("$RA_PPM" -r < gray.ppm | body)" \
    "2d59202020202020202032202b582020202020202020330acacaca7dcdcdcd7e9a9a9a7fcccccc7f8181818098989880"
  bmp="$("$RA_BMP" < gray.hdr | hex)"
  expect "ra_bmp: BM, top-down 3 x 2 pixels of 24 bits" "$(printf '%s' "$bmp" | cut -c1-4)/$(printf '%s' "$bmp" | cut -c37-60)" \
    "424d/03000000feffffff01001800"
  expect "ra_bmp: the pixels" "${bmp: -48}" "5959597b7b7b949494000000a8a8a8bbbbbbcacaca000000"
  "$RA_BMP" < gray.hdr > gray.bmp
  "$RA_BMP" -r < gray.bmp > gray-again.hdr || fail "ra_bmp -r failed"
  expect "ra_bmp -r" "$("$GETINFO" -d < gray-again.hdr | lines)" "-Y 2 +X 3|"

  cd ..
  ok "all tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage and version ($TARGET)"
    for tool in $TOOLS; do
      assert_linkage "./$tool-$TARGET$EXE"
      assert_version "./$tool-$TARGET$EXE"
    done
    ;;
esac

case "$MODE" in
  run|all)
    msg "usage"
    usage pvalue "unknown option: -Q"
    usage pflip "input not a Radiance picture"
    usage protate "-Q: cannot open"
    usage ra_xyze "Usage:"
    usage ra_rgbe "Usage:"
    usage ra_ppm "Usage:"
    usage ra_bmp "Usage:"
    # getinfo exits with 0 when it cannot open a file.
    output="$("./getinfo-$TARGET$EXE" -Q 2>&1 < /dev/null || true)"
    contains "$output" "-Q: cannot open" || fail "getinfo -Q: $output"
    ok "getinfo reports a file it cannot open"
    behavior_tests
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
