#!/usr/bin/env bash
#
# Verifies the unrar binary built by scripts/build-unrar.sh.
#
#   bash scripts/verify-unrar.sh <target> [link|run|all]
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
# Modes:
#   link  static-linkage assertions only
#   run   version assertion plus smoke tests (must run on the target platform)
#   all   both (default)
#
# The smoke tests test, list and extract the RAR 4 and RAR 5 samples of
# scripts/rar-samples.sh (stored, compressed, with a RarVM filter, encrypted),
# compare the extracted files with their pinned SHA-256, and check that a
# wrong password and a damaged archive are errors.
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
UNRAR="./unrar-$TARGET$EXE"
[ -f "$UNRAR" ] || { echo "missing $UNRAR" >&2; exit 1; }
chmod +x "$UNRAR" 2>/dev/null || true

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
# shellcheck source=rar-samples.sh
. "$SCRIPT_DIR/rar-samples.sh"

# ---------------------------------------------------------------------------
# Linkage
# ---------------------------------------------------------------------------

# As assert_linkage of scripts/verify-common.sh, with the system DLLs the
# Windows code of unrar calls into (power, process and WMI information).
assert_unrar_linkage() {
  bin="$1"
  case "$TARGET" in
    win-*)
      objdump="$(find_objdump)" || fail "no objdump or llvm-objdump to list the imports of $bin"
      imports="$("$objdump" -p "$bin" | sed -n 's/^[[:space:]]*DLL Name: //p' \
                 | tr 'A-Z' 'a-z' | tr -d '\r' | sort -u)"
      [ -n "$imports" ] || fail "could not list the imports of $bin"
      bad=""
      for dll in $imports; do
        # ucrtbase and the api-ms-win-crt-* stubs are the UCRT, a Windows
        # component since Windows 10. Anything else means a dependency leaked
        # in dynamically -- most likely libc++.dll, libunwind.dll or
        # libwinpthread-1.dll.
        case "$dll" in
          kernel32.dll|user32.dll|advapi32.dll|shell32.dll|shlwapi.dll|ole32.dll|oleaut32.dll|bcrypt.dll|powrprof.dll|psapi.dll|ucrtbase.dll|api-ms-win-*) ;;
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

# unrar has no --version option: with no argument, it prints its banner
# ("UNRAR 7.23 freeware      Copyright (c) 1993-2026 Alexander Roshal", with
# the architecture after the version on Windows: "UNRAR 7.23 x64 freeware") and
# its usage.
assert_version() {
  output="$("$UNRAR" 2>&1 < /dev/null | tr -d '\r')" || fail "unrar without arguments failed: $output"
  banner="$(printf '%s\n' "$output" | awk '/^UNRAR / && !found { print; found = 1 }')"
  [ -n "$banner" ] || fail "unrar prints no banner: $output"
  if [ -z "$UNRAR_VERSION" ]; then
    echo "  UNRAR_VERSION is not set; skipping the version check ($banner)"
    return 0
  fi
  case "$banner" in
    "UNRAR $UNRAR_VERSION "*) ok "unrar reports version $UNRAR_VERSION ($banner)" ;;
    *) fail "unrar does not report version $UNRAR_VERSION: $banner" ;;
  esac
}

# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

# run <command and arguments...>: runs unrar, and shows its output when it
# fails. -p- never asks for a password.
run() {
  "$UR" "$@" > unrar.log 2>&1 < /dev/null || { cat unrar.log >&2; fail "unrar $* failed"; }
}

# expect_sha256 <file> <sha256>
expect_sha256() {
  [ -f "$1" ] || fail "$1 was not extracted"
  actual="$(sha256_of "$1")"
  [ "$actual" = "$2" ] || fail "$1 has the SHA-256 $actual, expected $2"
  ok "$1 has the expected content"
}

# expect_failure <label> <command and arguments...>
expect_failure() {
  label="$1"; shift
  if "$UR" "$@" > failure.log 2>&1 < /dev/null; then
    cat failure.log >&2; fail "$label: unrar $* succeeded"
  fi
  ok "$label"
}

smoke_test() {
  workdir="smoke-unrar-$TARGET"
  rm -rf "$workdir"; mkdir -p "$workdir"
  cd "$workdir"
  UR="../$(basename "$UNRAR")"

  write_rar_samples
  ok "wrote the RAR samples"

  msg "test (t)"
  run t -p- rar4.rar
  run t -p- rar4-filter.rar
  run t -p- rar5.rar
  run t -p12345678 rar4-encrypted.rar
  ok "the samples pass unrar t"

  msg "list (lb)"
  run lb -p- rar4.rar
  # unrar lists the paths with the separator of the platform.
  names="$(tr -d '\r' < unrar.log | tr '\\' '/' | sort | tr '\n' ' ')"
  expect "the names of rar4.rar" "$names" "test.txt testdir testdir/test.txt testemptydir testlink "
  run lb -p- rar5.rar
  expect "the names of rar5.rar" "$(tr -d '\r\n' < unrar.log)" "test.bin"

  msg "print (p)"
  "$UR" p -inul -p- rar4.rar test.txt > printed.txt < /dev/null || fail "unrar p rar4.rar test.txt failed"
  expect_sha256 printed.txt "$RAR_TEST_TXT_SHA256"

  msg "extract (x)"
  # Not the symbolic link: Windows does not let every user create one.
  run x -o+ -p- -xtestlink rar4.rar out-rar4/
  expect_sha256 out-rar4/test.txt "$RAR_TEST_TXT_SHA256"
  expect_sha256 out-rar4/testdir/test.txt "$RAR_TEST_TXT_SHA256"
  [ -d out-rar4/testemptydir ] || fail "the empty directory testemptydir was not extracted"
  ok "the empty directory testemptydir"
  run x -o+ -p- rar4-filter.rar out-rar4-filter/
  expect_sha256 out-rar4-filter/f2500.bin "$RAR_F2500_BIN_SHA256"
  run x -o+ -p- rar5.rar out-rar5/
  expect_sha256 out-rar5/test.bin "$RAR_TEST_BIN_SHA256"
  run x -o+ -p12345678 rar4-encrypted.rar out-rar4-encrypted/
  expect_sha256 out-rar4-encrypted/foo.txt "$RAR_FOO_TXT_SHA256"
  expect_sha256 out-rar4-encrypted/bar.txt "$RAR_BAR_TXT_SHA256"

  msg "errors"
  expect_failure "a wrong password is rejected" t -pwrong rar4-encrypted.rar
  expect_failure "a missing password is rejected" t -p- rar4-encrypted.rar
  # The middle of the compressed data of test.bin.
  cp rar5.rar damaged.rar
  printf '\377\377\377\377' | dd of=damaged.rar bs=1 seek=200 conv=notrunc 2>/dev/null
  expect_failure "a damaged archive fails unrar t" t -p- damaged.rar

  cd ..
  ok "all smoke tests passed"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  link|all)
    msg "linkage ($TARGET)"
    assert_unrar_linkage "$UNRAR"
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
