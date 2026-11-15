#!/usr/bin/env bash
#
# Downloads the official 7-Zip console binary of a target from the 7-Zip
# release on GitHub (ip7z/7zip), checks it against the SHA-256 pinned in
# .github/workflows/ci.yml, and writes it as 7zz-<target>[.exe].
#
#   bash scripts/download-7zip.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# - linux-*: 7zzs of 7z<ver>-linux-<arch>.tar.xz, the statically linked build
#   of 7zz (the 7zz of the same archive links glibc dynamically).
# - osx-arm64: 7zz of 7z<ver>-mac.tar.xz, which links only system dylibs.
# - win-x64: x64/7za.exe of 7z<ver>-extra.7z, the standalone console build of
#   7-Zip for Windows (7z.exe needs 7z.dll). It packs and unpacks 7z, xz, zip,
#   gzip, bzip2 and tar, and unpacks lzma, cab and zstd: it has no RAR codec.
#   The .7z archive is extracted with the 7zz of the build machine, itself
#   downloaded from the same release and checked against its pinned SHA-256.
#
# SEVENZIP_VERSION and the SEVENZIP_*_SHA256 pins come from the environment.
# GitHub publishes the SHA-256 of each release file (the "digest" of
# `gh release view -R ip7z/7zip <version> --json assets`).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in SEVENZIP_VERSION SEVENZIP_LINUX_X64_SHA256 SEVENZIP_LINUX_ARM64_SHA256 SEVENZIP_MAC_SHA256 SEVENZIP_EXTRA_SHA256; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
DLDIR="$WORKDIR/7zip-download"
# 26.06 -> 2606
SHORT_VERSION="$(echo "$SEVENZIP_VERSION" | tr -d '.')"
BASE_URL="https://github.com/ip7z/7zip/releases/download/$SEVENZIP_VERSION"

mkdir -p "$DLDIR"

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# fetch <file name> <sha256>: downloads a release file into $DLDIR, with
# retries, and keeps it only when it has the pinned content.
fetch() {
  file="$1"; expected="$2"
  out="$DLDIR/$file"
  if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$expected" ]; then
    return 0
  fi
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$BASE_URL/$file" -o "$out"; then
      actual="$(sha256_of "$out")"
      [ "$actual" = "$expected" ] && return 0
      echo "$file has SHA-256 $actual, expected $expected" >&2
    fi
    echo "download attempt $attempt failed: $BASE_URL/$file" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  rm -f "$out"
  echo "failed to download $BASE_URL/$file with SHA-256 $expected" >&2
  return 1
}

# extract_tar <archive> <member> <destination>
extract_tar() {
  archive="$1"; member="$2"; destination="$3"
  rm -rf "$DLDIR/extracted"; mkdir -p "$DLDIR/extracted"
  tar -xJf "$DLDIR/$archive" -C "$DLDIR/extracted" "$member" \
    || { echo "$member not found in $archive" >&2; exit 1; }
  cp "$DLDIR/extracted/$member" "$destination"
  chmod +x "$destination"
}

# The 7zz of the build machine, to extract the .7z archive of the Windows build.
host_7zz() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) archive="7z$SHORT_VERSION-linux-x64.tar.xz"; sha="$SEVENZIP_LINUX_X64_SHA256"; member=7zzs ;;
    Linux-aarch64|Linux-arm64) archive="7z$SHORT_VERSION-linux-arm64.tar.xz"; sha="$SEVENZIP_LINUX_ARM64_SHA256"; member=7zzs ;;
    Darwin-*) archive="7z$SHORT_VERSION-mac.tar.xz"; sha="$SEVENZIP_MAC_SHA256"; member=7zz ;;
    *) echo "no 7zz for this build machine: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
  fetch "$archive" "$sha"
  extract_tar "$archive" "$member" "$DLDIR/host-7zz"
}

msg "downloading 7-Zip $SEVENZIP_VERSION for $TARGET"
case "$TARGET" in
  linux-x64)
    fetch "7z$SHORT_VERSION-linux-x64.tar.xz" "$SEVENZIP_LINUX_X64_SHA256"
    extract_tar "7z$SHORT_VERSION-linux-x64.tar.xz" 7zzs "$WORKDIR/7zz-$TARGET"
    out="$WORKDIR/7zz-$TARGET"
    ;;
  linux-arm64)
    fetch "7z$SHORT_VERSION-linux-arm64.tar.xz" "$SEVENZIP_LINUX_ARM64_SHA256"
    extract_tar "7z$SHORT_VERSION-linux-arm64.tar.xz" 7zzs "$WORKDIR/7zz-$TARGET"
    out="$WORKDIR/7zz-$TARGET"
    ;;
  osx-arm64)
    fetch "7z$SHORT_VERSION-mac.tar.xz" "$SEVENZIP_MAC_SHA256"
    extract_tar "7z$SHORT_VERSION-mac.tar.xz" 7zz "$WORKDIR/7zz-$TARGET"
    out="$WORKDIR/7zz-$TARGET"
    ;;
  win-x64)
    host_7zz
    fetch "7z$SHORT_VERSION-extra.7z" "$SEVENZIP_EXTRA_SHA256"
    rm -rf "$DLDIR/extra"
    "$DLDIR/host-7zz" x -y -bd "-o$DLDIR/extra" "$DLDIR/7z$SHORT_VERSION-extra.7z" x64/7za.exe > "$DLDIR/extract.log" \
      || { cat "$DLDIR/extract.log" >&2; echo "failed to extract x64/7za.exe" >&2; exit 1; }
    [ -f "$DLDIR/extra/x64/7za.exe" ] || { echo "x64/7za.exe not found in 7z$SHORT_VERSION-extra.7z" >&2; exit 1; }
    out="$WORKDIR/7zz-$TARGET.exe"
    cp "$DLDIR/extra/x64/7za.exe" "$out"
    ;;
esac

ls -l "$out"
msg "downloaded 7-Zip for $TARGET"
