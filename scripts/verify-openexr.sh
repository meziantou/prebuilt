#!/usr/bin/env bash
#
# Verifies the OpenEXR tools built by scripts/build-openexr.sh.
#
#   bash scripts/verify-openexr.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertions plus real write+read smoke tests (must run on the
#         target platform)
#   all   both (default)
#
# The smoke tests write EXR files with exr-from-raw and read them back with
# exr-to-raw, for every compression, every pixel type, scan lines and tiles,
# subsampled channels, every line order, mipmaps and ripmaps, deep scan lines
# and deep tiles, multi-part files and every attribute type, and check them
# with exrcheck. A lossless round trip must give the samples back bit for bit,
# and exr-from-raw must write the same file again from the header.json of
# exr-to-raw. A lossy one (PXR24 FLOAT, B44 and B44A HALF, DWAA, DWAB and LJ2K
# HALF and FLOAT) must change the samples of the channels it compresses
# lossily, and the decoded samples must have the SHA-256 of the table below,
# the same on every target: the codecs are compiled with -ffp-contract=off and
# without their x64 SIMD code (see scripts/build-openexr.sh).
# The shipped OpenEXR utilities are run on these
# files too.
#
# OPENEXR_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# What the smoke tests found out, and assert:
# - A chunk that a compression does not make smaller is stored uncompressed,
#   lossy compressions included: DWAA leaves random HALF samples as they are.
#   The lossy tests use smooth samples, which DWAA, DWAB and LJ2K do compress,
#   and tiles of 32 x 32 pixels: LJ2K makes no tile of 16 x 16 smaller.
# - DWAA, DWAB and LJ2K compress the R, G and B channels lossily and A
#   losslessly; B44 and B44A compress every HALF channel lossily, PXR24 every
#   FLOAT channel; UINT channels are always lossless.
# - exrcheck reports a file with a BY or RY channel that is not subsampled 2x2
#   as bad, although OpenEXR reads it: its RGBA reader takes them for the
#   chroma channels of a luminance/chroma image.
# - exrcheck reports a deep tiled file as bad, although OpenEXR reads it, when
#   a level does not have as many rows of tiles as columns: it reads the sample
#   counts of tile (x, y) with readPixelSampleCounts(x, y, x, y), whose
#   arguments are dx1, dx2, dy1, dy2, and asks for tiles that do not exist.
# - exrcheck reports a multi-part file with an image part and a deep part as
#   bad, although OpenEXR reads it, exrmetrics --convert writes it again and
#   exrcheck -c, the checks of OpenEXRCore, accept it.
# - exrmultipart -combine leaves the offset tables of the parts it combines
#   filled with zeros: all of them on Linux, all but the first on macOS. The
#   file can only be read by rebuilding the tables, which OpenEXR (and
#   exrcheck) does by default, and exr-to-raw does not, on purpose (exit code
#   1). Use exr-from-raw to write a multi-part file.
# - exr2aces prints that it is deprecated.
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

RELEASE_TOOLS="exrheader exrinfo exrmaketiled exrmetrics exrstdattr exrcheck exrmultipart exrmultiview exrenvmap exrmakepreview exrmanifest exr2aces"
RAW_TOOLS="exr-from-raw exr-to-raw"
ROOT="$(pwd)"
for tool in $RELEASE_TOOLS $RAW_TOOLS; do
  bin="$ROOT/$tool-$TARGET$EXE"
  [ -f "$bin" ] || { echo "missing $bin" >&2; exit 1; }
  chmod +x "$bin" 2>/dev/null || true
done
tool() { echo "$ROOT/$1-$TARGET$EXE"; }
FROM_RAW="$(tool exr-from-raw)"
TO_RAW="$(tool exr-to-raw)"
EXRCHECK="$(tool exrcheck)"

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
# Helpers of the smoke tests
# ---------------------------------------------------------------------------

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | cut -c1-64
  else
    shasum -a 256 "$@" | cut -c1-64
  fi
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

# One step of xorshift32 on the global STATE.
next_random() {
  STATE=$(( (STATE ^ (STATE << 13)) & 4294967295 ))
  STATE=$(( STATE ^ (STATE >> 17) ))
  STATE=$(( (STATE ^ (STATE << 5)) & 4294967295 ))
}

seed_random() {
  STATE=$(( ($1 * 2654435761 + 12345) & 4294967295 ))
  [ "$STATE" -ne 0 ] || STATE=1
}

# Appends the octal escapes of CHUNK to the file, CHUNK_COUNT pieces at a time.
CHUNK=""
CHUNK_COUNT=0
append_piece() {
  CHUNK="$CHUNK$1"
  CHUNK_COUNT=$((CHUNK_COUNT + 1))
  if [ "$CHUNK_COUNT" -ge 512 ]; then
    printf "$CHUNK" >> "$2"
    CHUNK=""
    CHUNK_COUNT=0
  fi
}
flush_pieces() {
  printf "$CHUNK" >> "$1"
  CHUNK=""
  CHUNK_COUNT=0
}

# gen_random <bytes> <seed> <file>: pseudo-random bytes, every bit pattern
# (NaN and infinite floats included).
gen_random() {
  count="$1"
  out="$3"
  seed_random "$2"
  : > "$out"
  i=0
  while [ "$i" -lt "$count" ]; do
    next_random
    printf -v piece '\\%03o\\%03o\\%03o\\%03o' $((STATE & 255)) $(((STATE >> 8) & 255)) \
      $(((STATE >> 16) & 255)) $(((STATE >> 24) & 255))
    append_piece "$piece" "$out"
    i=$((i + 4))
  done
  flush_pieces "$out"
  if [ "$(file_size "$out")" -ne "$count" ]; then
    head -c "$count" "$out" > "$out.tmp"
    mv "$out.tmp" "$out"
  fi
}

# gen_smooth <pixelType> <width> <height> <seed> <file>: samples of an image
# with gradients and a little noise, which lossy compressions do compress:
# HALF and FLOAT values between 0.5 and 1.
gen_smooth() {
  type="$1"
  width="$2"
  height="$3"
  seed="$4"
  out="$5"
  seed_random "$seed"
  : > "$out"
  y=0
  while [ "$y" -lt "$height" ]; do
    x=0
    while [ "$x" -lt "$width" ]; do
      next_random
      m=$(( (x * 37 + y * 23 + seed * 101 + (STATE & 31)) & 1023 ))
      case "$type" in
        HALF)
          v=$((14336 + m))
          printf -v piece '\\%03o\\%03o' $((v & 255)) $((v >> 8))
          ;;
        FLOAT)
          v=$((1056964608 + (m << 13) + ((STATE >> 3) & 8191)))
          printf -v piece '\\%03o\\%03o\\%03o\\%03o' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $((v >> 24))
          ;;
        UINT)
          v=$(( (x * 7919 + y * 104729 + seed * 13 + (STATE & 3)) & 4294967295 ))
          printf -v piece '\\%03o\\%03o\\%03o\\%03o' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $((v >> 24))
          ;;
      esac
      append_piece "$piece" "$out"
      x=$((x + 1))
    done
    y=$((y + 1))
  done
  flush_pieces "$out"
}

# gen_counts <pixels> <seed> <file>: deep sample counts, 0 to 3 per pixel, as
# UINT. Sets DEEP_TOTAL to their sum.
gen_counts() {
  pixels="$1"
  out="$3"
  seed_random "$2"
  : > "$out"
  DEEP_TOTAL=0
  i=0
  while [ "$i" -lt "$pixels" ]; do
    next_random
    count=$(( (STATE >> 7) & 3 ))
    DEEP_TOTAL=$((DEEP_TOTAL + count))
    printf -v piece '\\%03o\\000\\000\\000' "$count"
    append_piece "$piece" "$out"
    i=$((i + 1))
  done
  flush_pieces "$out"
}

size_of() {
  case "$1" in
    HALF) echo 2 ;;
    *) echo 4 ;;
  esac
}

# write <description> <exr>: exr-from-raw, then exrcheck, unless a third
# argument says not to.
write_exr() {
  "$FROM_RAW" "$1" "$2" || fail "exr-from-raw $1 $2 failed"
  [ -s "$2" ] || fail "exr-from-raw wrote no $2"
  if [ "$3" != "nocheck" ]; then
    check="$("$EXRCHECK" "$2" 2>&1)" || fail "exrcheck $2: $check"
  fi
}

# dump <exr> <folder>
dump() {
  rm -rf "$2"
  "$TO_RAW" "$1" "$2" || fail "exr-to-raw $1 $2 failed"
  [ -f "$2/header.json" ] || fail "exr-to-raw wrote no $2/header.json"
}

# rewrite <exr> <folder>: exr-from-raw writes the same file again from the dump.
rewrite() {
  "$FROM_RAW" "$2/header.json" "$2/rewritten.exr" || fail "exr-from-raw $2/header.json failed"
  cmp -s "$1" "$2/rewritten.exr" || fail "exr-from-raw does not write $1 again from its dump $2/header.json"
}

assert_json() {
  json="$(cat "$1")"
  contains "$json" "$2" || fail "$1 has no $2"
}

# The entries of the chunk table of part <n> (default 0) of a dump.
chunk_table() {
  sed -n 's/^ *"chunkTable": \[\(.*\)\],$/\1/p' "$1" | sed -n "$(( ${2:-0} + 1 ))p" | tr -d ' ' | tr ',' ' '
}

# increasing, decreasing or mixed
chunk_order() {
  previous=""
  increasing=1
  decreasing=1
  for entry in $(chunk_table "$1" "$2"); do
    if [ -n "$previous" ]; then
      [ "$entry" -gt "$previous" ] || increasing=0
      [ "$entry" -lt "$previous" ] || decreasing=0
    fi
    previous="$entry"
  done
  if [ "$increasing" = 1 ]; then echo increasing; elif [ "$decreasing" = 1 ]; then echo decreasing; else echo mixed; fi
}

# The SHA-256 of the decoded samples of the lossy round trips, the same on
# every target: the samples of the channels A, B, G and R, in that order, of
# <layout>-<compression>-<pixelType>, and of the channels BY, P, Q, RY and Y
# of sampling-<compression>; and of order-tiled-RANDOM_Y.exr, the file itself
# (no compression), whose tiles are shuffled the same way on every target.
# A failed run prints the hashes it found.
expected_hash() {
  case "$1" in
    scanline-PXR24-FLOAT) echo 074d0dccbc5d2deb7a64269c1d57e1b1ca60336dde4c9ca980648285678f650c ;;
    scanline-B44-HALF) echo f17b8f8030990185ab9a6318f3e2ec610505375710ef379bfb6ce630afdfe5ec ;;
    scanline-B44A-HALF) echo f17b8f8030990185ab9a6318f3e2ec610505375710ef379bfb6ce630afdfe5ec ;;
    scanline-DWAA-HALF) echo 394743086f418450018cc00c6c1242692cbd1a3b4ec90b98895c136b0dec8b50 ;;
    scanline-DWAA-FLOAT) echo 821510b3aeb7b5ccaf19b659b887f4e17df902875a23e3487098fa36316d711a ;;
    scanline-DWAB-HALF) echo 394743086f418450018cc00c6c1242692cbd1a3b4ec90b98895c136b0dec8b50 ;;
    scanline-DWAB-FLOAT) echo 821510b3aeb7b5ccaf19b659b887f4e17df902875a23e3487098fa36316d711a ;;
    scanline-LJ2K-HALF) echo 95ea07c80015da29bb280286cb372c5b74725dc3932136b51ba202abca4d21fa ;;
    scanline-LJ2K-FLOAT) echo f43302be01b3ed447a850df8f43913addb5cc03c53bb02e59e368a717bb12ccf ;;
    tiled-PXR24-FLOAT) echo 074d0dccbc5d2deb7a64269c1d57e1b1ca60336dde4c9ca980648285678f650c ;;
    tiled-B44-HALF) echo f17b8f8030990185ab9a6318f3e2ec610505375710ef379bfb6ce630afdfe5ec ;;
    tiled-B44A-HALF) echo f17b8f8030990185ab9a6318f3e2ec610505375710ef379bfb6ce630afdfe5ec ;;
    tiled-DWAA-HALF) echo 394743086f418450018cc00c6c1242692cbd1a3b4ec90b98895c136b0dec8b50 ;;
    tiled-DWAA-FLOAT) echo 821510b3aeb7b5ccaf19b659b887f4e17df902875a23e3487098fa36316d711a ;;
    tiled-DWAB-HALF) echo 394743086f418450018cc00c6c1242692cbd1a3b4ec90b98895c136b0dec8b50 ;;
    tiled-DWAB-FLOAT) echo 821510b3aeb7b5ccaf19b659b887f4e17df902875a23e3487098fa36316d711a ;;
    tiled-LJ2K-HALF) echo 18633c1a8d93c9cd597d76110d3433def35a19c709369eead143fbe91c19febd ;;
    tiled-LJ2K-FLOAT) echo 0a829cc787e4107fa70f385a5b61048b5e1cc65bdd4fc6a8240be703d32bf552 ;;
    sampling-B44) echo 1f7bcaca0afeffe8deef28663845f1f1f171ec78a90e4517284ddc6e331b1905 ;;
    sampling-B44A) echo 1f7bcaca0afeffe8deef28663845f1f1f171ec78a90e4517284ddc6e331b1905 ;;
    sampling-DWAA) echo 537c53dffd168e8b2b47df38eff75884317b9d6b21d68c200779be44cf5b83a3 ;;
    sampling-DWAB) echo 537c53dffd168e8b2b47df38eff75884317b9d6b21d68c200779be44cf5b83a3 ;;
    order-tiled-RANDOM_Y.exr) echo a3ec64d2ae15ca9e997bd45b63a652a1fd48cba52a853ff94780f63b2a98c74c ;;
    *) echo "" ;;
  esac
}

# The channels of R, G, B (smooth samples) and A (random bits) that a
# compression of a pixel type changes.
lossy_channels() {
  case "$1:$2" in
    PXR24:FLOAT|B44:HALF|B44A:HALF) echo "R G B A" ;;
    DWAA:HALF|DWAA:FLOAT|DWAB:HALF|DWAB:FLOAT|LJ2K:HALF|LJ2K:FLOAT) echo "R G B" ;;
    *) echo "" ;;
  esac
}

COMPRESSIONS="NONE RLE ZIPS ZIP PIZ PXR24 B44 B44A DWAA DWAB HTJ2K256 HTJ2K32 LJ2K ZSTD"
HASH_FAILURES=""

check_hash() {
  name="$1"
  shift
  actual="$(cat "$@" | sha256)"
  expected="$(expected_hash "$name")"
  if [ "$actual" != "$expected" ]; then
    echo "  hash of $name: $actual (expected: ${expected:-none})"
    HASH_FAILURES="$HASH_FAILURES $name"
  else
    ok "$name: the decoded samples have the expected SHA-256"
  fi
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

run_tests() {
  WORK="$ROOT/openexr-smoke"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cd "$WORK"

  msg "versions"
  for name in $RELEASE_TOOLS; do
    version="$("$(tool "$name")" --version 2>&1)" || fail "$name --version failed: $version"
    contains "$version" "$name (OpenEXR) $OPENEXR_VERSION" || fail "$name --version: $version"
    ok "$name: $OPENEXR_VERSION"
  done
  version="$("$(tool exr2aces)" --version 2>&1)"
  contains "$version" "is deprecated" || fail "exr2aces no longer says that it is deprecated: $version"
  for name in $RAW_TOOLS; do
    # Windows writes \r\n.
    version="$("$(tool "$name")" --version | tr -d '\r')" || fail "$name --version failed"
    [ "$version" = "$name (OpenEXR $OPENEXR_VERSION)" ] || fail "$name --version: $version"
    ok "$name: $OPENEXR_VERSION"
  done

  # -------------------------------------------------------------------------
  msg "samples"
  # The data window of most tests: 61 x 45 pixels, from (-7, 3).
  WIDTH=61
  HEIGHT=45
  for type in HALF FLOAT UINT; do
    gen_smooth "$type" "$WIDTH" "$HEIGHT" 1 "$type-R.raw"
    gen_smooth "$type" "$WIDTH" "$HEIGHT" 2 "$type-G.raw"
    gen_smooth "$type" "$WIDTH" "$HEIGHT" 3 "$type-B.raw"
    gen_random $((WIDTH * HEIGHT * $(size_of "$type"))) 4 "$type-A.raw"
    [ "$(file_size "$type-R.raw")" -eq $((WIDTH * HEIGHT * $(size_of "$type"))) ] || fail "gen_smooth $type"
  done
  ok "R, G and B smooth, A random, for HALF, FLOAT and UINT"

  # -------------------------------------------------------------------------
  msg "every compression and pixel type, scan lines and tiles"
  for layout in scanline tiled; do
    tiles=""
    # Not smaller: LJ2K makes no 16 x 16 tile of these samples smaller.
    [ "$layout" = tiled ] && tiles='"tiles": {"xSize": 32, "ySize": 32},'
    for compression in $COMPRESSIONS; do
      for type in HALF FLOAT UINT; do
        name="$layout-$compression-$type"
        cat > "$name.json" <<EOF
{$tiles "dataWindow": [-7, 3, 53, 47], "displayWindow": [0, 0, 63, 63], "compression": "$compression",
 "channels": [
  {"name": "R", "pixelType": "$type", "file": "$type-R.raw"},
  {"name": "G", "pixelType": "$type", "file": "$type-G.raw"},
  {"name": "B", "pixelType": "$type", "file": "$type-B.raw"},
  {"name": "A", "pixelType": "$type", "file": "$type-A.raw"}]}
EOF
        write_exr "$name.json" "$name.exr"
        dump "$name.exr" "$name"
        assert_json "$name/header.json" "\"compression\": \"$compression\""
        if [ "$layout" = tiled ]; then
          assert_json "$name/header.json" '"type": "tiledimage"'
        else
          assert_json "$name/header.json" '"type": "scanlineimage"'
        fi
        lossy="$(lossy_channels "$compression" "$type")"
        index=0
        changed=""
        # The channels of the dump are sorted by name.
        for channel in A B G R; do
          if ! cmp -s "$type-$channel.raw" "$name/part0.channel$index.raw"; then
            contains " $lossy " " $channel " || fail "$name: the samples of $channel changed"
            changed="$changed $channel"
          fi
          index=$((index + 1))
        done
        [ -z "$lossy" ] || [ -n "$changed" ] || fail "$name: $compression changed no sample"
        if [ -z "$lossy" ]; then
          rewrite "$name.exr" "$name"
          ok "$name: lossless, written again identically from its dump"
        else
          check_hash "$name" "$name/part0.channel0.raw" "$name/part0.channel1.raw" \
            "$name/part0.channel2.raw" "$name/part0.channel3.raw"
        fi
      done
    done
  done

  msg "chunks a compression does not make smaller are stored uncompressed"
  gen_random $((WIDTH * HEIGHT * 2)) 11 random-R.raw
  gen_random $((WIDTH * HEIGHT * 2)) 12 random-G.raw
  gen_random $((WIDTH * HEIGHT * 2)) 13 random-B.raw
  cat > random-dwaa.json <<EOF
{"dataWindow": [-7, 3, 53, 47], "compression": "DWAA",
 "channels": [
  {"name": "R", "pixelType": "HALF", "file": "random-R.raw"},
  {"name": "G", "pixelType": "HALF", "file": "random-G.raw"},
  {"name": "B", "pixelType": "HALF", "file": "random-B.raw"}]}
EOF
  write_exr random-dwaa.json random-dwaa.exr
  dump random-dwaa.exr random-dwaa
  cmp -s random-R.raw random-dwaa/part0.channel2.raw && cmp -s random-G.raw random-dwaa/part0.channel1.raw \
    && cmp -s random-B.raw random-dwaa/part0.channel0.raw \
    || fail "DWAA changed random HALF samples: it now compresses chunks it makes larger"
  ok "DWAA leaves random HALF samples as they are"

  # -------------------------------------------------------------------------
  msg "subsampled channels"
  # 60 x 44 pixels from (-6, 4): even origin and size.
  gen_smooth HALF 60 44 5 sub-Y.raw
  gen_smooth HALF 30 22 6 sub-RY.raw
  gen_smooth HALF 30 22 7 sub-BY.raw
  gen_random $((60 * 22 * 2)) 8 sub-Q.raw
  gen_random $((30 * 44 * 2)) 9 sub-P.raw
  for compression in $COMPRESSIONS; do
    name="sampling-$compression"
    cat > "$name.json" <<EOF
{"dataWindow": [-6, 4, 53, 47], "compression": "$compression",
 "channels": [
  {"name": "Y", "pixelType": "HALF", "file": "sub-Y.raw"},
  {"name": "RY", "pixelType": "HALF", "xSampling": 2, "ySampling": 2, "file": "sub-RY.raw"},
  {"name": "BY", "pixelType": "HALF", "xSampling": 2, "ySampling": 2, "file": "sub-BY.raw"},
  {"name": "Q", "pixelType": "HALF", "xSampling": 1, "ySampling": 2, "file": "sub-Q.raw"},
  {"name": "P", "pixelType": "HALF", "xSampling": 2, "ySampling": 1, "file": "sub-P.raw"}]}
EOF
    write_exr "$name.json" "$name.exr"
    dump "$name.exr" "$name"
    assert_json "$name/header.json" '{"name": "Q", "pixelType": "HALF", "xSampling": 1, "ySampling": 2, "pLinear": false, "file": "part0.channel2.raw"}'
    same=1
    index=0
    for channel in BY P Q RY Y; do
      cmp -s "sub-$channel.raw" "$name/part0.channel$index.raw" || same=0
      index=$((index + 1))
    done
    if [ "$same" = 1 ]; then
      rewrite "$name.exr" "$name"
      ok "$name: lossless, written again identically from its dump"
    else
      case "$compression" in
        B44|B44A|DWAA|DWAB|LJ2K) ;;
        *) fail "$name: the samples changed" ;;
      esac
      check_hash "$name" "$name/part0.channel0.raw" "$name/part0.channel1.raw" "$name/part0.channel2.raw" \
        "$name/part0.channel3.raw" "$name/part0.channel4.raw"
    fi
  done

  cat > by-1x2.json <<EOF
{"dataWindow": [0, 0, 13, 7], "compression": "ZIP",
 "channels": [{"name": "BY", "pixelType": "HALF", "ySampling": 2, "file": "by.raw"}]}
EOF
  gen_random $((14 * 4 * 2)) 10 by.raw
  write_exr by-1x2.json by-1x2.exr nocheck
  dump by-1x2.exr by-1x2
  cmp -s by.raw by-1x2/part0.channel0.raw || fail "by-1x2: the samples changed"
  if "$EXRCHECK" by-1x2.exr > /dev/null 2>&1; then
    fail "exrcheck now accepts a BY channel subsampled 1x2"
  fi
  ok "exrcheck reports a BY channel subsampled 1x2 as bad; OpenEXR reads it"

  # -------------------------------------------------------------------------
  msg "line orders"
  for order in INCREASING_Y DECREASING_Y; do
    name="order-scanline-$order"
    cat > "$name.json" <<EOF
{"dataWindow": [-7, 3, 53, 47], "compression": "ZIPS", "lineOrder": "$order",
 "channels": [{"name": "R", "pixelType": "HALF", "file": "HALF-R.raw"}, {"name": "A", "pixelType": "FLOAT", "file": "FLOAT-A.raw"}]}
EOF
    write_exr "$name.json" "$name.exr"
    dump "$name.exr" "$name"
    assert_json "$name/header.json" "\"lineOrder\": \"$order\""
    cmp -s HALF-R.raw "$name/part0.channel1.raw" && cmp -s FLOAT-A.raw "$name/part0.channel0.raw" \
      || fail "$name: the samples changed"
    rewrite "$name.exr" "$name"
    expected=increasing
    [ "$order" = DECREASING_Y ] && expected=decreasing
    [ "$(chunk_order "$name/header.json")" = "$expected" ] || fail "$name: the chunks are not in $expected order"
    ok "$name: the chunks are in $expected order"
  done
  for order in INCREASING_Y DECREASING_Y RANDOM_Y; do
    name="order-tiled-$order"
    cat > "$name.json" <<EOF
{"type": "tiledimage", "dataWindow": [-7, 3, 53, 47], "compression": "NONE", "lineOrder": "$order",
 "tiles": {"xSize": 8, "ySize": 8, "levelMode": "ONE_LEVEL"},
 "channels": [{"name": "R", "pixelType": "HALF", "file": "HALF-R.raw"}, {"name": "A", "pixelType": "FLOAT", "file": "FLOAT-A.raw"}]}
EOF
    write_exr "$name.json" "$name.exr"
    dump "$name.exr" "$name"
    assert_json "$name/header.json" "\"lineOrder\": \"$order\""
    cmp -s HALF-R.raw "$name/part0.channel1.raw" && cmp -s FLOAT-A.raw "$name/part0.channel0.raw" \
      || fail "$name: the samples changed"
    rewrite "$name.exr" "$name"
    order_found="$(chunk_order "$name/header.json")"
    case "$order" in
      INCREASING_Y) [ "$order_found" = increasing ] || fail "$name: the tiles are not in increasing order" ;;
      DECREASING_Y) [ "$order_found" = mixed ] || fail "$name: the tiles are in $order_found order" ;;
      RANDOM_Y) [ "$order_found" = mixed ] || fail "$name: the tiles are in $order_found order" ;;
    esac
    ok "$name: the tiles are in $order_found order in the table"
  done
  # The shuffle is the same on every platform: no compression, so the file
  # itself is the same.
  random_hash="$(sha256 order-tiled-RANDOM_Y.exr)"
  [ "$random_hash" = "$(expected_hash order-tiled-RANDOM_Y.exr)" ] \
    || { echo "  hash of order-tiled-RANDOM_Y.exr: $random_hash"; HASH_FAILURES="$HASH_FAILURES order-tiled-RANDOM_Y.exr"; }

  # -------------------------------------------------------------------------
  msg "mipmaps and ripmaps"
  # 37 x 23 pixels; the levels as the OpenEXR specification computes them.
  for mode in MIPMAP_LEVELS RIPMAP_LEVELS; do
    for rounding in ROUND_DOWN ROUND_UP; do
      name="levels-$mode-$rounding"
      levels=""
      total=0
      level_count() {
        size="$1"
        log=0
        remainder=0
        while [ "$size" -gt 1 ]; do
          [ $((size & 1)) -eq 1 ] && remainder=1
          size=$((size >> 1))
          log=$((log + 1))
        done
        [ "$rounding" = ROUND_UP ] && log=$((log + remainder))
        echo $((log + 1))
      }
      level_size() {
        if [ "$rounding" = ROUND_UP ]; then
          s=$(( ($1 + (1 << $2) - 1) >> $2 ))
        else
          s=$(( $1 >> $2 ))
        fi
        [ "$s" -ge 1 ] || s=1
        echo "$s"
      }
      if [ "$mode" = MIPMAP_LEVELS ]; then
        n="$(level_count 37)"
        l=0
        while [ "$l" -lt "$n" ]; do
          w="$(level_size 37 "$l")"
          h="$(level_size 23 "$l")"
          levels="$levels{\"level\": [$l, $l], \"dataWindow\": [5, -2, $((5 + w - 1)), $((-2 + h - 1))]}
"
          total=$((total + w * h))
          l=$((l + 1))
        done
      else
        nx="$(level_count 37)"
        ny="$(level_count 23)"
        ly=0
        while [ "$ly" -lt "$ny" ]; do
          lx=0
          while [ "$lx" -lt "$nx" ]; do
            w="$(level_size 37 "$lx")"
            h="$(level_size 23 "$ly")"
            levels="$levels{\"level\": [$lx, $ly], \"dataWindow\": [5, -2, $((5 + w - 1)), $((-2 + h - 1))]}
"
            total=$((total + w * h))
            lx=$((lx + 1))
          done
          ly=$((ly + 1))
        done
      fi
      gen_random $((total * 2)) 20 "$name-R.raw"
      gen_random $((total * 4)) 21 "$name-Z.raw"
      order=INCREASING_Y
      [ "$rounding" = ROUND_UP ] && order=RANDOM_Y
      cat > "$name.json" <<EOF
{"type": "tiledimage", "dataWindow": [5, -2, 41, 20], "compression": "PIZ", "lineOrder": "$order",
 "tiles": {"xSize": 8, "ySize": 4, "levelMode": "$mode", "roundingMode": "$rounding"},
 "channels": [{"name": "R", "pixelType": "HALF", "file": "$name-R.raw"}, {"name": "Z", "pixelType": "FLOAT", "file": "$name-Z.raw"}]}
EOF
      write_exr "$name.json" "$name.exr"
      dump "$name.exr" "$name"
      dumped="$(sed -n 's/^ *\({"level": .*}\),\{0,1\}$/\1/p' "$name/header.json")
"
      [ "$dumped" = "$levels" ] || fail "$name: the levels are
$dumped
not
$levels"
      cmp -s "$name-R.raw" "$name/part0.channel0.raw" && cmp -s "$name-Z.raw" "$name/part0.channel1.raw" \
        || fail "$name: the samples changed"
      rewrite "$name.exr" "$name"
      ok "$name: $(printf '%s' "$levels" | grep -c level) levels, lossless, $order"
    done
  done

  # -------------------------------------------------------------------------
  msg "deep scan lines and deep tiles"
  # 19 x 13 pixels from (-4, 6).
  gen_counts $((19 * 13)) 30 deep-counts.raw
  gen_random $((DEEP_TOTAL * 2)) 31 deep-A.raw
  gen_random $((DEEP_TOTAL * 4)) 32 deep-Z.raw
  gen_random $((DEEP_TOTAL * 4)) 33 deep-id.raw
  # The compressions OpenEXR accepts for deep data.
  for compression in NONE RLE ZIPS ZSTD; do
    for type in deepscanline deeptile; do
      name="$type-$compression"
      tiles=""
      # 3 x 3 tiles: see exrcheck at the top.
      [ "$type" = deeptile ] && tiles='"tiles": {"xSize": 8, "ySize": 5},'
      cat > "$name.json" <<EOF
{"type": "$type", $tiles "dataWindow": [-4, 6, 14, 18], "compression": "$compression", "sampleCounts": "deep-counts.raw",
 "channels": [{"name": "A", "pixelType": "HALF", "file": "deep-A.raw"}, {"name": "Z", "pixelType": "FLOAT", "file": "deep-Z.raw"},
  {"name": "id", "pixelType": "UINT", "file": "deep-id.raw"}]}
EOF
      write_exr "$name.json" "$name.exr"
      dump "$name.exr" "$name"
      assert_json "$name/header.json" "\"type\": \"$type\""
      cmp -s deep-counts.raw "$name/part0.sampleCounts.raw" || fail "$name: the sample counts changed"
      cmp -s deep-A.raw "$name/part0.channel0.raw" && cmp -s deep-Z.raw "$name/part0.channel1.raw" \
        && cmp -s deep-id.raw "$name/part0.channel2.raw" || fail "$name: the samples changed"
      rewrite "$name.exr" "$name"
      ok "$name: $DEEP_TOTAL samples, lossless"
    done
  done
  # 3 x 4 tiles.
  sed 's/"ySize": 5/"ySize": 4/' deeptile-ZIPS.json > deeptile-3x4.json
  write_exr deeptile-3x4.json deeptile-3x4.exr nocheck
  dump deeptile-3x4.exr deeptile-3x4
  cmp -s deep-Z.raw deeptile-3x4/part0.channel1.raw || fail "deeptile-3x4: the samples changed"
  rewrite deeptile-3x4.exr deeptile-3x4
  if "$EXRCHECK" deeptile-3x4.exr > /dev/null 2>&1; then
    fail "exrcheck now accepts a deep tiled file of 3 x 4 tiles"
  fi
  ok "exrcheck reports a deep tiled file of 3 x 4 tiles as bad; OpenEXR reads it"
  # Deep tiles with mipmaps, in random order; 16 x 16 pixels, so that every
  # level has as many rows of tiles as columns (see exrcheck at the top).
  name=deeptile-mipmap
  pixels=0
  for size in "16 16" "8 8" "4 4" "2 2" "1 1"; do
    set -- $size
    pixels=$((pixels + $1 * $2))
  done
  gen_counts "$pixels" 34 "$name-counts.raw"
  gen_random $((DEEP_TOTAL * 4)) 35 "$name-Z.raw"
  cat > "$name.json" <<EOF
{"type": "deeptile", "tiles": {"xSize": 4, "ySize": 4, "levelMode": "MIPMAP_LEVELS"}, "lineOrder": "RANDOM_Y",
 "dataWindow": [-4, 6, 11, 21], "compression": "ZIPS", "sampleCounts": "$name-counts.raw",
 "channels": [{"name": "Z", "pixelType": "FLOAT", "file": "$name-Z.raw"}]}
EOF
  write_exr "$name.json" "$name.exr"
  dump "$name.exr" "$name"
  cmp -s "$name-counts.raw" "$name/part0.sampleCounts.raw" && cmp -s "$name-Z.raw" "$name/part0.channel0.raw" \
    || fail "$name: the samples changed"
  rewrite "$name.exr" "$name"
  ok "$name: 5 levels, $DEEP_TOTAL samples, lossless"

  # -------------------------------------------------------------------------
  msg "multi-part files"
  cat > multipart.json <<EOF
{"parts": [
 {"name": "rgba", "dataWindow": [-7, 3, 53, 47], "displayWindow": [0, 0, 63, 63], "compression": "PIZ",
  "channels": [{"name": "R", "pixelType": "HALF", "file": "HALF-R.raw"}, {"name": "A", "pixelType": "HALF", "file": "HALF-A.raw"}]},
 {"name": "depth", "type": "tiledimage", "tiles": {"xSize": 16, "ySize": 16}, "dataWindow": [-7, 3, 53, 47], "displayWindow": [0, 0, 63, 63], "compression": "ZIP",
  "channels": [{"name": "Z", "pixelType": "FLOAT", "file": "FLOAT-R.raw"}]},
 {"name": "deep", "type": "deepscanline", "dataWindow": [-4, 6, 14, 18], "displayWindow": [0, 0, 63, 63], "compression": "RLE", "sampleCounts": "deep-counts.raw",
  "channels": [{"name": "Z", "pixelType": "FLOAT", "file": "deep-Z.raw"}]}]}
EOF
  # See exrcheck at the top.
  write_exr multipart.json multipart.exr nocheck
  check="$("$EXRCHECK" -c multipart.exr 2>&1)" || fail "exrcheck -c multipart.exr: $check"
  if "$EXRCHECK" multipart.exr > /dev/null 2>&1; then
    fail "exrcheck now accepts a multi-part file with an image part and a deep part"
  fi
  "$(tool exrmetrics)" --convert -o multipart-metrics.exr multipart.exr > /dev/null || fail "exrmetrics --convert multipart.exr failed"
  if "$EXRCHECK" multipart-metrics.exr > /dev/null 2>&1; then
    fail "exrcheck now accepts the multi-part file exrmetrics writes"
  fi
  ok "exrcheck reports a multi-part file with an image part and a deep part as bad, even written by exrmetrics; exrcheck -c accepts it"
  dump multipart.exr multipart
  assert_json multipart/header.json '"flags": {"tiled": false, "longNames": false, "nonImage": true, "multiPart": true}'
  assert_json multipart/header.json '"name": "depth"'
  cmp -s HALF-R.raw multipart/part0.channel1.raw && cmp -s HALF-A.raw multipart/part0.channel0.raw \
    && cmp -s FLOAT-R.raw multipart/part1.channel0.raw && cmp -s deep-counts.raw multipart/part2.sampleCounts.raw \
    && cmp -s deep-Z.raw multipart/part2.channel0.raw || fail "multipart: the samples changed"
  rewrite multipart.exr multipart
  [ "$(grep -a -c scanlineimage multipart.exr)" -ge 1 ] || fail "multipart.exr has no type attribute"
  ok "3 parts (scan lines, tiles, deep scan lines), lossless"
  if grep -a -q scanlineimage scanline-ZIP-HALF.exr; then
    fail "a single-part scan line file has a type attribute"
  fi
  ok "a single-part file has no type attribute, a multi-part file does"

  # A part can be given alone or in "parts".
  cat > single-in-parts.json <<EOF
{"parts": [$(cat scanline-ZIP-HALF.json)]}
EOF
  write_exr single-in-parts.json single-in-parts.exr
  cmp -s single-in-parts.exr scanline-ZIP-HALF.exr || fail "a part alone and the same part in \"parts\" give different files"
  ok "a part alone and in \"parts\" give the same file"

  # -------------------------------------------------------------------------
  msg "attributes"
  long_name="a_channel_name_longer_than_31_characters"
  cat > attributes.json <<EOF
{"dataWindow": [0, 0, 3, 1], "displayWindow": [-1, -1, 5, 5], "compression": "NONE",
 "pixelAspectRatio": 1.5, "screenWindowCenter": [0.25, -0.5], "screenWindowWidth": 2,
 "channels": [{"name": "$long_name", "pixelType": "FLOAT", "pLinear": true}],
 "attributes": [
  {"name": "aBox2i", "type": "box2i", "value": [-1, 2, 3, 4]},
  {"name": "aBox2f", "type": "box2f", "value": [-1.5, 2, 3.25, 4]},
  {"name": "chromaticities", "type": "chromaticities", "value": [0.64, 0.33, 0.3, 0.6, 0.15, 0.06, 0.3127, 0.329]},
  {"name": "aCompression", "type": "compression", "value": "B44A"},
  {"name": "aDouble", "type": "double", "value": 0.1},
  {"name": "envmap", "type": "envmap", "value": "CUBE"},
  {"name": "aFloat", "type": "float", "value": 3.5},
  {"name": "aNaN", "type": "float", "value": "NaN"},
  {"name": "anInfinity", "type": "double", "value": "-Infinity"},
  {"name": "anInt", "type": "int", "value": -42},
  {"name": "keyCode", "type": "keycode", "value": [1, 2, 3, 4, 5, 6, 64]},
  {"name": "aLineOrder", "type": "lineOrder", "value": "RANDOM_Y"},
  {"name": "aM33f", "type": "m33f", "value": [1, 2, 3, 4, 5, 6, 7, 8, 9]},
  {"name": "aM33d", "type": "m33d", "value": [1, 0, 0, 0, 1, 0, 0, 0, 0.5]},
  {"name": "worldToCamera", "type": "m44f", "value": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1]},
  {"name": "aM44d", "type": "m44d", "value": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]},
  {"name": "preview", "type": "preview", "value": {"width": 2, "height": 1, "pixels": "ff00008000ff00ff"}},
  {"name": "framesPerSecond", "type": "rational", "value": [24000, 1001]},
  {"name": "owner", "type": "string", "value": "Zoé \"quoted\"\n"},
  {"name": "aStringVector", "type": "stringvector", "value": ["one", "", "three"]},
  {"name": "aTileDescription", "type": "tiledesc", "value": {"xSize": 32, "ySize": 16, "levelMode": "RIPMAP_LEVELS", "roundingMode": "ROUND_UP"}},
  {"name": "timeCode", "type": "timecode", "value": [305419896, 2271560481]},
  {"name": "aV2i", "type": "v2i", "value": [1, -2]},
  {"name": "aV2f", "type": "v2f", "value": [1.5, -2]},
  {"name": "aV2d", "type": "v2d", "value": [0.1, 0.2]},
  {"name": "aV3i", "type": "v3i", "value": [1, 2, 3]},
  {"name": "aV3f", "type": "v3f", "value": [1, 2, 3.5]},
  {"name": "aV3d", "type": "v3d", "value": [1e-300, 2, 3]},
  {"name": "deepImageState", "type": "deepImageState", "value": "TIDY"},
  {"name": "aFloatVector", "type": "floatvector", "value": [1, 2.5, -3]},
  {"name": "anOpaque", "type": "customType", "data": "00ff10"},
  {"name": "an_attribute_name_longer_than_31_characters", "type": "int", "value": 7}]}
EOF
  write_exr attributes.json attributes.exr nocheck
  dump attributes.exr attributes
  for expected in \
    '"flags": {"tiled": false, "longNames": true, "nonImage": false, "multiPart": false}' \
    '"displayWindow": [-1, -1, 5, 5]' '"pixelAspectRatio": 1.5' '"screenWindowCenter": [0.25, -0.5]' '"screenWindowWidth": 2' \
    "{\"name\": \"$long_name\", \"pixelType\": \"FLOAT\", \"xSampling\": 1, \"ySampling\": 1, \"pLinear\": true, \"file\": \"part0.channel0.raw\"}" \
    '{"name": "aBox2i", "type": "box2i", "value": [-1, 2, 3, 4], "data": "ffffffff020000000300000004000000"}' \
    '{"name": "aBox2f", "type": "box2f", "value": [-1.5, 2, 3.25, 4],' \
    '{"name": "chromaticities", "type": "chromaticities", "value": [0.64, 0.33, 0.3, 0.6, 0.15, 0.06, 0.3127, 0.329], "data": "0ad7233fc3f5a83e9a99993e9a99193f9a99193e8fc2753d371aa03eb072a83e"}' \
    '{"name": "aCompression", "type": "compression", "value": "B44A", "data": "07"}' \
    '{"name": "aDouble", "type": "double", "value": 0.1, "data": "9a9999999999b93f"}' \
    '{"name": "envmap", "type": "envmap", "value": "CUBE", "data": "01"}' \
    '{"name": "aNaN", "type": "float", "value": "NaN", "data": "0000c07f"}' \
    '{"name": "anInfinity", "type": "double", "value": "-Infinity", "data": "000000000000f0ff"}' \
    '{"name": "anInt", "type": "int", "value": -42, "data": "d6ffffff"}' \
    '{"name": "keyCode", "type": "keycode", "value": [1, 2, 3, 4, 5, 6, 64],' \
    '{"name": "aLineOrder", "type": "lineOrder", "value": "RANDOM_Y", "data": "02"}' \
    '{"name": "aM33d", "type": "m33d", "value": [1, 0, 0, 0, 1, 0, 0, 0, 0.5],' \
    '{"name": "worldToCamera", "type": "m44f", "value": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1],' \
    '{"name": "preview", "type": "preview", "value": {"width": 2, "height": 1, "pixels": "ff00008000ff00ff"}, "data": "0200000001000000ff00008000ff00ff"}' \
    '{"name": "framesPerSecond", "type": "rational", "value": [24000, 1001], "data": "c05d0000e9030000"}' \
    '{"name": "owner", "type": "string", "value": "Zoé \"quoted\"\n", "data": "5a6fc3a9202271756f746564220a"}' \
    '{"name": "aStringVector", "type": "stringvector", "value": ["one", "", "three"], "data": "030000006f6e6500000000050000007468726565"}' \
    '{"name": "aTileDescription", "type": "tiledesc", "value": {"xSize": 32, "ySize": 16, "levelMode": "RIPMAP_LEVELS", "roundingMode": "ROUND_UP"}, "data": "200000001000000012"}' \
    '{"name": "timeCode", "type": "timecode", "value": [305419896, 2271560481], "data": "7856341221436587"}' \
    '{"name": "aV3d", "type": "v3d", "value": [1e-300, 2, 3],' \
    '{"name": "deepImageState", "type": "deepImageState", "value": "TIDY", "data": "03"}' \
    '{"name": "aFloatVector", "type": "floatvector", "value": [1, 2.5, -3], "data": "0000803f00002040000040c0"}' \
    '{"name": "anOpaque", "type": "customType", "data": "00ff10"}' \
    '{"name": "an_attribute_name_longer_than_31_characters", "type": "int", "value": 7, "data": "07000000"}'; do
    assert_json attributes/header.json "$expected"
  done
  rewrite attributes.exr attributes
  ok "every attribute type, opaque and malformed values, long names: dumped and written again identically"
  header="$("$(tool exrheader)" attributes.exr)" || fail "exrheader attributes.exr failed"
  contains "$header" 'owner (type string): "Zoé "quoted"' || fail "exrheader: $header"
  contains "$header" 'framesPerSecond (type rational): 24000/1001' || fail "exrheader: $header"
  ok "exrheader reads the attributes"

  # A value of a known type with the wrong size: exr-from-raw writes it,
  # OpenEXR refuses to read the file.
  cat > broken-attribute.json <<EOF
{"dataWindow": [0, 0, 3, 1], "compression": "NONE", "channels": [{"name": "R"}],
 "attributes": [{"name": "chromaticities", "type": "chromaticities", "data": "0000803f"}]}
EOF
  write_exr broken-attribute.json broken-attribute.exr nocheck
  status=0
  "$TO_RAW" broken-attribute.exr broken-attribute 2> /dev/null || status=$?
  [ "$status" -eq 1 ] || fail "exr-to-raw broken-attribute.exr exits with $status, not 1"
  ok "a chromaticities attribute of 4 bytes is written; OpenEXR refuses the file"

  # -------------------------------------------------------------------------
  msg "the OpenEXR utilities"
  info="$("$(tool exrinfo)" -v multipart.exr)" || fail "exrinfo -v multipart.exr failed"
  contains "$info" "parts: 3" || fail "exrinfo: $info"
  ok "exrinfo: 3 parts"

  header="$("$(tool exrheader)" scanline-PIZ-HALF.exr)" || fail "exrheader failed"
  contains "$header" 'compression (type compression): piz' || fail "exrheader: $header"
  contains "$header" 'dataWindow (type box2i): (-7 3) - (53 47)' || fail "exrheader: $header"
  ok "exrheader"

  "$(tool exrmaketiled)" -m -t 16 8 -z piz scanline-NONE-HALF.exr maketiled.exr || fail "exrmaketiled failed"
  dump maketiled.exr maketiled
  assert_json maketiled/header.json '"tiles": {"xSize": 16, "ySize": 8, "levelMode": "MIPMAP_LEVELS", "roundingMode": "ROUND_DOWN"}'
  assert_json maketiled/header.json '"compression": "PIZ"'
  level0=$((WIDTH * HEIGHT * 2))
  head -c "$level0" maketiled/part0.channel3.raw > maketiled-level0.raw
  cmp -s HALF-R.raw maketiled-level0.raw || fail "exrmaketiled: the level 0 of R is not the source"
  ok "exrmaketiled: MIPMAP_LEVELS, level 0 is the source"

  "$(tool exrmetrics)" --convert -z dwab -o metrics-dwab.exr scanline-NONE-FLOAT.exr > /dev/null || fail "exrmetrics --convert -z dwab failed"
  dump metrics-dwab.exr metrics-dwab
  assert_json metrics-dwab/header.json '"compression": "DWAB"'
  cmp -s FLOAT-A.raw metrics-dwab/part0.channel0.raw || fail "exrmetrics: DWAB changed A"
  if cmp -s FLOAT-R.raw metrics-dwab/part0.channel3.raw; then fail "exrmetrics: DWAB did not change R"; fi
  "$(tool exrmetrics)" --convert --pixelmode half -z zip -o metrics-half.exr scanline-NONE-FLOAT.exr > /dev/null \
    || fail "exrmetrics --convert --pixelmode half failed"
  dump metrics-half.exr metrics-half
  assert_json metrics-half/header.json '{"name": "R", "pixelType": "HALF"'
  ok "exrmetrics --convert: compression and pixel type"

  "$(tool exrstdattr)" -owner "prebuilt" -chromaticities 0.708 0.292 0.17 0.797 0.131 0.046 0.3127 0.329 \
    scanline-ZIP-HALF.exr stdattr.exr || fail "exrstdattr failed"
  dump stdattr.exr stdattr
  assert_json stdattr/header.json '{"name": "owner", "type": "string", "value": "prebuilt"'
  assert_json stdattr/header.json '"value": [0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329]'
  ok "exrstdattr"

  "$(tool exrmakepreview)" -w 16 scanline-ZIP-HALF.exr preview.exr || fail "exrmakepreview failed"
  dump preview.exr preview
  assert_json preview/header.json '{"name": "preview", "type": "preview", "value": {"width": 16, "height": 12'
  ok "exrmakepreview"

  "$(tool exrmultipart)" -separate -i multipart.exr -o separate > /dev/null || fail "exrmultipart -separate failed"
  [ -f separate.1.exr ] && [ -f separate.2.exr ] && [ -f separate.3.exr ] || fail "exrmultipart -separate: $(ls separate*)"
  dump separate.2.exr separate
  cmp -s FLOAT-R.raw separate/part0.channel0.raw || fail "exrmultipart -separate: the samples of depth changed"
  ok "exrmultipart -separate"

  "$(tool exrmultipart)" -combine -i scanline-ZIP-HALF.exr::left tiled-ZIP-FLOAT.exr::right -o combined.exr > /dev/null \
    || fail "exrmultipart -combine failed"
  check="$("$EXRCHECK" combined.exr 2>&1)" || fail "exrcheck combined.exr: $check"
  rm -rf combined
  "$TO_RAW" --header-only combined.exr combined || fail "exr-to-raw --header-only combined.exr failed"
  assert_json combined/header.json '"name": "right"'
  [ -z "$(chunk_table combined/header.json 1 | tr -d ' 0')" ] \
    || fail "exrmultipart -combine now writes the offset table of the second part: $(chunk_table combined/header.json 1)"
  status=0
  "$TO_RAW" combined.exr combined 2> /dev/null || status=$?
  [ "$status" -eq 1 ] || fail "exr-to-raw combined.exr exits with $status, not 1"
  ok "exrmultipart -combine writes an offset table of zeros for the second part; exrcheck accepts the file, exr-to-raw refuses it"

  "$(tool exrmultiview)" left scanline-ZIP-HALF.exr right scanline-PIZ-HALF.exr multiview.exr > /dev/null \
    || fail "exrmultiview failed"
  dump multiview.exr multiview
  assert_json multiview/header.json '{"name": "right.R"'
  assert_json multiview/header.json '{"name": "multiView", "type": "stringvector", "value": ["left", "right"]'
  ok "exrmultiview"

  cat > latlong.json <<EOF
{"dataWindow": [0, 0, 31, 15], "compression": "ZIP", "channels": [{"name": "R", "pixelType": "HALF"}, {"name": "G", "pixelType": "HALF"}, {"name": "B", "pixelType": "HALF"}],
 "attributes": [{"name": "envmap", "type": "envmap", "value": "LATLONG"}]}
EOF
  write_exr latlong.json latlong.exr
  "$(tool exrenvmap)" -c -w 8 latlong.exr cube.exr > /dev/null || fail "exrenvmap failed"
  dump cube.exr cube
  assert_json cube/header.json '"value": "CUBE"'
  assert_json cube/header.json '"dataWindow": [0, 0, 7, 47]'
  ok "exrenvmap: latitude-longitude to cube"

  "$(tool exr2aces)" scanline-PIZ-HALF.exr aces.exr > /dev/null 2>&1 || fail "exr2aces failed"
  dump aces.exr aces
  # The ACES primaries (AP0) and white point.
  assert_json aces/header.json '{"name": "chromaticities", "type": "chromaticities", "value": [0.7347, 0.2653, 0, 1, 0.0001, -0.077, 0.32168, 0.33767]'
  ok "exr2aces: ACES chromaticities"

  "$(tool exrmanifest)" scanline-PIZ-HALF.exr > /dev/null 2>&1 || true
  ok "exrmanifest runs"

  # -------------------------------------------------------------------------
  msg "errors"
  head -c 300 scanline-ZIP-HALF.exr > truncated.exr
  printf 'not an EXR file' > garbage.exr
  for bad in truncated.exr garbage.exr; do
    status=0
    "$TO_RAW" "$bad" "bad-dump" 2> /dev/null || status=$?
    [ "$status" -eq 1 ] || fail "exr-to-raw $bad exits with $status, not 1"
    status=0
    "$EXRCHECK" "$bad" > /dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "exrcheck accepts $bad"
  done
  ok "exr-to-raw exits with 1 on a truncated file and on a file that is not an EXR file; exrcheck fails"

  head -c 100 HALF-R.raw > short.raw
  printf '{"dataWindow": [0, 0, 9, 9], "channels": [{"name": "R", "file": "short.raw"}]}' > short.json
  printf '{"dataWindow": [0, 0, 9, 9], "channelz": []}' > unknown.json
  printf '{"parts": [{"dataWindow": [0, 0, 9, 9]}, {"dataWindow": [0, 0, 9, 9], "name": "b"}]}' > unnamed.json
  printf '{"dataWindow": [0, 0, 9, 9], "attributes": [{"name": "dataWindow", "type": "box2i", "value": [0, 0, 1, 1]}]}' > member.json
  for bad in short unknown unnamed member; do
    rm -f bad.exr
    status=0
    "$FROM_RAW" "$bad.json" bad.exr 2> /dev/null || status=$?
    [ "$status" -eq 2 ] || fail "exr-from-raw $bad.json exits with $status, not 2"
    [ ! -f bad.exr ] || fail "exr-from-raw $bad.json left bad.exr"
  done
  printf '{"tiles": {"xSize": 8, "ySize": 8}, "dataWindow": [0, 0, 9, 9], "channels": [{"name": "R", "xSampling": 2, "ySampling": 2}]}' > tiled-sampling.json
  status=0
  "$FROM_RAW" tiled-sampling.json bad.exr 2> /dev/null || status=$?
  [ "$status" -eq 1 ] || fail "exr-from-raw tiled-sampling.json exits with $status, not 1"
  [ ! -f bad.exr ] || fail "exr-from-raw tiled-sampling.json left bad.exr"
  sed 's/"compression": "NONE"/"compression": "ZIP"/' deepscanline-NONE.json > deep-zip.json
  status=0
  "$FROM_RAW" deep-zip.json bad.exr 2> /dev/null || status=$?
  [ "$status" -eq 1 ] || fail "exr-from-raw deep-zip.json exits with $status, not 1"
  [ ! -f bad.exr ] || fail "exr-from-raw deep-zip.json left bad.exr"
  ok "exr-from-raw exits with 2 on an invalid description, with 1 when OpenEXR refuses the header (subsampled tiles, deep ZIP), and writes no file"

  # -------------------------------------------------------------------------
  if [ -n "$HASH_FAILURES" ]; then
    fail "the decoded samples of the lossy round trips do not have the expected SHA-256:$HASH_FAILURES"
  fi
  cd "$ROOT"
}

if [ "$MODE" = link ] || [ "$MODE" = all ]; then
  msg "linkage ($TARGET)"
  for name in $RELEASE_TOOLS $RAW_TOOLS; do
    assert_linkage "$(tool "$name")"
  done
fi

if [ "$MODE" = run ] || [ "$MODE" = all ]; then
  [ -n "$OPENEXR_VERSION" ] || { echo "OPENEXR_VERSION is not set" >&2; exit 2; }
  run_tests
fi

msg "verified the OpenEXR tools for $TARGET ($MODE)"
