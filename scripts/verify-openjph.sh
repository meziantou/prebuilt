#!/usr/bin/env bash
#
# Verifies the ojph_compress/ojph_expand set built by scripts/build-openjph.sh.
#
#   bash scripts/verify-openjph.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   usage assertions plus real encode+decode smoke tests of what the
#         tools are published for (must run on the target platform)
#   all   both (default)
#
# The OpenJPH tools have no --version and print no version anywhere, so there
# is no version assertion: the sources are pinned by tag in build-openjph.sh.
#
# The smoke tests need the opj_compress, opj_decompress and opj_dump of the same
# target next to the OpenJPH tools (scripts/build-openjpeg.sh): opj_decompress
# is the second decoder the codestreams of ojph_compress are decoded with, and
# opj_dump reads their coding parameters back.
#
# What the smoke tests found out about ojph_compress, and assert:
# - It writes HT cleanup passes only: every code-block has one coding pass, and
#   never the SigProp and MagRef refinement passes that may follow it. There is
#   no option for more: the block coder of OpenJPH 0.32.0 is written for one
#   pass (ojph_encode_codeblock32 and ojph_encode_codeblock64 assert
#   num_passes == 1). A codestream with HT refinement passes has to come from
#   somewhere else.
# - The samples of a .yuv file are read as unsigned numbers whatever -signed
#   says: -signed only declares the component as signed, and a sample above
#   what a signed component holds is clipped. A .raw file, which is one
#   component, is read with its sign.
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

OJPH_COMPRESS="./ojph_compress-$TARGET$EXE"
OJPH_EXPAND="./ojph_expand-$TARGET$EXE"
for bin in "$OJPH_COMPRESS" "$OJPH_EXPAND"; do
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
# Usage
# ---------------------------------------------------------------------------

# Without an argument, the tools print their usage and fail. The file formats
# of the usage are the ones the tool is built with: a build with libtiff lists
# tif(f) too.
# assert_usage <tool> <binary> <formats line> <option>...
assert_usage() {
  tool="$1"; bin="$2"; formats="$3"; shift 3
  status=0
  usage="$("$bin" 2>&1 | tr -d '\r')" || status=$?
  [ "$status" -ne 0 ] || fail "$tool without an argument succeeded: $usage"
  contains "$usage" "The following arguments are necessary:" || fail "$tool without an argument does not print its usage: $usage"
  contains "$usage" "$formats" || fail "$tool does not list its file formats as '$formats': $usage"
  for option in "$@"; do
    contains "$usage" $'\n'" $option " || fail "the usage of $tool does not list $option"
  done
  ok "$tool: $formats"
  ok "the usage of $tool lists $*"
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

# compress <label> <image> <codestream> [<ojph_compress option>...]
# An {x,y} argument has to be quoted: bash expands the braces otherwise.
compress() {
  label="$1"; image="$2"; codestream="$3"; shift 3
  run "$label" "$codestream" "$OJPH_COMPRESS" -i "$image" -o "$codestream" "$@"
}

# expand <label> <codestream> <image>: decodes with ojph_expand.
expand() {
  run "$1" "$3" "$OJPH_EXPAND" -i "$2" -o "$3"
}

# decompress <label> <codestream> <image> [<opj_decompress option>...]: decodes
# with opj_decompress.
decompress() {
  label="$1"; codestream="$2"; image="$3"; shift 3
  run "$label" "$image" "$OPJ_DECOMPRESS" -i "$codestream" -o "$image" "$@"
}

# same_samples <file> <file> <sample bytes>: both files end with the same samples.
# The headers are left out: opj_decompress writes a comment in the PNM ones.
same_samples() {
  tail -c "$3" "$1" > expected.raw
  tail -c "$3" "$2" > actual.raw
  [ "$(($(wc -c < expected.raw)))" -eq "$3" ] || return 1
  cmp -s expected.raw actual.raw
}

# roundtrip <name> <image> <sample bytes> [<ojph_compress option>...]: <name>.j2c
# is written, and both ojph_expand and opj_decompress decode it to the samples
# of the image.
roundtrip() {
  name="$1"; source="$2"; bytes="$3"; shift 3
  extension="${source##*.}"
  compress "$name" "$source" "$name.j2c" "$@"
  expand "$name" "$name.j2c" "$name.ojph.$extension"
  same_samples "$source" "$name.ojph.$extension" "$bytes" || fail "$name: the lossless round-trip changed the samples"
  decompress "$name" "$name.j2c" "$name.opj.$extension"
  same_samples "$source" "$name.opj.$extension" "$bytes" \
    || fail "$name: opj_decompress does not decode the samples of the source"
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
#   ff4f ff51:47 ff50:8 ff52:12 ff5c:10 ff64:23 ff90:10 ff93
# The segments are walked rather than searched for: the two bytes of a marker
# below FF90 can be in the data of a segment or of a packet too.
# It leaves the offset of the first packet in $position.
markers() {
  hex="$(od -An -v -tx1 "$1" | tr -d ' \n')"
  [ "${hex:0:4}" = "ff4f" ] || { echo "$1 does not start with SOC" >&2; return 1; }
  list="ff4f"
  position=2
  while :; do
    marker="${hex:$((position * 2)):4}"
    case "$marker" in
      ff93) list="$list ff93"; position=$((position + 2)); break ;;       # SOD: the packets follow
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

# read_bit: reads the next bit of a packet header into $bit, from the byte at
# $position of $hex. The bits are read from the most significant one, and the
# byte after a FF byte has 7 of them: its first one is a stuffing bit.
read_bit() {
  if [ "$bits_left" -eq 0 ]; then
    previous="$current"
    current=$((16#${hex:$((position * 2)):2}))
    position=$((position + 1))
    if [ "$previous" -eq 255 ]; then bits_left=7; else bits_left=8; fi
  fi
  bits_left=$((bits_left - 1))
  bit=$(((current >> bits_left) & 1))
}

# coding_passes <codestream>: prints the number of coding passes the first
# packet has for its code-block. For a codestream of one tile, one component,
# one resolution, one layer and one code-block: the packet header is then
#   1               the packet is not empty
#   1               the code-block is included (a tag tree of one node)
#   0 ... 0 1       its missing bit-planes (a tag tree of one node)
#   0               1 coding pass
#   10              2
#   11xx            3 to 5
#   1111xxxxx       6 to 36
#   111111111x...   37 to 164
coding_passes() {
  markers "$1" > /dev/null || return 1
  current=0
  bits_left=0
  read_bit; [ "$bit" -eq 1 ] || { echo "$1: the first packet is empty" >&2; return 1; }
  read_bit; [ "$bit" -eq 1 ] || { echo "$1: the first packet does not have its code-block" >&2; return 1; }
  missing=0
  while :; do
    read_bit
    [ "$bit" -eq 0 ] || break
    missing=$((missing + 1))
    [ "$missing" -lt 64 ] || { echo "$1: no end to the missing bit-planes" >&2; return 1; }
  done
  read_bit; if [ "$bit" -eq 0 ]; then echo 1; return 0; fi
  read_bit; if [ "$bit" -eq 0 ]; then echo 2; return 0; fi
  read_bit; value="$bit"
  read_bit; value=$((value * 2 + bit))
  if [ "$value" -lt 3 ]; then echo $((3 + value)); return 0; fi
  value=0; count=0
  while [ "$count" -lt 5 ]; do read_bit; value=$((value * 2 + bit)); count=$((count + 1)); done
  if [ "$value" -lt 31 ]; then echo $((6 + value)); return 0; fi
  value=0; count=0
  while [ "$count" -lt 7 ]; do read_bit; value=$((value * 2 + bit)); count=$((count + 1)); done
  echo $((37 + value))
}

# differences <file> <file> <sample bytes>: prints the largest difference
# between the 8-bit samples both files end with, and their PSNR in dB, rounded
# down.
differences() {
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
      if (difference < 0) difference = -difference
      if (difference > max) max = difference
      sum += difference * difference
    }
    END {
      if (sum == 0) print "0 99"
      else print max, int(10 * log(255 * 255 * count / sum) / log(10))
    }'
}

smoke_test() {
  OPJ_COMPRESS="./opj_compress-$TARGET$EXE"
  OPJ_DECOMPRESS="./opj_decompress-$TARGET$EXE"
  OPJ_DUMP="./opj_dump-$TARGET$EXE"
  for bin in "$OPJ_COMPRESS" "$OPJ_DECOMPRESS" "$OPJ_DUMP"; do
    [ -f "$bin" ] || fail "missing $bin, which the smoke tests check the codestreams of ojph_compress with"
    chmod +x "$bin" 2>/dev/null || true
  done

  workdir="smoke-openjph-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  OJPH_COMPRESS="../$(basename "$OJPH_COMPRESS")"
  OJPH_EXPAND="../$(basename "$OJPH_EXPAND")"
  OPJ_COMPRESS="../$(basename "$OPJ_COMPRESS")"
  OPJ_DECOMPRESS="../$(basename "$OPJ_DECOMPRESS")"
  OPJ_DUMP="../$(basename "$OPJ_DUMP")"

  # 32x24 images: 768 samples per component.
  msg "test images"
  { printf 'P5\n32 24\n255\n'; samples 32 24 1 1; } > gray8.pgm
  { printf 'P6\n32 24\n255\n'; samples 32 24 3 1; } > rgb8.ppm
  { printf 'P6\n32 24\n65535\n'; samples 32 24 3 2; } > rgb16.ppm
  { printf 'P6\n64 64\n255\n'; gradient 64 64 3; } > gradient.ppm
  { printf 'P5\n8 8\n255\n'; samples 8 8 1 1; } > block.pgm
  # Planar files without a header: three components of 32x24, 16x12 and 16x12
  # samples (4:2:0); then a 12-bit component of 32x24 samples, least
  # significant byte first, and 8-bit ones of 32x12 and 16x12 samples. The
  # 12-bit samples are below 2048: the component is coded as a signed one.
  { samples 32 24 1 1; samples 16 12 1 1; samples 16 12 1 1; } > yuv420.yuv
  samples 32 24 1 2 7 > plane12.raw
  { samples 32 24 1 2 7 little; samples 32 12 1 1; samples 16 12 1 1; } > planes.yuv
  samples 32 24 1 1 > signed8.raw
  [ "$(($(wc -c < planes.yuv)))" -eq $((1536 + 384 + 192)) ] || fail "planes.yuv was not written correctly"
  ok "wrote the PGM, PPM, yuv and raw inputs"

  msg "reversible (-reversible true)"
  roundtrip reversible rgb8.ppm 2304 -reversible true -num_decomps 2
  # The capabilities of Part 15 are announced by the CAP marker segment, after
  # SIZ, whose Rsiz says that there is one: bit 14.
  expect_markers reversible.j2c "* ff4f ff51:* ff50:* ff52:* ff5c:* ff90:10 ff93 *"
  [ "$(od -An -v -tx1 -j 6 -N 2 reversible.j2c | tr -d ' \n')" = "4000" ] || fail "reversible.j2c: Rsiz is not 4000"
  # 0x40: the code-blocks are HT ones.
  expect_dump reversible.j2c "x1=32, y1=24" "numcomps=3" "prec=8" "numresolutions=3" "qmfbid=1" "cblksty=0x40" "numlayers=1"
  ok "the reversible round-trip is bit-exact: SIZ with Rsiz 4000, CAP (FF50) and HT code-blocks"
  ok "opj_decompress decodes reversible.j2c to the samples of the source"
  roundtrip gray gray8.pgm 768 -reversible true -num_decomps 2
  expect_dump gray.j2c "numcomps=1"
  # 5 decompositions by default, and RPCL.
  roundtrip defaults rgb8.ppm 2304 -reversible true
  expect_dump defaults.j2c "numresolutions=6" "prg=0x2"
  ok "PGM input, and 5 decompositions in the RPCL order by default"

  msg "irreversible (-reversible false -qstep 0.01)"
  compress "irreversible" gradient.ppm irreversible.j2c -reversible false -qstep 0.01 -num_decomps 2
  expect_markers irreversible.j2c "* ff51:* ff50:* ff52:*"
  expect_dump irreversible.j2c "qmfbid=0" "cblksty=0x40"
  expand "irreversible" irreversible.j2c irreversible.ojph.ppm
  if same_samples gradient.ppm irreversible.ojph.ppm 12288; then fail "-reversible false is lossless"; fi
  set -- $(differences gradient.ppm irreversible.ojph.ppm 12288)
  [ "$2" -ge "$IRREVERSIBLE_PSNR" ] || fail "-qstep 0.01: PSNR of $2 dB, less than $IRREVERSIBLE_PSNR dB"
  ok "-qstep 0.01: $(($(wc -c < irreversible.j2c))) bytes, PSNR of $2 dB"
  # The two decoders do not round the same way.
  decompress "irreversible" irreversible.j2c irreversible.opj.ppm
  set -- $(differences irreversible.ojph.ppm irreversible.opj.ppm 12288)
  [ "$1" -le 2 ] || fail "irreversible: ojph_expand and opj_decompress differ by $1"
  ok "ojph_expand and opj_decompress differ by at most $1"
  set -- $(differences gradient.ppm irreversible.opj.ppm 12288)
  [ "$2" -ge "$IRREVERSIBLE_PSNR" ] || fail "-qstep 0.01: PSNR of $2 dB with opj_decompress, less than $IRREVERSIBLE_PSNR dB"
  # A larger step: a smaller file.
  compress "irreversible, larger step" gradient.ppm coarse.j2c -reversible false -qstep 0.1 -num_decomps 2
  [ "$(($(wc -c < coarse.j2c)))" -lt "$(($(wc -c < irreversible.j2c)))" ] || fail "-qstep 0.1 does not give a smaller file than -qstep 0.01"
  # Irreversible is the default.
  compress "defaults" gradient.ppm lossy-defaults.j2c
  expect_dump lossy-defaults.j2c "qmfbid=0"
  ok "-qstep 0.1 gives a smaller file, and the coding is irreversible by default"

  msg "coding options"
  # The precincts are given from the lowest resolution, and listed that way:
  # 8x8, then 16x16 for the other ones.
  roundtrip options rgb8.ppm 2304 -reversible true -num_decomps 2 -block_size '{16,16}' -precincts '{8,8},{16,16}' \
    -colour_trans true
  expect_dump options.j2c "numresolutions=3" "cblkw=2^4" "cblkh=2^4" "preccintsize (w,h)=(3,3) (4,4) (4,4)" "mct=1"
  roundtrip no-transform rgb8.ppm 2304 -reversible true -num_decomps 2 -colour_trans false
  expect_dump no-transform.j2c "mct=0"
  if cmp -s reversible.j2c no-transform.j2c; then fail "-colour_trans false changes nothing"; fi
  ok "-num_decomps 2 -block_size {16,16} -precincts {8,8},{16,16} and -colour_trans true and false"
  order=0
  for progression in LRCP RLCP RPCL PCRL CPRL; do
    roundtrip "progression-$progression" rgb8.ppm 2304 -reversible true -num_decomps 2 -precincts '{8,8},{16,16}' \
      -prog_order "$progression"
    if [ "$order" -eq 0 ]; then style="prg=0"; else style="prg=0x$order"; fi
    expect_dump "progression-$progression.j2c" "$style"$'\n'
    order=$((order + 1))
  done
  if cmp -s progression-LRCP.j2c progression-CPRL.j2c; then fail "-prog_order LRCP and CPRL give the same codestream"; fi
  ok "-prog_order LRCP, RLCP, RPCL, PCRL and CPRL round-trip bit-exactly"

  msg "tiles, tile-parts and TLM"
  roundtrip tiles rgb8.ppm 2304 -reversible true -num_decomps 2 -tile_size '{16,16}'
  expect_dump tiles.j2c "tdx=16, tdy=16" "tw=2, th=2"
  [ "$(count_marker tiles.j2c ff90)" -eq 4 ] || fail "tiles.j2c does not have 4 tile-parts: $(count_marker tiles.j2c ff90)"
  if contains " $(markers tiles.j2c) " " ff55:"; then fail "tiles.j2c has a TLM marker segment"; fi
  # A tile-part per resolution, then per component: 3 for each of the 4 tiles.
  roundtrip tile-parts-r rgb8.ppm 2304 -reversible true -num_decomps 2 -tile_size '{16,16}' -prog_order RPCL \
    -tileparts R -tlm_marker true
  [ "$(count_marker tile-parts-r.j2c ff90)" -eq 12 ] \
    || fail "tile-parts-r.j2c does not have 12 tile-parts: $(count_marker tile-parts-r.j2c ff90)"
  expect_markers tile-parts-r.j2c "* ff55:* ff90:*"
  roundtrip tile-parts-c rgb8.ppm 2304 -reversible true -num_decomps 2 -tile_size '{16,16}' -prog_order CPRL \
    -tileparts C -tlm_marker true
  [ "$(count_marker tile-parts-c.j2c ff90)" -eq 12 ] \
    || fail "tile-parts-c.j2c does not have 12 tile-parts: $(count_marker tile-parts-c.j2c ff90)"
  expect_markers tile-parts-c.j2c "* ff55:* ff90:*"
  # Both: 9 for each tile.
  roundtrip tile-parts-rc rgb8.ppm 2304 -reversible true -num_decomps 2 -tile_size '{16,16}' -prog_order LRCP \
    -tileparts RC
  [ "$(count_marker tile-parts-rc.j2c ff90)" -eq 36 ] \
    || fail "tile-parts-rc.j2c does not have 36 tile-parts: $(count_marker tile-parts-rc.j2c ff90)"
  ok "-tile_size {16,16}: 4 tiles; 12 tile-parts with -tileparts R or C, 36 with RC; TLM (FF55) with -tlm_marker true"

  msg "16-bit PPM input"
  roundtrip rgb16 rgb16.ppm 4608 -reversible true -num_decomps 2
  expect_dump rgb16.j2c "numcomps=3" "prec=16"
  ok "the 16-bit round-trip is bit-exact"

  msg "yuv and raw input"
  compress "4:2:0" yuv420.yuv yuv420.j2c -reversible true -num_decomps 2 -dims '{32,24}' -num_comps 3 \
    -signed false,false,false -bit_depth 8,8,8 -downsamp '{1,1},{2,2},{2,2}'
  expect_dump yuv420.j2c "numcomps=3" "dx=1, dy=1" "dx=2, dy=2" "mct=0"
  expand "4:2:0" yuv420.j2c yuv420.ojph.yuv
  cmp -s yuv420.yuv yuv420.ojph.yuv || fail "4:2:0: the lossless round-trip changed the samples"
  # opj_decompress one component at a time: it converts the three of them from
  # sYCC to RGB otherwise (see scripts/verify-openjpeg.sh).
  for component in 0 1 2; do
    decompress "4:2:0, component $component" yuv420.j2c "yuv420-$component.raw" -c "$component"
  done
  cat yuv420-0.raw yuv420-1.raw yuv420-2.raw > yuv420.opj.yuv
  cmp -s yuv420.yuv yuv420.opj.yuv || fail "4:2:0: opj_decompress does not decode the samples of the source"
  ok "-dims {32,24} -num_comps 3 -signed false,false,false -bit_depth 8,8,8 -downsamp {1,1},{2,2},{2,2} round-trips bit-exactly"
  # A sign, a precision and a size per component. opj_decompress writes a PGX
  # file for each of them, most significant byte first.
  compress "planes" planes.yuv planes.j2c -reversible true -num_decomps 2 -dims '{32,24}' -num_comps 3 \
    -signed true,false,false -bit_depth 12,8,8 -downsamp '{1,1},{1,2},{2,2}'
  rm -f planes_*.pgx
  run "planes" planes_0.pgx "$OPJ_DECOMPRESS" -i planes.j2c -o planes.pgx
  [ "$(head -n 1 planes_0.pgx)" = "PG ML - 12 32 24" ] || fail "planes_0.pgx: $(head -n 1 planes_0.pgx)"
  [ "$(head -n 1 planes_1.pgx)" = "PG ML + 8 32 12" ] || fail "planes_1.pgx: $(head -n 1 planes_1.pgx)"
  [ "$(head -n 1 planes_2.pgx)" = "PG ML + 8 16 12" ] || fail "planes_2.pgx: $(head -n 1 planes_2.pgx)"
  { tail -c 1536 planes_0.pgx; tail -c 384 planes_1.pgx; tail -c 192 planes_2.pgx; } > planes.opj.raw
  { cat plane12.raw; tail -c 576 planes.yuv; } > planes.expected.raw
  cmp -s planes.expected.raw planes.opj.raw || fail "planes: the PGX files do not hold the samples of the source"
  ok "-signed true,false,false -bit_depth 12,8,8 -downsamp {1,1},{1,2},{2,2}: a signed 12-bit 32x24 and unsigned 8-bit 32x12 and 16x12 components"
  # A .raw file is a .yuv file of one component.
  compress "raw" signed8.raw signed8.j2c -reversible true -num_decomps 2 -dims '{32,24}' -num_comps 1 -signed true \
    -bit_depth 8 -downsamp '{1,1}'
  expect_dump signed8.j2c "numcomps=1" "sgnd=1"
  expand "raw" signed8.j2c signed8.ojph.raw
  cmp -s signed8.raw signed8.ojph.raw || fail "raw: the lossless round-trip changed the samples"
  decompress "raw" signed8.j2c signed8.opj.raw
  cmp -s signed8.raw signed8.opj.raw || fail "raw: opj_decompress does not decode the samples of the source"
  ok "a signed 8-bit .raw file round-trips bit-exactly"
  # The same file as a .yuv one: its samples are read as 0 to 255, and the ones
  # above 127 are clipped.
  cp signed8.raw signed8.yuv
  compress "yuv" signed8.yuv signed8-yuv.j2c -reversible true -num_decomps 2 -dims '{32,24}' -num_comps 1 -signed true \
    -bit_depth 8 -downsamp '{1,1}'
  expect_dump signed8-yuv.j2c "numcomps=1" "sgnd=1"
  decompress "yuv" signed8-yuv.j2c signed8-yuv.opj.raw
  if cmp -s signed8.raw signed8-yuv.opj.raw; then fail "the samples of a .yuv file are read with their sign"; fi
  ok "the samples of a signed component are read without their sign from a .yuv file"

  # See the header of this script. An 8x8 image without decomposition is one
  # code-block in one packet, whose header says how many coding passes it has.
  msg "coding passes"
  compress "one code-block" block.pgm block-reversible.j2c -reversible true -num_decomps 0
  compress "one code-block" block.pgm block-irreversible.j2c -reversible false -qstep 0.01 -num_decomps 0
  compress "one code-block" block.pgm block-coarse.j2c -reversible false -qstep 0.2 -num_decomps 0
  compress "one code-block" block.pgm block-qfactor.j2c -reversible false -qfactor 20 -num_decomps 0
  for codestream in block-reversible block-irreversible block-coarse block-qfactor; do
    passes="$(coding_passes "$codestream.j2c")" || fail "$codestream.j2c: could not read the header of its packet"
    [ "$passes" -eq 1 ] || fail "$codestream.j2c: $passes coding passes, ojph_compress writes refinement passes"
  done
  # The same image coded by opj_compress, whose code-blocks are not HT ones: a
  # cleanup pass for the first bit-plane and 3 passes for each of the other ones.
  run "one code-block" block-opj.j2k "$OPJ_COMPRESS" -i block.pgm -o block-opj.j2k -n 1
  passes="$(coding_passes block-opj.j2k)" || fail "block-opj.j2k: could not read the header of its packet"
  [ "$passes" -eq 22 ] || fail "block-opj.j2k: $passes coding passes instead of the 22 of 8 bit-planes"
  ok "ojph_compress writes 1 coding pass per code-block, the HT cleanup pass, and no SigProp or MagRef pass"
  ok "opj_compress writes 22 passes for the same code-block"

  msg "refusals"
  for extension in png tif; do
    rejects "$extension output" "refused.$extension" "$OJPH_EXPAND" -i reversible.j2c -o "refused.$extension"
    contains "$(cat tool.log)" "unknown output file extension" \
      || { cat tool.log >&2; fail "ojph_expand does not say that it writes no $extension file"; }
  done
  printf 'II*\0' > refused-input.tif
  rejects "tif input" refused.j2c "$OJPH_COMPRESS" -i refused-input.tif -o refused.j2c
  contains "$(cat tool.log)" "unknown input file extension" \
    || { cat tool.log >&2; fail "ojph_compress does not say that it reads no tif file"; }
  rejects "an unknown option" refused.j2c "$OJPH_COMPRESS" -i rgb8.ppm -o refused.j2c -reversible true -unknown 1
  ok "PNG and TIFF files and an unknown option are refused"

  cd ..
  ok "all smoke tests passed"
}

# The 64x64 image coded with -qstep 0.01 decodes with a PSNR of 48 dB.
IRREVERSIBLE_PSNR=43

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_linkage "$OJPH_COMPRESS"
    assert_linkage "$OJPH_EXPAND"
    ;;
esac

case "$MODE" in
  run|all)
    msg "usage"
    assert_usage ojph_compress "$OJPH_COMPRESS" "-i input file name (either pgm, ppm, pfm, or raw(yuv))" \
      -num_decomps -qstep -qfactor -reversible -colour_trans -prog_order -block_size -precincts -tile_offset \
      -tile_size -image_offset -tileparts -tlm_marker -profile -com -dims -num_comps -signed -bit_depth -downsamp
    assert_usage ojph_expand "$OJPH_EXPAND" "-o <output file name> (either pgm, ppm, or raw(yuv))" \
      -skip_res -resilient
    smoke_test
    ;;
esac

msg "verification passed for $TARGET ($MODE)"
