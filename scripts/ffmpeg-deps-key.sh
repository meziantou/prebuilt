#!/usr/bin/env bash
#
# Prints the actions/cache key for the ffmpeg-deps prefix that
# scripts/build-ffmpeg.sh populates.
#
#   bash scripts/ffmpeg-deps-key.sh <target>
#
# The key covers exactly what the dependencies are built from: the build
# script, the toolchain, and the dependency versions. Hashing ci.yml as a whole
# is simpler, but then every unrelated workflow edit -- including the VERSION
# bump that goes with any tool update -- throws away 7 to 20 minutes of
# dependency builds.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
[ -n "$TARGET" ] || { echo "usage: $0 <linux-x64|linux-arm64|win-x64|win-arm64|osx-arm64>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Every version variable the build script reads, so a dependency added there is
# picked up here without further changes. FFMPEG_VERSION is left out: ffmpeg
# itself is compiled on every run and never lands in the cached prefix.
VARS="$(grep -oE '\$\{?[A-Z0-9_]+_(VERSION|COMMIT)' "$SCRIPT_DIR/build-ffmpeg.sh" | tr -d '${' | sort -u | grep -v '^FFMPEG_VERSION$')"
FILES="$SCRIPT_DIR/build-ffmpeg.sh"

case "$TARGET" in
  linux-*) VARS="$VARS ALPINE_IMAGE" ;;
  win-*)   VARS="$VARS LLVM_MINGW_VERSION"; FILES="$FILES $SCRIPT_DIR/mingw-toolchain.cmake" ;;
  osx-arm64) ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

HASH="$(
  {
    for name in $VARS; do
      eval "value=\${$name}"
      # An empty value would silently drop the variable from the key.
      [ -n "$value" ] || { echo "$name is not set" >&2; exit 1; }
      echo "$name=$value"
    done
    # shellcheck disable=SC2086
    cat $FILES
  } | hash_stdin
)"

echo "ffmpeg-deps-v2-$TARGET-$HASH"
