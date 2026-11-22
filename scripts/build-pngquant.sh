#!/usr/bin/env bash
#
# Builds a statically linked pngquant, the lossy PNG compressor (palette
# quantization with libimagequant), from the pngquant package on crates.io.
#
#   bash scripts/build-pngquant.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# pngquant 3 is a Rust program around the C code of pngquant 2 (pngquant.c,
# rwpng.c), linked with libimagequant 4, which is written in Rust. The pngquant
# releases have no binaries, and pngquant.org has Windows and macOS builds
# only, so every target is built from the crate of the release, with the
# Cargo.lock it holds (--locked).
#
# The crates libz-sys, libpng-sys and lcms2-sys compile the zlib, libpng and
# LittleCMS they bundle (libpng-sys has libpng 1.6.37, from 2019), or link the
# ones pkg-config finds, which is a .dylib or a .so on a build machine. Their
# build scripts are not run: Cargo overrides the `links` key of each of them
# (z, png and lcms2) with the static libraries this script builds first, the
# zlib and libpng ffmpeg and the HarfBuzz tools are built with, and the
# LittleCMS of Poppler and magick. LittleCMS is the color management of the
# default features of pngquant, which converts the pixels of a PNG file with an
# ICC profile or a gAMA/cHRM chunk to sRGB.
#
# Linux builds in Alpine, against musl, as the other tools do: rustup has to be
# on PATH there. win-x64 is cross-compiled from Linux with llvm-mingw, to the
# x86_64-pc-windows-gnullvm target of Rust; point LLVM_MINGW_ROOT at the
# extracted toolchain. Every other target builds natively.
#
# Dependency versions come from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
EXE=""
case "$TARGET" in
  linux-x64)   TRIPLE="x86_64-unknown-linux-musl" ;;
  linux-arm64) TRIPLE="aarch64-unknown-linux-musl" ;;
  win-x64)     TRIPLE="x86_64-pc-windows-gnullvm"; EXE=".exe" ;;
  osx-arm64)   TRIPLE="aarch64-apple-darwin" ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac
for name in ZLIB_VERSION LIBPNG_VERSION LCMS2_VERSION PNGQUANT_VERSION RUST_TOOLCHAIN; do
  eval "value=\${$name}"
  [ -n "$value" ] || { echo "$name is not set" >&2; exit 2; }
done

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/pngquant-deps"
SRCDIR="$WORKDIR/pngquant-src"
STAMPDIR="$PREFIX/.stamps"
ROOT="$WORKDIR/pngquant-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$PREFIX" "$SRCDIR" "$STAMPDIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

msg() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

job_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.logicalcpu
  else
    echo 2
  fi
}
JOBS="$(job_count)"

# Download with retries, then verify the archive really is an archive.
download() {
  url="$1"
  out="$2"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      tar -tzf "$out" >/dev/null 2>&1 && return 0
      echo "downloaded file is not a valid archive: $url" >&2
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  echo "failed to download $url after 5 attempts" >&2
  return 1
}

# Fetch + extract into $SRCDIR.
fetch() {
  name="$1"; url="$2"; archive="$3"; dir="$4"
  if [ ! -d "$SRCDIR/$dir" ]; then
    msg "fetching $name"
    download "$url" "$SRCDIR/$archive"
    ( cd "$SRCDIR" && tar -xf "$archive" )
  fi
  [ -d "$SRCDIR/$dir" ] || { echo "expected source directory $dir not found" >&2; exit 1; }
}

stamp_done() { [ -f "$STAMPDIR/$1" ]; }
stamp_mark() { : > "$STAMPDIR/$1"; }

# Full-static builds must never see a shared library. Delete any that a
# dependency installs despite being asked for static-only.
purge_shared_libs() {
  rm -f "$PREFIX"/lib/*.so "$PREFIX"/lib/*.so.* "$PREFIX"/lib/*.dylib \
        "$PREFIX"/lib/*.dll.a "$PREFIX"/bin/*.dll 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Target configuration
# ---------------------------------------------------------------------------

CMAKE_CROSS_ARGS=""
STRIP="strip"
# The variables of the cc crate and of Cargo are named after the target.
TRIPLE_VARIABLE="$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')"
triple_lower="$(echo "$TRIPLE" | tr '-' '_')"

case "$TARGET" in
  linux-*)
    # Same compiler as the ffmpeg build, for the C libraries and the C code of
    # pngquant. The musl targets of Rust link statically by default.
    export CC=clang CXX=clang++
    export "CC_$triple_lower=clang"
    ;;
  win-x64)
    [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
    export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
    MINGW_TRIPLE="x86_64-w64-mingw32"
    export MINGW_TRIPLE
    CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
    export "CC_$triple_lower=$MINGW_TRIPLE-clang"
    export "AR_$triple_lower=llvm-ar"
    # The cc crate of the Cargo.lock of pngquant (1.0.83) passes the Rust
    # triple to clang, --target=x86_64-pc-windows-gnullvm, which clang rejects.
    # Without its default flags, cc passes none, and the clang of llvm-mingw
    # targets mingw already: the flags it would pass otherwise are here.
    export CRATE_CC_NO_DEFAULTS=1
    export "CFLAGS_$triple_lower=-O3 -ffunction-sections -fdata-sections"
    export "CARGO_TARGET_${TRIPLE_VARIABLE}_LINKER=$MINGW_TRIPLE-clang"
    # crt-static links libunwind, which the Rust standard library unwinds with,
    # statically: it is a DLL of llvm-mingw otherwise.
    export "CARGO_TARGET_${TRIPLE_VARIABLE}_RUSTFLAGS=-C target-feature=+crt-static"
    STRIP="$MINGW_TRIPLE-strip"
    ;;
  osx-arm64)
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    export CC=clang CXX=clang++
    STRIP="strip -x"
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
esac

# pkg-config must see the prefix and nothing else, so that Homebrew cannot leak
# a .dylib into the link.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <name> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-pngquant-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-pngquant-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-pngquant-$name"
  purge_shared_libs
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

if ! stamp_done "zlib-$ZLIB_VERSION"; then
  fetch zlib "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
        "zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
  run_cmake zlib "$SRCDIR/zlib-$ZLIB_VERSION" \
    -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_MINIZIP=OFF
  stamp_mark "zlib-$ZLIB_VERSION"
fi

# Targeting MinGW, zlib's CMake build installs libzs.a; libz.a is the name the
# other platforms have, and the one the link below asks for.
if [ ! -f "$PREFIX/lib/libz.a" ]; then
  for zlib_candidate in libzs.a libzlibstatic.a; do
    if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
      cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
      break
    fi
  done
fi
[ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }

if ! stamp_done "libpng-$LIBPNG_VERSION"; then
  fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" \
        "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"
  run_cmake libpng "$SRCDIR/libpng-$LIBPNG_VERSION" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
    -DZLIB_LIBRARY="$PREFIX/lib/libz.a" -DZLIB_INCLUDE_DIR="$PREFIX/include"
  stamp_mark "libpng-$LIBPNG_VERSION"
fi
[ -f "$PREFIX/lib/libpng16.a" ] || { echo "no static libpng in $PREFIX/lib" >&2; exit 1; }

if ! stamp_done "lcms2-$LCMS2_VERSION"; then
  fetch lcms2 "https://github.com/mm2/Little-CMS/releases/download/lcms$LCMS2_VERSION/lcms2-$LCMS2_VERSION.tar.gz" \
        "lcms2-$LCMS2_VERSION.tar.gz" "lcms2-$LCMS2_VERSION"
  run_cmake lcms2 "$SRCDIR/lcms2-$LCMS2_VERSION" \
    -DLCMS2_BUILD_SHARED=OFF -DLCMS2_BUILD_STATIC=ON -DLCMS2_BUILD_TOOLS=OFF -DLCMS2_BUILD_TESTS=OFF \
    -DLCMS2_WITH_JPEG=OFF -DLCMS2_WITH_TIFF=OFF -DLCMS2_WITH_ZLIB=OFF
  stamp_mark "lcms2-$LCMS2_VERSION"
fi
[ -f "$PREFIX/lib/liblcms2.a" ] || { echo "no static LittleCMS 2 in $PREFIX/lib" >&2; exit 1; }

# ---------------------------------------------------------------------------
# pngquant
# ---------------------------------------------------------------------------

# The build scripts of libz-sys, libpng-sys and lcms2-sys are replaced by the
# libraries of the prefix (https://doc.rust-lang.org/cargo/reference/build-scripts.html#overriding-build-scripts).
# include becomes the DEP_<links>_INCLUDE of the crates that depend on them:
# the build script of pngquant compiles its C code with the headers of
# DEP_PNG_INCLUDE and DEP_LCMS2_INCLUDE. A static library is linked after the
# crates that use it: libpng-sys depends on libz-sys, so libpng16.a comes
# before libz.a.
CARGO_CONFIG="$WORKDIR/pngquant-cargo-config.toml"
cat > "$CARGO_CONFIG" <<EOF
[target.$TRIPLE.z]
rustc-link-search = ["native=$PREFIX/lib"]
rustc-link-lib = ["static=z"]
include = "$PREFIX/include"
root = "$PREFIX"

[target.$TRIPLE.png]
rustc-link-search = ["native=$PREFIX/lib"]
rustc-link-lib = ["static=png16"]
include = "$PREFIX/include"
root = "$PREFIX"

[target.$TRIPLE.lcms2]
rustc-link-search = ["native=$PREFIX/lib"]
rustc-link-lib = ["static=lcms2"]
include = "$PREFIX/include"
root = "$PREFIX"
EOF

msg "installing Rust $RUST_TOOLCHAIN for $TRIPLE"
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --target "$TRIPLE" --no-self-update

# --locked: build with the Cargo.lock of the package. The default features are
# the ones of the pngquant releases: LittleCMS, and libpng rather than the
# image reader of macOS (the cocoa feature).
msg "building pngquant $PNGQUANT_VERSION for $TARGET"
cargo "+$RUST_TOOLCHAIN" install pngquant --version "$PNGQUANT_VERSION" --locked \
  --config "$CARGO_CONFIG" \
  --target "$TRIPLE" --root "$ROOT" --force

OUT="$WORKDIR/pngquant-$TARGET$EXE"
cp "$ROOT/bin/pngquant$EXE" "$OUT"

msg "stripping"
$STRIP "$OUT"
chmod +x "$OUT"

ls -lh "$OUT"
msg "built $(basename "$OUT")"
