#!/usr/bin/env bash
#
# Builds statically linked ffmpeg/ffprobe with a pinned codec set.
#
#   bash scripts/build-ffmpeg.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | win-arm64 | osx-arm64
#
# Windows targets are cross-compiled from Linux with llvm-mingw; point
# LLVM_MINGW_ROOT at the extracted toolchain. Every other target builds natively.
#
# Dependency versions come from the environment (see .github/workflows/ci.yml).
#
# NOTE: this script must stay compatible with bash 3.2 -- macos-latest still
# ships 3.2. No mapfile/readarray, no `declare -A`, no ${v,,}, no globstar,
# no `local -n`, and no `set -u` (3.2 aborts on "${empty_array[@]}").

set -eo pipefail

TARGET="$1"
if [ -z "$TARGET" ]; then
  echo "usage: $0 <linux-x64|linux-arm64|win-x64|win-arm64|osx-arm64>" >&2
  exit 2
fi

WORKDIR="$(pwd)"
PREFIX="$WORKDIR/ffmpeg-deps"
SRCDIR="$WORKDIR/ffmpeg-src"
STAMPDIR="$PREFIX/.stamps"
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
# code.videolan.org and friends answer HTTP 200 with a bot-challenge HTML page,
# so an unvalidated download fails much later with a baffling error.
download() {
  url="$1"
  out="$2"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    rm -f "$out"
    if curl -fsSL --retry 2 --connect-timeout 30 "$url" -o "$out"; then
      case "$out" in
        *.tar.gz|*.tgz) tar -tzf "$out" >/dev/null 2>&1 && return 0 ;;
        *.tar.xz)       tar -tJf "$out" >/dev/null 2>&1 && return 0 ;;
        *.tar.bz2)      tar -tjf "$out" >/dev/null 2>&1 && return 0 ;;
        *)              [ -s "$out" ] && return 0 ;;
      esac
      echo "downloaded file is not a valid archive: $url" >&2
    fi
    echo "download attempt $attempt failed: $url" >&2
    attempt=$((attempt + 1))
    sleep $((2 * attempt))
  done
  echo "failed to download $url after 5 attempts" >&2
  return 1
}

# Fetch + extract into $SRCDIR, echoing the resulting source directory.
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

CROSS_PREFIX=""
CMAKE_CROSS_ARGS=""
VPX_TARGET=""
X265_ASM="ON"

case "$TARGET" in
  linux-x64)
    RID="linux-x64"; EXE=""
    FF_ARCH="x86_64"; FF_TARGET_OS="linux"
    CXX_LIB="-lstdc++"
    FF_THREADS="--enable-pthreads"
    # musl's default thread stack is 128 KB; libaom and libsvtav1 overflow it.
    FF_LDFLAGS="-static -Wl,-z,stack-size=2097152"
    ;;
  linux-arm64)
    RID="linux-arm64"; EXE=""
    FF_ARCH="aarch64"; FF_TARGET_OS="linux"
    CXX_LIB="-lstdc++"
    FF_THREADS="--enable-pthreads"
    FF_LDFLAGS="-static -Wl,-z,stack-size=2097152"
    ;;
  win-x64)
    RID="win-x64"; EXE=".exe"
    FF_ARCH="x86_64"; FF_TARGET_OS="mingw32"
    CROSS_PREFIX="x86_64-w64-mingw32-"
    VPX_TARGET="x86_64-win64-gcc"
    CXX_LIB="-lc++"      # llvm-mingw uses libc++, not libstdc++
    FF_THREADS="--disable-pthreads --enable-w32threads"
    FF_LDFLAGS="-static"
    ;;
  win-arm64)
    RID="win-arm64"; EXE=".exe"
    FF_ARCH="aarch64"; FF_TARGET_OS="mingw32"
    CROSS_PREFIX="aarch64-w64-mingw32-"
    VPX_TARGET="arm64-win64-gcc"
    CXX_LIB="-lc++"
    FF_THREADS="--disable-pthreads --enable-w32threads"
    FF_LDFLAGS="-static"
    # aarch64 assembly under clang-on-Windows is the least exercised x265 config.
    X265_ASM="OFF"
    ;;
  osx-arm64)
    RID="osx-arm64"; EXE=""
    FF_ARCH="arm64"; FF_TARGET_OS="darwin"
    CXX_LIB="-lc++"
    FF_THREADS="--enable-pthreads"
    # macOS has no static libSystem: the goal here is "no non-system dylibs".
    FF_LDFLAGS=""
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 2
    ;;
esac

if [ -n "$CROSS_PREFIX" ]; then
  [ -n "$LLVM_MINGW_ROOT" ] || { echo "LLVM_MINGW_ROOT must be set for $TARGET" >&2; exit 2; }
  export PATH="$LLVM_MINGW_ROOT/bin:$PATH"
  MINGW_TRIPLE="${CROSS_PREFIX%-}"
  export MINGW_TRIPLE
  CMAKE_CROSS_ARGS="-DCMAKE_TOOLCHAIN_FILE=$SCRIPT_DIR/mingw-toolchain.cmake -DMINGW_TRIPLE=$MINGW_TRIPLE"
fi

# pkg-config must see the cross prefix and nothing else. PKG_CONFIG_LIBDIR (not
# just PKG_CONFIG_PATH) is what stops Homebrew leaking a .dylib into the link.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=OFF"

# run_cmake <stamp> <source dir> [extra cmake args...]
run_cmake() {
  name="$1"; src="$2"; shift 2
  msg "building $name"
  # shellcheck disable=SC2086
  cmake -S "$src" -B "$WORKDIR/build-$name" $CMAKE_COMMON $CMAKE_CROSS_ARGS "$@"
  cmake --build "$WORKDIR/build-$name" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-$name"
  purge_shared_libs
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

if ! stamp_done "zlib-$ZLIB_VERSION"; then
  fetch zlib "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" \
        "zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
  msg "building zlib"
  cmake -S "$SRCDIR/zlib-$ZLIB_VERSION" -B "$WORKDIR/build-zlib" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
    -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_MINIZIP=OFF
  cmake --build "$WORKDIR/build-zlib" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-zlib"
  purge_shared_libs
  stamp_mark "zlib-$ZLIB_VERSION"
fi

# Targeting MinGW, zlib's CMake build installs libzs.a, but zlib.pc advertises
# -lz and ffmpeg looks for zlib with a plain `-lz` link test rather than
# pkg-config -- so without this the Windows builds fail configure with
# "zlib requested but not found". Left outside the stamp guard so it also
# validates a restored cache.
if [ ! -f "$PREFIX/lib/libz.a" ]; then
  for zlib_candidate in libzs.a libzlibstatic.a; do
    if [ -f "$PREFIX/lib/$zlib_candidate" ]; then
      cp "$PREFIX/lib/$zlib_candidate" "$PREFIX/lib/libz.a"
      break
    fi
  done
fi
[ -f "$PREFIX/lib/libz.a" ] || { echo "no static zlib in $PREFIX/lib" >&2; exit 1; }

if ! stamp_done "brotli-$BROTLI_VERSION"; then
  fetch brotli "https://github.com/google/brotli/archive/refs/tags/v$BROTLI_VERSION.tar.gz" \
        "brotli-$BROTLI_VERSION.tar.gz" "brotli-$BROTLI_VERSION"
  run_cmake brotli "$SRCDIR/brotli-$BROTLI_VERSION" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
  stamp_mark "brotli-$BROTLI_VERSION"
fi

# highway tags carry no leading "v".
if ! stamp_done "highway-$HWY_VERSION"; then
  fetch highway "https://github.com/google/highway/archive/refs/tags/$HWY_VERSION.tar.gz" \
        "highway-$HWY_VERSION.tar.gz" "highway-$HWY_VERSION"
  run_cmake highway "$SRCDIR/highway-$HWY_VERSION" \
    -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=ON -DBUILD_TESTING=OFF
  stamp_mark "highway-$HWY_VERSION"
fi

if ! stamp_done "libjxl-$JXL_VERSION"; then
  fetch libjxl "https://github.com/libjxl/libjxl/archive/refs/tags/v$JXL_VERSION.tar.gz" \
        "libjxl-$JXL_VERSION.tar.gz" "libjxl-$JXL_VERSION"
  # deps.sh fetches third_party/skcms et al. and is flaky; retry it.
  attempt=1
  while [ "$attempt" -le 5 ]; do
    if ( cd "$SRCDIR/libjxl-$JXL_VERSION" && bash ./deps.sh ); then break; fi
    [ "$attempt" -eq 5 ] && { echo "failed to fetch libjxl dependencies" >&2; exit 1; }
    attempt=$((attempt + 1)); sleep $((2 * attempt))
  done
  run_cmake libjxl "$SRCDIR/libjxl-$JXL_VERSION" \
    -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TESTS=OFF -DJPEGXL_ENABLE_TOOLS=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_VERSION="$JXL_VERSION" \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON
  # Built from a tarball there is no git metadata, so CMake writes a bogus
  # Version: into the .pc files and ffmpeg's `libjxl >= 0.7.0` check fails.
  # -DJPEGXL_VERSION alone is not enough; rewrite them.
  for pc in libjxl libjxl_threads libjxl_cms; do
    f="$PREFIX/lib/pkgconfig/$pc.pc"
    if [ -f "$f" ]; then
      sed -e "s/^Version:.*/Version: $JXL_VERSION/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  done
  stamp_mark "libjxl-$JXL_VERSION"
fi

if ! stamp_done "libwebp-$WEBP_VERSION"; then
  fetch libwebp "https://github.com/webmproject/libwebp/archive/refs/tags/v$WEBP_VERSION.tar.gz" \
        "libwebp-$WEBP_VERSION.tar.gz" "libwebp-$WEBP_VERSION"
  run_cmake libwebp "$SRCDIR/libwebp-$WEBP_VERSION" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=ON -DWEBP_BUILD_EXTRAS=OFF \
    -DWEBP_BUILD_LIBWEBPMUX=ON -DBUILD_TESTING=OFF
  stamp_mark "libwebp-$WEBP_VERSION"
fi

if ! stamp_done "opus-$OPUS_VERSION"; then
  fetch opus "https://github.com/xiph/opus/releases/download/v$OPUS_VERSION/opus-$OPUS_VERSION.tar.gz" \
        "opus-$OPUS_VERSION.tar.gz" "opus-$OPUS_VERSION"
  run_cmake opus "$SRCDIR/opus-$OPUS_VERSION" \
    -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF -DBUILD_TESTING=OFF
  stamp_mark "opus-$OPUS_VERSION"
fi

if ! stamp_done "libvpx-$LIBVPX_VERSION"; then
  fetch libvpx "https://github.com/webmproject/libvpx/archive/refs/tags/v$LIBVPX_VERSION.tar.gz" \
        "libvpx-$LIBVPX_VERSION.tar.gz" "libvpx-$LIBVPX_VERSION"
  msg "building libvpx"
  # libvpx has its own configure (needs perl for rtcd.pl) and no ninja support.
  rm -rf "$WORKDIR/build-libvpx"; mkdir -p "$WORKDIR/build-libvpx"
  vpx_args="--prefix=$PREFIX --libdir=$PREFIX/lib --disable-shared --enable-static \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth"
  if [ -n "$VPX_TARGET" ]; then
    vpx_args="$vpx_args --target=$VPX_TARGET"
    export CROSS="$CROSS_PREFIX"
  fi
  ( cd "$WORKDIR/build-libvpx" && "$SRCDIR/libvpx-$LIBVPX_VERSION/configure" $vpx_args \
    && make -j"$JOBS" && make install )
  unset CROSS
  purge_shared_libs
  stamp_mark "libvpx-$LIBVPX_VERSION"
fi

if ! stamp_done "libaom-$AOM_VERSION"; then
  fetch libaom "https://storage.googleapis.com/aom-releases/libaom-$AOM_VERSION.tar.gz" \
        "libaom-$AOM_VERSION.tar.gz" "libaom-$AOM_VERSION"
  # ENABLE_APPS (not ENABLE_EXAMPLES) is what gates aomenc/aomdec, and those
  # fail to compile against musl: libaom builds them with -std=c11, which sets
  # __STRICT_ANSI__ and hides fseeko/ftello in musl's headers.
  run_cmake libaom "$SRCDIR/libaom-$AOM_VERSION" \
    -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF \
    -DENABLE_TESTDATA=OFF -DENABLE_TOOLS=OFF -DENABLE_APPS=OFF -DCONFIG_AV1_DECODER=1
  stamp_mark "libaom-$AOM_VERSION"
fi

if ! stamp_done "svtav1-$SVT_AV1_VERSION"; then
  fetch SVT-AV1 "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v$SVT_AV1_VERSION/SVT-AV1-v$SVT_AV1_VERSION.tar.gz" \
        "SVT-AV1-$SVT_AV1_VERSION.tar.gz" "SVT-AV1-v$SVT_AV1_VERSION"
  run_cmake svtav1 "$SRCDIR/SVT-AV1-v$SVT_AV1_VERSION" \
    -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DSVT_AV1_LTO=OFF
  stamp_mark "svtav1-$SVT_AV1_VERSION"
fi

if ! stamp_done "dav1d-$DAV1D_VERSION"; then
  # code.videolan.org archive URLs are bot-blocked; downloads.videolan.org is not.
  fetch dav1d "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" \
        "dav1d-$DAV1D_VERSION.tar.xz" "dav1d-$DAV1D_VERSION"
  msg "building dav1d"
  meson_args="--prefix=$PREFIX --libdir=lib --buildtype=release -Ddefault_library=static -Denable_tools=false -Denable_tests=false"
  if [ -n "$CROSS_PREFIX" ]; then
    if [ "$FF_ARCH" = "aarch64" ]; then dav1d_cpu="aarch64"; else dav1d_cpu="x86_64"; fi
    cat > "$WORKDIR/dav1d-cross.txt" <<EOF
[binaries]
c = '${CROSS_PREFIX}clang'
cpp = '${CROSS_PREFIX}clang++'
ar = '${CROSS_PREFIX}ar'
strip = '${CROSS_PREFIX}strip'
windres = '${CROSS_PREFIX}windres'
pkg-config = 'pkg-config'
nasm = 'nasm'

[host_machine]
system = 'windows'
cpu_family = '$dav1d_cpu'
cpu = '$dav1d_cpu'
endian = 'little'
EOF
    meson_args="$meson_args --cross-file $WORKDIR/dav1d-cross.txt"
  fi
  rm -rf "$WORKDIR/build-dav1d"
  ( cd "$SRCDIR/dav1d-$DAV1D_VERSION" && meson setup "$WORKDIR/build-dav1d" $meson_args \
    && ninja -C "$WORKDIR/build-dav1d" install )
  purge_shared_libs
  stamp_mark "dav1d-$DAV1D_VERSION"
fi

if ! stamp_done "x264-$X264_COMMIT"; then
  # The archive endpoint on code.videolan.org is bot-blocked and the GitHub
  # mirror is years stale, so clone and pin by commit.
  if [ ! -d "$SRCDIR/x264" ]; then
    msg "fetching x264"
    git clone https://code.videolan.org/videolan/x264.git "$SRCDIR/x264"
  fi
  ( cd "$SRCDIR/x264" && git fetch --all --tags && git checkout -q "$X264_COMMIT" )
  msg "building x264"
  x264_args="--prefix=$PREFIX --libdir=$PREFIX/lib --enable-static --disable-shared \
    --disable-cli --disable-opencl --disable-lavf --disable-swscale --disable-ffms --disable-avs"
  if [ -n "$CROSS_PREFIX" ]; then
    x264_args="$x264_args --cross-prefix=$CROSS_PREFIX --host=${CROSS_PREFIX%-}"
  fi
  ( cd "$SRCDIR/x264" && make distclean >/dev/null 2>&1 || true
    ./configure $x264_args && make -j"$JOBS" && make install )
  purge_shared_libs
  stamp_mark "x264-$X264_COMMIT"
fi

if ! stamp_done "x265-$X265_VERSION"; then
  # Use the bitbucket downloads/ tarball: it carries x265Version.txt, without
  # which no x265.pc is generated at all.
  fetch x265 "https://bitbucket.org/multicoreware/x265_git/downloads/x265_$X265_VERSION.tar.gz" \
        "x265-$X265_VERSION.tar.gz" "x265_$X265_VERSION"
  msg "building x265"
  x265_extra="-DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_LIBNUMA=OFF -DLIB_INSTALL_DIR=lib -DENABLE_ASSEMBLY=$X265_ASM"
  if [ "$FF_ARCH" = "aarch64" ] && [ -n "$CROSS_PREFIX" ]; then
    x265_extra="$x265_extra -DCROSS_COMPILE_ARM64=ON"
  fi
  cmake -S "$SRCDIR/x265_$X265_VERSION/source" -B "$WORKDIR/build-x265" $CMAKE_COMMON $CMAKE_CROSS_ARGS $x265_extra
  cmake --build "$WORKDIR/build-x265" --parallel "$JOBS"
  cmake --install "$WORKDIR/build-x265"
  purge_shared_libs
  stamp_mark "x265-$X265_VERSION"
fi

# ---------------------------------------------------------------------------
# pkg-config sanitation
# ---------------------------------------------------------------------------

# x265 copies CMAKE_CXX_IMPLICIT_LINK_LIBRARIES into Libs.private, which on
# Alpine includes -lgcc_s -- and Alpine ships no libgcc_s.a. With
# --pkg-config-flags=--static that makes ffmpeg's configure fail with
# "x265 not found using pkg-config". Strip it from every .pc file.
case "$TARGET" in
  linux-*)
    msg "sanitising pkg-config files"
    for f in "$PREFIX"/lib/pkgconfig/*.pc; do
      [ -f "$f" ] || continue
      sed -e 's/-lgcc_s//g' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
    ;;
esac

msg "verifying dependencies are visible to pkg-config"
for pkg in zlib libjxl libjxl_threads libwebp opus vpx aom SvtAv1Enc dav1d x264 x265; do
  if ! pkg-config --exists --print-errors --static "$pkg"; then
    echo "pkg-config package '$pkg' not found in $PREFIX" >&2
    exit 1
  fi
  printf '  %-14s %s\n' "$pkg" "$(pkg-config --modversion "$pkg")"
done

# ---------------------------------------------------------------------------
# FFmpeg
# ---------------------------------------------------------------------------

FFMPEG_REF="n$FFMPEG_CUSTOM_VERSION"
fetch FFmpeg "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FFMPEG_REF.tar.gz" \
      "ffmpeg-$FFMPEG_CUSTOM_VERSION.tar.gz" "FFmpeg-$FFMPEG_REF"

msg "configuring ffmpeg $FFMPEG_REF for $TARGET"

FF_ARGS="--arch=$FF_ARCH --target-os=$FF_TARGET_OS
  --disable-shared --enable-static --disable-doc --disable-debug --disable-autodetect
  --enable-gpl --enable-runtime-cpudetect --pkg-config-flags=--static --enable-zlib
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom
  --enable-libsvtav1 --enable-libdav1d --enable-libjxl --enable-libwebp --enable-libopus
  $FF_THREADS"

case "$TARGET" in
  win-*)
    FF_ARGS="$FF_ARGS --enable-cross-compile --cross-prefix=$CROSS_PREFIX --pkg-config=pkg-config"
    ;;
  osx-arm64)
    # --disable-autodetect turns these off; they link system frameworks only.
    FF_ARGS="$FF_ARGS --enable-neon --enable-videotoolbox --enable-audiotoolbox"
    ;;
esac

FF_BUILD="$WORKDIR/build-ffmpeg"
rm -rf "$FF_BUILD"; mkdir -p "$FF_BUILD"
(
  cd "$FF_BUILD"
  "$SRCDIR/FFmpeg-$FFMPEG_REF/configure" $FF_ARGS \
    --extra-cflags="-I$PREFIX/include" \
    --extra-cxxflags="-I$PREFIX/include" \
    --extra-ldflags="-L$PREFIX/lib $FF_LDFLAGS" \
    --extra-libs="$CXX_LIB -lm"
  make -j"$JOBS"
)

FFMPEG_OUT="$WORKDIR/ffmpeg-custom-$RID$EXE"
FFPROBE_OUT="$WORKDIR/ffprobe-custom-$RID$EXE"
cp "$FF_BUILD/ffmpeg$EXE" "$FFMPEG_OUT"
cp "$FF_BUILD/ffprobe$EXE" "$FFPROBE_OUT"

msg "stripping"
case "$TARGET" in
  osx-arm64) strip -x "$FFMPEG_OUT" "$FFPROBE_OUT" ;;
  win-*)     "${CROSS_PREFIX}strip" "$FFMPEG_OUT" "$FFPROBE_OUT" ;;
  *)         strip "$FFMPEG_OUT" "$FFPROBE_OUT" ;;
esac
chmod +x "$FFMPEG_OUT" "$FFPROBE_OUT"

ls -lh "$FFMPEG_OUT" "$FFPROBE_OUT"
msg "built $(basename "$FFMPEG_OUT") and $(basename "$FFPROBE_OUT")"
