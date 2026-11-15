#!/usr/bin/env bash
#
# Verifies the 7zz binary downloaded by scripts/download-7zip.sh.
#
#   bash scripts/verify-7zip.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  linkage assertions only
#   run   version assertion plus smoke tests (must run on the target platform)
#   all   both (default)
#
# The smoke tests write 7z archives with each of the methods an archive reader
# meets (LZMA2, LZMA, PPMd, BZip2, Deflate, the BCJ filter, solid and not
# solid, AES-256 with encrypted headers), and zip, tar, xz, bzip2 and gzip
# files, check their signatures, then test and extract each of them and
# compare the files with the originals.
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
SEVENZIP="./7zz-$TARGET$EXE"
[ -f "$SEVENZIP" ] || { echo "missing $SEVENZIP" >&2; exit 1; }
chmod +x "$SEVENZIP" 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# Linkage
# ---------------------------------------------------------------------------

# As assert_linkage of scripts/verify-common.sh, except that 7za.exe is linked
# with msvcrt.dll, the C runtime every Windows version ships, as all the
# binaries of the 7-Zip releases are.
assert_7zip_linkage() {
  bin="$1"
  case "$TARGET" in
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $bin"
      imports="$("$objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $bin"
      bad=""
      for dll in $imports; do
        case "$dll" in
          kernel32.dll|user32.dll|advapi32.dll|oleaut32.dll|msvcrt.dll) ;;
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

# 7-Zip has no --version option: with no argument, it prints its banner
# ("7-Zip (z) 26.06 (x64) : Copyright ...", "7-Zip (a)" for 7za) and its usage.
assert_version() {
  output="$("$SEVENZIP" 2>&1 | tr -d '\r')" || fail "7zz without arguments failed: $output"
  banner="$(printf '%s\n' "$output" | awk '/^7-Zip / && !found { print; found = 1 }')"
  [ -n "$banner" ] || fail "7zz prints no banner: $output"
  if [ -z "$SEVENZIP_VERSION" ]; then
    echo "  SEVENZIP_VERSION is not set; skipping the version check ($banner)"
    return 0
  fi
  case "$banner" in
    "7-Zip ("?") $SEVENZIP_VERSION "*) ok "7zz reports version $SEVENZIP_VERSION ($banner)" ;;
    *) fail "7zz does not report version $SEVENZIP_VERSION: $banner" ;;
  esac
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# run <command and arguments...>: runs 7zz, and shows its output when it fails.
run() {
  "$SZ" "$@" -bd > 7zz.log 2>&1 < /dev/null || { cat 7zz.log >&2; fail "7zz $* failed"; }
}

# expect_signature <file> <offset> <hexadecimal bytes>
expect_signature() {
  actual="$(od -An -v -tx1 -j "$2" -N $((${#3} / 2)) "$1" | tr -d ' \n\r')"
  [ "$actual" = "$3" ] || fail "$1 starts with $actual at offset $2, expected $3"
  ok "$1 has the signature $3"
}

# same_tree <directory>: compares the extracted files with the source tree.
same_tree() {
  for name in text.txt "with space.bin" empty.txt sub/nested.txt; do
    same_file "$1/$name" "$1/$name" "src/$name" > /dev/null
  done
  ok "$1 has the source files"
}

# roundtrip <archive> <add options...>: writes the source tree to an archive,
# then tests and extracts it, with the password of $PASSWORD, if any.
PASSWORD=""
roundtrip() {
  archive="$1"; shift
  rm -f "$archive"
  ( cd src && "../$SZ" a "$@" -bd "../$archive" text.txt "with space.bin" empty.txt sub > ../7zz.log 2>&1 < /dev/null ) \
    || { cat 7zz.log >&2; fail "7zz a $* $archive failed"; }
  if [ -n "$PASSWORD" ]; then
    run t "-p$PASSWORD" "$archive"
    rm -rf "out-$archive"
    run x -y "-p$PASSWORD" "-oout-$archive" "$archive"
  else
    run t "$archive"
    rm -rf "out-$archive"
    run x -y "-oout-$archive" "$archive"
  fi
  same_tree "out-$archive"
}

# single <archive> <type>: compresses one file to a stream format.
single() {
  archive="$1"; type="$2"
  rm -f "$archive"
  run a "-t$type" "$archive" src/text.txt
  run t "$archive"
  rm -rf "out-$archive"
  run x -y "-oout-$archive" "$archive"
  same_file "$archive extracts to text.txt" "out-$archive/text.txt" src/text.txt
}

smoke_test() {
  workdir="smoke-7zip-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  SZ="../$(basename "$SEVENZIP")"

  msg "formats (7zz i)"
  "$SZ" i > formats.txt 2>&1 < /dev/null || { cat formats.txt >&2; fail "7zz i failed"; }
  tr -d '\r' < formats.txt > formats.lf
  # A line of the format table is "<flags> <name> <extensions> <signature>";
  # the flags start with C when 7-Zip writes the format.
  for format in 7z xz zip gzip bzip2 tar; do
    flags="$(awk -v name="$format" '$2 == name { print $1; exit }' formats.lf)"
    case "$flags" in
      C*) ok "7zz writes $format" ;;
      *) cat formats.lf >&2; fail "7zz does not write $format (flags '$flags')" ;;
    esac
  done

  # A text file, a less compressible binary file (the start of 7zz itself), an
  # empty file, and a file in a subdirectory.
  mkdir -p src/sub
  i=0
  : > src/text.txt
  while [ "$i" -lt 2000 ]; do
    printf 'line %d of the 7-Zip smoke test: the quick brown fox jumps over the lazy dog\n' "$i" >> src/text.txt
    i=$((i + 1))
  done
  head -c 200000 "$SZ" > "src/with space.bin"
  : > src/empty.txt
  printf 'nested\n' > src/sub/nested.txt

  msg "7z archives"
  roundtrip lzma2.7z -t7z -m0=LZMA2 -mx=9
  expect_signature lzma2.7z 0 377abcaf271c
  roundtrip lzma.7z -t7z -m0=LZMA -mx=5
  roundtrip ppmd.7z -t7z -m0=PPMd -mx=7
  roundtrip bzip2.7z -t7z -m0=BZip2
  roundtrip deflate.7z -t7z -m0=Deflate
  roundtrip copy.7z -t7z -m0=Copy
  roundtrip bcj.7z -t7z -mf=BCJ -m0=LZMA2
  roundtrip nonsolid.7z -t7z -ms=off -mx=1
  [ "$(file_size lzma2.7z)" -lt "$(file_size copy.7z)" ] || fail "the LZMA2 archive is not smaller than the stored one"
  ok "LZMA2 compresses"

  msg "7z with AES-256 and encrypted headers"
  PASSWORD=Secret123
  roundtrip aes.7z -t7z -pSecret123 -mhe=on
  # The headers are encrypted: listing needs the password too.
  if "$SZ" l -pWrong -bd aes.7z > wrong.log 2>&1 < /dev/null; then
    cat wrong.log >&2; fail "7zz listed aes.7z with a wrong password"
  fi
  ok "a wrong password is rejected"
  PASSWORD=""

  msg "zip and tar"
  roundtrip deflate.zip -tzip -mm=Deflate
  expect_signature deflate.zip 0 504b0304
  PASSWORD=Secret123
  roundtrip aes.zip -tzip -mem=AES256 -pSecret123
  PASSWORD=""
  roundtrip archive.tar -ttar
  # "ustar" at offset 257 of the first header.
  expect_signature archive.tar 257 7573746172

  msg "stream formats"
  single text.txt.xz xz
  expect_signature text.txt.xz 0 fd377a585a00
  single text.txt.bz2 bzip2
  expect_signature text.txt.bz2 0 425a68
  single text.txt.gz gzip
  expect_signature text.txt.gz 0 1f8b08

  # A damaged archive fails its test.
  cp lzma2.7z damaged.7z
  size="$(file_size damaged.7z)"
  printf '\377\377\377\377' | dd of=damaged.7z bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
  if "$SZ" t -bd damaged.7z > damaged.log 2>&1 < /dev/null; then
    cat damaged.log >&2; fail "7zz t accepts a damaged archive"
  fi
  ok "a damaged archive fails 7zz t"

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_7zip_linkage "$SEVENZIP"
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
