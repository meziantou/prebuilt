#!/usr/bin/env bash
#
# Builds a statically linked jxl-oxide, the command-line tool of the jxl-oxide
# JPEG XL decoder, from the jxl-oxide-cli package on crates.io.
#
#   bash scripts/build-jxl-oxide.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# The jxl-oxide releases have no binaries any more, and the ones they had were
# linked against glibc and did not cover macOS. Every target builds natively.
# The Linux targets need musl-gcc (the musl-tools package on Ubuntu) to compile
# the bundled lcms2.
#
# JXL_OXIDE_VERSION and RUST_TOOLCHAIN come from the environment (see
# .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
EXE=""
case "$TARGET" in
  linux-x64)   TRIPLE="x86_64-unknown-linux-musl" ;;
  linux-arm64) TRIPLE="aarch64-unknown-linux-musl" ;;
  win-x64)     TRIPLE="x86_64-pc-windows-msvc"; EXE=".exe" ;;
  osx-arm64)   TRIPLE="aarch64-apple-darwin" ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
[ -n "$JXL_OXIDE_VERSION" ] || { echo "JXL_OXIDE_VERSION is not set" >&2; exit 2; }
[ -n "$RUST_TOOLCHAIN" ] || { echo "RUST_TOOLCHAIN is not set" >&2; exit 2; }

WORKDIR="$(pwd)"
ROOT="$WORKDIR/jxl-oxide-build"

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

case "$TARGET" in
  linux-*)
    # The musl targets of Rust link statically by default. musl-gcc is a
    # wrapper for the architecture of the machine, whatever its name.
    command -v musl-gcc >/dev/null 2>&1 || { echo "musl-gcc not found; install musl-tools" >&2; exit 1; }
    cc_variable="CC_$(echo "$TRIPLE" | tr '-' '_')"
    export "$cc_variable=musl-gcc"
    ;;
  win-x64)
    # Link the C runtime statically: vcruntime140.dll is not part of Windows.
    export RUSTFLAGS="-C target-feature=+crt-static"
    ;;
  osx-arm64)
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# lcms2-sys links the lcms2 pkg-config finds, which is a Homebrew .dylib on
# macOS, unless it is told to compile the copy it bundles.
export LCMS2_STATIC=1

msg "installing Rust $RUST_TOOLCHAIN for $TRIPLE"
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --target "$TRIPLE" --no-self-update

# --locked: build with the Cargo.lock of the package.
# The default features also enable mimalloc, an allocator written in C that a
# test tool has no use for.
msg "building jxl-oxide $JXL_OXIDE_VERSION for $TARGET"
cargo "+$RUST_TOOLCHAIN" install jxl-oxide-cli --version "$JXL_OXIDE_VERSION" --locked \
  --no-default-features --features rayon \
  --target "$TRIPLE" --root "$ROOT" --force

OUT="$WORKDIR/jxl-oxide-$TARGET$EXE"
cp "$ROOT/bin/jxl-oxide$EXE" "$OUT"
chmod +x "$OUT"

ls -lh "$OUT"
msg "built $(basename "$OUT")"
