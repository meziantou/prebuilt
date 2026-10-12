#!/usr/bin/env bash
#
# Verifies the opj_compress/opj_decompress/opj_dump set built by
# scripts/build-openjpeg.sh.
#
#   bash scripts/verify-openjpeg.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   usage and version assertions plus real encode+decode smoke tests of
#         what the tools are published for (must run on the target platform)
#   all   both (default)
#
# What the smoke tests found out about opj_decompress, and assert:
# - A codestream of 3 components whose second one is subsampled is taken for
#   sYCC and converted to RGB at the size of the first component, even when it
#   is a bare codestream that says nothing about its colours. `-c <index>`
#   decodes one component as it is coded.
# - .raw and .rawl outputs of more than 8 bits are both written in the byte
#   order of the machine, little-endian on every target, where a .raw input is
#   big-endian. PGX and PNM outputs are big-endian.
# - .pam is an input extension only: a .pnm output with an alpha channel is a
#   PAM file.
# And about opj_compress:
# - It writes no channel definition box (cdef) in a JP2 file for the alpha
#   channel of a PAM file: only its PNG and TIFF readers tell the alpha channel
#   apart, and these tools are built without them.
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

OPJ_COMPRESS="./opj_compress-$TARGET$EXE"
OPJ_DECOMPRESS="./opj_decompress-$TARGET$EXE"
OPJ_DUMP="./opj_dump-$TARGET$EXE"
for bin in "$OPJ_COMPRESS" "$OPJ_DECOMPRESS" "$OPJ_DUMP"; do
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
        # libwinpthread-1.dll.
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

# The tools have no --version: -h prints the usage, which starts with
#   This is the opj_compress utility from the OpenJPEG project.
#   It compresses various image formats with the JPEG 2000 algorithm.
#   It has been compiled against openjp2 library v2.5.4.
# -h exits with 1, as every invocation that codes nothing does.
usage_of() {
  "$1" -h 2>&1 | tr -d '\r' || true
}

assert_version() {
  tool="$1"; bin="$2"
  usage="$(usage_of "$bin")"
  contains "$usage" "This is the $tool utility from the OpenJPEG project." \
    || fail "$tool -h does not print its usage: $usage"

  if [ -z "$OPENJPEG_VERSION" ]; then
    echo "  OPENJPEG_VERSION is not set; skipping the $tool version check"
  else
    contains "$usage" "It has been compiled against openjp2 library v$OPENJPEG_VERSION." \
      || fail "$tool is not compiled against openjp2 library v$OPENJPEG_VERSION: $usage"
    ok "$tool is compiled against openjp2 library v$OPENJPEG_VERSION"
  fi
}

# assert_options <tool> <binary> <indentation> <option>...: the usage has an
# entry for every option. An entry is a line that starts with the option.
assert_options() {
  tool="$1"; bin="$2"; indentation="$3"; shift 3
  usage="$(usage_of "$bin")"
  for option in "$@"; do
    contains "$usage" $'\n'"$indentation$option " || contains "$usage" $'\n'"$indentation$option"$'\n' \
      || fail "$tool -h does not list $option"
  done
  ok "$tool -h lists $*"
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# samples <width> <height> <channels> <bytes per sample> [<mask> [little]]:
# prints the samples of an image whose channels wrap around at different paces
# in both directions, so that the lossless round-trips have something to get
# wrong. The most significant byte of a 2-byte sample is masked, and comes
# first unless `little` is given.
samples() {
  width="$1"; height="$2"; channels="$3"; bytes="$4"; mask="${5:-255}"; order="$6"
  y=0
  while [ "$y" -lt "$height" ]; do
    row=""
    x=0
    while [ "$x" -lt "$width" ]; do
      channel=0
      while [ "$channel" -lt "$channels" ]; do
        printf -v low '%03o' $(((x * (channel * 2 + 3) + y * 7 + channel * 40) % 256))
        if [ "$bytes" -eq 2 ]; then
          printf -v high '%03o' $(((x * 5 + y * 3 + channel * 11) % 256 & mask))
          if [ "$order" = "little" ]; then row="$row\\$low\\$high"; else row="$row\\$high\\$low"; fi
        else
          row="$row\\$low"
        fi
        channel=$((channel + 1))
      done
      x=$((x + 1))
    done
    # shellcheck disable=SC2059
    printf "$row"
    y=$((y + 1))
  done
}

# gradient <width> <height> <channels>: prints the 8-bit samples of a smooth
# image with some texture, which is what the lossy coding is measured on.
gradient() {
  width="$1"; height="$2"; channels="$3"
  y=0
  while [ "$y" -lt "$height" ]; do
    row=""
    x=0
    while [ "$x" -lt "$width" ]; do
      channel=0
      while [ "$channel" -lt "$channels" ]; do
        printf -v octal '%03o' $((x * 2 + y + channel * 20 + x * y % 7 * 4))
        row="$row\\$octal"
        channel=$((channel + 1))
      done
      x=$((x + 1))
    done
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

# rejects <label> <output file> <command...>: the command fails and writes no file.
rejects() {
  label="$1"; out="$2"; shift 2
  rm -f "$out"
  if "$@" > tool.log 2>&1; then
    cat tool.log >&2
    fail "$label: $(basename "$1") succeeded"
  fi
  [ ! -s "$out" ] || fail "$label: $(basename "$1") wrote $out"
}

# compress <label> <image> <codestream> [<opj_compress option>...]
compress() {
  label="$1"; image="$2"; codestream="$3"; shift 3
  run "$label" "$codestream" "$OPJ_COMPRESS" -i "$image" -o "$codestream" "$@"
}

# decompress <label> <codestream> <image> [<opj_decompress option>...]
decompress() {
  label="$1"; codestream="$2"; image="$3"; shift 3
  run "$label" "$image" "$OPJ_DECOMPRESS" -i "$codestream" -o "$image" "$@"
}

# decompress_pgx <label> <codestream> <name> [<opj_decompress option>...]: a PGX
# file holds one component, so <name>_<component>.pgx is written for each one.
decompress_pgx() {
  label="$1"; codestream="$2"; name="$3"; shift 3
  rm -f "$name".pgx "$name"_*.pgx
  run "$label" "${name}_0.pgx" "$OPJ_DECOMPRESS" -i "$codestream" -o "$name.pgx" "$@"
  [ ! -e "$name.pgx" ] || fail "$label: $name.pgx was written next to the files of the components"
}

# same_samples <file> <file> <sample bytes>: both files end with the same samples.
# The headers are left out: opj_decompress writes a comment in the PNM ones.
same_samples() {
  tail -c "$3" "$1" > expected.raw
  tail -c "$3" "$2" > actual.raw
  [ "$(($(wc -c < expected.raw)))" -eq "$3" ] || return 1
  cmp -s expected.raw actual.raw
}

# roundtrip <name> <image> <sample bytes> [<opj_compress option>...]: <name>.j2k
# is written, and decodes to the samples of the image, in <name>.decoded.<extension>.
roundtrip() {
  name="$1"; source="$2"; bytes="$3"; shift 3
  case "$source" in
    *.pam) decoded="$name.decoded.pnm" ;;
    *) decoded="$name.decoded.${source##*.}" ;;
  esac
  compress "$name" "$source" "$name.j2k" "$@"
  decompress "$name" "$name.j2k" "$decoded"
  same_samples "$source" "$decoded" "$bytes" || fail "$name: the lossless round-trip changed the samples"
}

# expect_dump <file> <text>...: every text is in what opj_dump prints, without
# its tabulations.
expect_dump() {
  file="$1"; shift
  dump="$("$OPJ_DUMP" -i "$file" 2>&1 | tr -d '\t\r')" || { echo "$dump" >&2; fail "opj_dump $file failed"; }
  for text in "$@"; do
    contains "$dump" "$text" || { echo "$dump" >&2; fail "$file: opj_dump does not report '$text'"; }
  done
}

# markers <codestream>: prints the marker segments of the main header and of
# the header of the first tile-part, in order, each with its length:
#   ff4f ff51:41 ff52:12 ff5c:19 ff64:37 ff90:10 ff93
# The segments are walked rather than searched for: the two bytes of a marker
# below FF90 can be in the data of a segment or of a packet too.
markers() {
  hex="$(od -An -v -tx1 "$1" | tr -d ' \n')"
  [ "${hex:0:4}" = "ff4f" ] || { echo "$1 does not start with SOC" >&2; return 1; }
  list="ff4f"
  position=2
  while :; do
    marker="${hex:$((position * 2)):4}"
    case "$marker" in
      ff93) list="$list ff93"; break ;;       # SOD: the packets follow
      ff??) ;;
      *) echo "$1: no marker at offset $position" >&2; return 1 ;;
    esac
    length=$((16#${hex:$((position * 2 + 4)):4}))
    list="$list $marker:$length"
    position=$((position + 2 + length))
  done
  echo "$list"
}

# expect_markers <codestream> <pattern>...: the list `markers` prints matches
# every pattern.
expect_markers() {
  file="$1"; shift
  list=" $(markers "$file") " || fail "$file is not a codestream"
  for pattern in "$@"; do
    # shellcheck disable=SC2254
    case "$list" in
      $pattern) ;;
      *) fail "$file: its markers do not match '$pattern':$list" ;;
    esac
  done
}

# no_marker <codestream> <marker>...: the headers `markers` walks have none of them.
no_marker() {
  file="$1"; shift
  list=" $(markers "$file") " || fail "$file is not a codestream"
  for marker in "$@"; do
    if contains "$list" " $marker:"; then fail "$file has a $marker marker:$list"; fi
  done
}

# count_marker <codestream> <marker>: how many times the two bytes are in the
# file. For the markers from FF90 on only, which nothing else can hold: the
# data of a packet has no two bytes above FF8F.
count_marker() {
  od -An -v -tx1 "$1" | tr -s ' \n' ' ' | awk -v needle=" ${2:0:2} ${2:2:2} " '
    {
      count = 0
      rest = $0
      while ((at = index(rest, needle)) > 0) {
        count++
        rest = substr(rest, at + length(needle) - 1)
      }
      print count
    }'
}

# boxes <JP2 file>: prints the types of its boxes, and of the boxes of its JP2
# header box, in order and in hexadecimal.
boxes() {
  hex="$(od -An -v -tx1 "$1" | tr -d ' \n')"
  size=$((${#hex} / 2))
  list=""
  position=0
  while [ "$position" -lt "$size" ]; do
    length=$((16#${hex:$((position * 2)):8}))
    type="${hex:$((position * 2 + 8)):8}"
    list="$list $type"
    if [ "$type" = "$BOX_JP2H" ]; then
      position=$((position + 8))            # a superbox: its boxes follow
    elif [ "$length" -ge 8 ]; then
      position=$((position + length))
    else
      break                                 # 0: the box is the rest of the file
    fi
  done
  echo "$list"
}
BOX_SIGNATURE="6a502020"   # "jP  "
BOX_FTYP="66747970"
BOX_JP2H="6a703268"
BOX_IHDR="69686472"
BOX_COLR="636f6c72"
BOX_CDEF="63646566"
BOX_JP2C="6a703263"

# psnr <file> <file> <sample bytes>: prints the PSNR of the 8-bit samples both
# files end with, in dB and rounded down.
psnr() {
  tail -c "$3" "$1" > expected.raw
  tail -c "$3" "$2" > actual.raw
  [ "$(($(wc -c < expected.raw)))" -eq "$3" ] || fail "$1 holds less than $3 bytes"
  [ "$(($(wc -c < actual.raw)))" -eq "$3" ] || fail "$2 holds less than $3 bytes"
  # cmp -l prints one line per difference: the offset and the two bytes, in
  # octal. It exits with 1 when there is any.
  { cmp -l expected.raw actual.raw || true; } | awk -v count="$3" '
    function octal(text,    value, i) {
      value = 0
      for (i = 1; i <= length(text); i++) value = value * 8 + substr(text, i, 1)
      return value
    }
    {
      difference = octal($2) - octal($3)
      sum += difference * difference
    }
    END {
      if (sum == 0) print 99
      else print int(10 * log(255 * 255 * count / sum) / log(10))
    }'
}

smoke_test() {
  workdir="smoke-openjpeg-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  OPJ_COMPRESS="../$(basename "$OPJ_COMPRESS")"
  OPJ_DECOMPRESS="../$(basename "$OPJ_DECOMPRESS")"
  OPJ_DUMP="../$(basename "$OPJ_DUMP")"

  # 32x24 images: 768 samples per component.
  msg "test images"
  { printf 'P5\n32 24\n255\n'; samples 32 24 1 1; } > gray8.pgm
  { printf 'P5\n32 24\n65535\n'; samples 32 24 1 2; } > gray16.pgm
  { printf 'P6\n32 24\n255\n'; samples 32 24 3 1; } > rgb8.ppm
  { printf 'P6\n32 24\n65535\n'; samples 32 24 3 2; } > rgb16.ppm
  {
    printf 'P7\nWIDTH 32\nHEIGHT 24\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n'
    samples 32 24 4 1
  } > rgba8.pam
  {
    printf 'P7\nWIDTH 32\nHEIGHT 24\nDEPTH 4\nMAXVAL 65535\nTUPLTYPE RGB_ALPHA\nENDHDR\n'
    samples 32 24 4 2
  } > rgba16.pam
  # Planar files without a header: three components of 32x24, 16x12 and 16x12
  # samples (4:2:0), then of 32x24, 32x12 and 16x12 samples.
  { samples 32 24 1 1; samples 16 12 1 1; samples 16 12 1 1; } > yuv420.raw
  { samples 32 24 1 1; samples 32 12 1 1; samples 16 12 1 1; } > planes.raw
  samples 32 24 1 1 > signed8.raw
  # 12-bit samples in 2 bytes, most significant byte first and last.
  samples 32 24 1 2 15 > unsigned12.raw
  samples 32 24 1 2 15 little > unsigned12.rawl
  { printf 'P6\n64 64\n255\n'; gradient 64 64 3; } > gradient.ppm
  [ "$(($(wc -c < rgba16.pam)))" -eq $((69 + 6144)) ] || fail "rgba16.pam was not written correctly"
  ok "wrote the PGM, PPM, PAM and raw inputs"

  # -n is given everywhere: the default of 6 resolutions needs a tile of 32
  # samples in both directions at least, and is refused for a smaller one.
  msg "PGM, PPM and PAM input, 8 and 16 bits, lossless"
  { printf 'P5\n8 8\n255\n'; samples 8 8 1 1; } > tiny.pgm
  rejects "6 resolutions of 8x8 samples" tiny.j2k "$OPJ_COMPRESS" -i tiny.pgm -o tiny.j2k
  contains "$(cat tool.log)" "Number of resolutions is too high in comparison to the size of tiles" \
    || { cat tool.log >&2; fail "opj_compress does not say why it refuses 6 resolutions of 8x8 samples"; }
  roundtrip tiny tiny.pgm 64 -n 1
  ok "6 resolutions, the default, are refused for 8x8 samples, and -n 1 codes them"
  roundtrip gray8 gray8.pgm 768 -n 3
  expect_dump gray8.j2k "x1=32, y1=24" "numcomps=1" "prec=8" "sgnd=0" "numresolutions=3" "qmfbid=1"
  roundtrip gray16 gray16.pgm 1536 -n 3
  expect_dump gray16.j2k "numcomps=1" "prec=16"
  roundtrip rgb8 rgb8.ppm 2304 -n 3
  expect_dump rgb8.j2k "numcomps=3" "prec=8" "mct=1"
  roundtrip rgb16 rgb16.ppm 4608 -n 3
  expect_dump rgb16.j2k "numcomps=3" "prec=16"
  roundtrip rgba8 rgba8.pam 3072 -n 3
  expect_dump rgba8.j2k "numcomps=4" "prec=8"
  roundtrip rgba16 rgba16.pam 6144 -n 3
  expect_dump rgba16.j2k "numcomps=4" "prec=16"
  ok "the PGM, PPM and PAM round-trips are bit-exact at 8 and 16 bits"
  # .pam is not an output extension: 4 components are written as a PAM file
  # whatever the extension is.
  [ "$(head -c 2 rgba8.decoded.pnm)" = "P7" ] || fail "rgba8.decoded.pnm is not a PAM file"
  contains "$(head -c 120 rgba16.decoded.pnm)" "TUPLTYPE RGB_ALPHA" || fail "rgba16.decoded.pnm has no RGB_ALPHA tuple type"
  rejects "PAM output" rgba8.out.pam "$OPJ_DECOMPRESS" -i rgba8.j2k -o rgba8.out.pam
  ok "a .pnm output with an alpha channel is a PAM file, and a .pam output is refused"

  msg "raw input: subsampled components"
  compress "4:2:0" yuv420.raw yuv420.j2k -n 3 -F 32,24,3,8,u@1x1:2x2:2x2
  expect_dump yuv420.j2k "numcomps=3" "dx=1, dy=1" "dx=2, dy=2" "mct=0"
  # One component at a time: each one as it is coded.
  for component in 0 1 2; do
    decompress "4:2:0, component $component" yuv420.j2k "yuv420-$component.raw" -c "$component"
  done
  cat yuv420-0.raw yuv420-1.raw yuv420-2.raw > yuv420-components.raw
  cmp -s yuv420.raw yuv420-components.raw || fail "4:2:0: the lossless round-trip changed the samples"
  ok "-F 32,24,3,8,u@1x1:2x2:2x2 round-trips bit-exactly, one component at a time (-c)"
  # All of them at once: 3 components and a subsampled second one are taken for
  # sYCC, whatever the file says, and converted to RGB.
  decompress "4:2:0, converted" yuv420.j2k yuv420-converted.raw
  [ "$(($(wc -c < yuv420-converted.raw)))" -eq 2304 ] \
    || fail "4:2:0: opj_decompress did not write 3 components of 32x24 samples"
  decompress_pgx "4:2:0, converted" yuv420.j2k yuv420-converted
  for component in 0 1 2; do
    [ "$(head -n 1 "yuv420-converted_$component.pgx")" = "PG ML + 8 32 24" ] \
      || fail "4:2:0: component $component is not converted to 32x24 samples"
  done
  ok "without -c, opj_decompress converts the 4:2:0 codestream from sYCC to RGB, 32x24 samples per component"

  msg "PGX output: one file per component"
  # The second component is not subsampled horizontally, so nothing is converted.
  compress "planes" planes.raw planes.j2k -n 3 -F 32,24,3,8,u@1x1:1x2:2x2
  expect_dump planes.j2k "dx=1, dy=2" "dx=2, dy=2" "mct=0"
  decompress_pgx "planes" planes.j2k planes
  [ "$(head -n 1 planes_0.pgx)" = "PG ML + 8 32 24" ] || fail "planes_0.pgx: $(head -n 1 planes_0.pgx)"
  [ "$(head -n 1 planes_1.pgx)" = "PG ML + 8 32 12" ] || fail "planes_1.pgx: $(head -n 1 planes_1.pgx)"
  [ "$(head -n 1 planes_2.pgx)" = "PG ML + 8 16 12" ] || fail "planes_2.pgx: $(head -n 1 planes_2.pgx)"
  { tail -c 768 planes_0.pgx; tail -c 384 planes_1.pgx; tail -c 192 planes_2.pgx; } > planes-components.raw
  cmp -s planes.raw planes-components.raw || fail "planes: the PGX files do not hold the samples of the source"
  ok "planes_0.pgx (32x24), planes_1.pgx (32x12) and planes_2.pgx (16x12) hold the samples of the source"
  # A raw file has one size for every component.
  rejects "raw output of components of different sizes" planes.out.raw "$OPJ_DECOMPRESS" -i planes.j2k -o planes.out.raw
  ok "a .raw output is refused for components of different sizes"

  msg "raw input: signed and 12-bit samples"
  roundtrip signed8 signed8.raw 768 -n 3 -F 32,24,1,8,s
  expect_dump signed8.j2k "prec=8" "sgnd=1"
  decompress_pgx "signed" signed8.j2k signed8
  [ "$(head -n 1 signed8_0.pgx)" = "PG ML - 8 32 24" ] || fail "signed8_0.pgx: $(head -n 1 signed8_0.pgx)"
  same_samples signed8.raw signed8_0.pgx 768 || fail "signed8_0.pgx does not hold the samples of the source"
  ok "signed 8-bit samples round-trip bit-exactly (PG ML - 8)"
  compress "12 bits" unsigned12.raw unsigned12.j2k -n 3 -F 32,24,1,12,u
  expect_dump unsigned12.j2k "prec=12" "sgnd=0"
  decompress_pgx "12 bits" unsigned12.j2k unsigned12
  [ "$(head -n 1 unsigned12_0.pgx)" = "PG ML + 12 32 24" ] || fail "unsigned12_0.pgx: $(head -n 1 unsigned12_0.pgx)"
  same_samples unsigned12.raw unsigned12_0.pgx 1536 || fail "unsigned12_0.pgx does not hold the samples of the source"
  decompress "12 bits" unsigned12.j2k unsigned12.out.pgm
  same_samples unsigned12.raw unsigned12.out.pgm 1536 || fail "unsigned12.out.pgm does not hold the samples of the source"
  ok "12-bit samples round-trip bit-exactly to PGX and PGM (PG ML + 12)"
  # A .rawl input is the same image, least significant byte first.
  compress "12 bits, little-endian" unsigned12.rawl unsigned12-little.j2k -n 3 -F 32,24,1,12,u
  cmp -s unsigned12.j2k unsigned12-little.j2k || fail ".raw and .rawl inputs do not give the same codestream"
  decompress "12 bits, little-endian" unsigned12.j2k unsigned12.out.rawl
  cmp -s unsigned12.rawl unsigned12.out.rawl || fail "unsigned12.out.rawl does not hold the samples of the source"
  # The .raw output is not the .raw input: it has the byte order of the machine.
  decompress "12 bits" unsigned12.j2k unsigned12.out.raw
  cmp -s unsigned12.rawl unsigned12.out.raw || fail "unsigned12.out.raw is not little-endian"
  ok ".raw input is big-endian, .rawl input and both .raw and .rawl outputs are little-endian"

  msg "mode switches"
  for mode in 1 2 4 8 16 32 63; do
    roundtrip "mode-$mode" rgb8.ppm 2304 -n 3 -M "$mode"
    printf -v style '0x%x' "$mode"
    expect_dump "mode-$mode.j2k" "cblksty=$style"$'\n'
  done
  expect_dump rgb8.j2k $'cblksty=0\n'
  ok "-M 1, 2, 4, 8, 16, 32 and 63 round-trip bit-exactly"

  msg "progression orders, layers, precincts and code-blocks"
  order=0
  for progression in LRCP RLCP RPCL PCRL CPRL; do
    roundtrip "progression-$progression" rgb8.ppm 2304 -n 3 -r 8,4,1 -c '[16,16],[8,8]' -b 4,4 -p "$progression"
    if [ "$order" -eq 0 ]; then style="prg=0"; else style="prg=0x$order"; fi
    # The precincts are listed from the lowest resolution: 4x4, 8x8 and 16x16.
    expect_dump "progression-$progression.j2k" "$style"$'\n' "numlayers=3" "cblkw=2^2" "cblkh=2^2" \
      "preccintsize (w,h)=(2,2) (3,3) (4,4)"
    order=$((order + 1))
  done
  if cmp -s progression-LRCP.j2k progression-CPRL.j2k; then fail "-p LRCP and -p CPRL give the same codestream"; fi
  # A layer less: not the last one, which makes the coding lossless.
  decompress "2 layers" progression-LRCP.j2k progression-layers.ppm -l 2
  if same_samples rgb8.ppm progression-layers.ppm 2304; then fail "-l 2 decoded the 3 layers"; fi
  # A resolution less: 16x12 samples.
  decompress "reduced" progression-RLCP.j2k progression-reduced.ppm -r 1
  contains "$(head -c 40 progression-reduced.ppm | tr '\n' ' ')" " 16 12 " || fail "-r 1 did not decode 16x12 samples"
  ok "-p LRCP, RLCP, RPCL, PCRL and CPRL round-trip bit-exactly with -r 8,4,1 -c [16,16],[8,8] -b 4,4"

  msg "tiles and tile-parts"
  roundtrip tiles rgb8.ppm 2304 -n 3 -t 8,8
  expect_dump tiles.j2k "tdx=8, tdy=8" "tw=4, th=3"
  [ "$(count_marker tiles.j2k ff90)" -eq 12 ] || fail "tiles.j2k does not have 12 tile-parts: $(count_marker tiles.j2k ff90)"
  roundtrip tile-parts rgb8.ppm 2304 -n 3 -t 8,8 -TP R
  # A tile-part per resolution.
  [ "$(count_marker tile-parts.j2k ff90)" -eq 36 ] \
    || fail "tile-parts.j2k does not have 36 tile-parts: $(count_marker tile-parts.j2k ff90)"
  ok "-t 8,8 writes 12 tiles, and 36 tile-parts with -TP R"
  roundtrip offsets rgb8.ppm 2304 -n 3 -d 4,2 -T 2,2 -t 16,16
  expect_dump offsets.j2k "x0=4, y0=2" "x1=36, y1=26" "tx0=2, ty0=2" "tdx=16, tdy=16"
  ok "-d 4,2 -T 2,2 moves the image and the tiles"

  msg "marker segments"
  no_marker rgb8.j2k ff55 ff58 ff5e ff5f
  [ "$(count_marker rgb8.j2k ff91)" -eq 0 ] || fail "rgb8.j2k has SOP markers"
  [ "$(count_marker rgb8.j2k ff92)" -eq 0 ] || fail "rgb8.j2k has EPH markers"
  expect_markers rgb8.j2k "* ff4f ff51:* ff52:* ff5c:* ff90:10 ff93 *"
  ok "by default: SOC, SIZ, COD, QCD, SOT and SOD, and no TLM, PLT, RGN, POC, SOP or EPH"
  # A packet per resolution and component: 9.
  roundtrip sop-eph rgb8.ppm 2304 -n 3 -SOP -EPH
  expect_dump sop-eph.j2k "csty=0x6"
  [ "$(count_marker sop-eph.j2k ff91)" -eq 9 ] || fail "sop-eph.j2k does not have 9 SOP markers (FF91)"
  [ "$(count_marker sop-eph.j2k ff92)" -eq 9 ] || fail "sop-eph.j2k does not have 9 EPH markers (FF92)"
  ok "-SOP -EPH: 9 SOP (FF91) and 9 EPH (FF92) markers"
  roundtrip plt-tlm rgb8.ppm 2304 -n 3 -PLT -TLM
  expect_markers plt-tlm.j2k "* ff55:* ff90:*" "* ff90:* ff58:* ff93 *"
  ok "-PLT -TLM: TLM (FF55) in the main header and PLT (FF58) in the tile-part header"
  roundtrip roi rgb8.ppm 2304 -n 3 -ROI c=0,U=4
  expect_markers roi.j2k "* ff5e:5 *"
  expect_dump roi.j2k "roishift=4"
  ok "-ROI c=0,U=4: RGN (FF5E)"
  # Two progression order changes of 7 bytes each.
  roundtrip poc rgb8.ppm 2304 -n 3 -POC T1=0,0,1,2,3,CPRL/T1=2,0,1,3,3,RLCP
  expect_markers poc.j2k "* ff5f:16 *"
  ok "-POC with two entries: POC (FF5F)"
  roundtrip guard-bits rgb8.ppm 2304 -n 3 -GuardBits 3
  expect_dump guard-bits.j2k "numgbits=3"
  roundtrip comment rgb8.ppm 2304 -n 3 -mct 0 -C "prebuilt comment"
  expect_dump comment.j2k "mct=0"
  grep -q -a "prebuilt comment" comment.j2k || fail "comment.j2k does not have its comment"
  ok "-GuardBits 3, -mct 0 and -C"

  msg "lossy"
  compress "irreversible" gradient.ppm irreversible.j2k -n 3 -I -r 10
  expect_dump irreversible.j2k "qmfbid=0"
  # 12288 bytes of samples, and about a tenth of them.
  [ "$(($(wc -c < irreversible.j2k)))" -le 1300 ] || fail "irreversible.j2k is not a tenth of its source: $(($(wc -c < irreversible.j2k))) bytes"
  decompress "irreversible" irreversible.j2k irreversible.ppm
  if same_samples gradient.ppm irreversible.ppm 12288; then fail "-I -r 10 is lossless"; fi
  quality="$(psnr gradient.ppm irreversible.ppm 12288)"
  [ "$quality" -ge "$IRREVERSIBLE_PSNR" ] || fail "-I -r 10: PSNR of $quality dB, less than $IRREVERSIBLE_PSNR dB"
  ok "-I -r 10: $(($(wc -c < irreversible.j2k))) bytes, PSNR of $quality dB"
  roundtrip quality rgb8.ppm 2304 -n 3 -q 30,40,0
  expect_dump quality.j2k "numlayers=3"
  ok "-q 30,40,0: 3 layers, the last one lossless"

  msg "JP2 files"
  compress "JP2" rgb8.ppm rgb8.jp2 -n 3
  list="$(boxes rgb8.jp2) "
  [ "$list" = " $BOX_SIGNATURE $BOX_FTYP $BOX_JP2H $BOX_IHDR $BOX_COLR $BOX_JP2C " ] \
    || fail "rgb8.jp2 does not have the boxes jP, ftyp, jp2h (ihdr, colr) and jp2c:$list"
  decompress "JP2" rgb8.jp2 rgb8.jp2.ppm
  same_samples rgb8.ppm rgb8.jp2.ppm 2304 || fail "JP2: the lossless round-trip changed the samples"
  expect_dump rgb8.jp2 "numcomps=3" "numresolutions=3"
  ok "rgb8.jp2: jP, ftyp, jp2h (ihdr, colr) and jp2c boxes"
  # The alpha channel of a PAM file is a fourth component and nothing more: a
  # channel definition box (cdef) would say that it is one, and opj_compress
  # only writes it for the PNG and TIFF files these tools do not read.
  compress "JP2 with alpha" rgba8.pam rgba8.jp2 -n 3
  list="$(boxes rgba8.jp2) "
  [ "$list" = " $BOX_SIGNATURE $BOX_FTYP $BOX_JP2H $BOX_IHDR $BOX_COLR $BOX_JP2C " ] \
    || fail "rgba8.jp2 does not have the boxes jP, ftyp, jp2h (ihdr, colr) and jp2c:$list"
  if contains "$list" " $BOX_CDEF "; then fail "rgba8.jp2 has a cdef box"; fi
  expect_dump rgba8.jp2 "numcomps=4"
  decompress "JP2 with alpha" rgba8.jp2 rgba8.jp2.pnm
  same_samples rgba8.pam rgba8.jp2.pnm 3072 || fail "JP2 with alpha: the lossless round-trip changed the samples"
  ok "rgba8.jp2: 4 components, and no cdef box for the alpha channel of a PAM file"
  # -OutFor: the output format of the files of a directory.
  mkdir directory
  cp gray8.pgm directory/gray8.pgm
  run "directory" directory/gray8.jp2 "$OPJ_COMPRESS" -ImgDir directory -OutFor JP2 -n 3
  contains " $(boxes directory/gray8.jp2) " " $BOX_JP2C " || fail "directory/gray8.jp2 has no jp2c box"
  ok "-ImgDir directory -OutFor JP2"

  # The tools are built without libpng, libtiff and LittleCMS: PNG and TIFF
  # are extensions their usage lists, and files they do not read or write.
  msg "PNG and TIFF"
  for extension in png tif tiff; do
    rejects "$extension output" "refused.$extension" "$OPJ_DECOMPRESS" -i rgb8.j2k -o "refused.$extension"
    contains "$(cat tool.log)" "Outfile refused.$extension not generated" \
      || { cat tool.log >&2; fail "opj_decompress does not say that it writes no $extension file"; }
  done
  # A 1x1 PNG file.
  printf '\211\120\116\107\015\012\032\012\000\000\000\015\111\110\104\122\000\000\000\001\000\000\000\001\010\000\000\000\000\072\176\233\125\000\000\000\012\111\104\101\124\170\332\143\150\000\000\000\202\000\201\332\105\010\073\000\000\000\000\111\105\116\104\256\102\140\202' > pixel.png
  [ "$(($(wc -c < pixel.png)))" -eq 67 ] || fail "pixel.png was not written correctly"
  rejects "PNG input" pixel.j2k "$OPJ_COMPRESS" -i pixel.png -o pixel.j2k -n 1
  contains "$(cat tool.log)" "Unable to load file: got no image" \
    || { cat tool.log >&2; fail "opj_compress does not say that it reads no PNG file"; }
  ok "PNG and TIFF outputs and a PNG input are refused"

  cd ..
  ok "all smoke tests passed"
}

# The 64x64 image coded with -I -r 10 decodes with a PSNR of 41 dB.
IRREVERSIBLE_PSNR=36

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$OPJ_COMPRESS"
    assert_linkage "$OPJ_DECOMPRESS"
    assert_linkage "$OPJ_DUMP"
    ;;
esac

case "$MODE" in
  run|all)
    msg "version"
    assert_version opj_compress "$OPJ_COMPRESS"
    assert_version opj_decompress "$OPJ_DECOMPRESS"
    assert_version opj_dump "$OPJ_DUMP"
    msg "command-line options"
    assert_options opj_compress "$OPJ_COMPRESS" "" -r -q -n -b -c -t -p -s -POC -SOP -EPH -PLT -TLM -M -TP -ROI \
      -d -T -I -mct -F -OutFor -GuardBits -C
    assert_options opj_decompress "$OPJ_DECOMPRESS" "  " -r -l -d -t -p -c -force-rgb -upsample -split-pnm \
      -allow-partial -quiet
    assert_options opj_dump "$OPJ_DUMP" "  " -i -o -v
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
