#!/usr/bin/env bash
#
# Builds x265 as a "multilib": a single static libx265 that encodes 8, 10 and
# 12 bits, and optionally the x265 command-line tool linked with it.
#
# This file is sourced, not executed, by scripts/build-ffmpeg.sh and
# scripts/build-libheif.sh, so that ffmpeg, the x265 tool and heif-enc are
# built with the same x265:
#
#   . "$SCRIPT_DIR/x265-multilib.sh"
#   build_x265_multilib <build directory prefix> <ON|OFF: build the tool> <linker flags of the tool>
#
# It uses the helpers and the variables of the calling script: msg, fetch,
# purge_shared_libs, TARGET, WORKDIR, SRCDIR, PREFIX, JOBS, CMAKE_COMMON,
# CMAKE_CROSS_ARGS, X265_VERSION and, when cross-compiling, MINGW_TRIPLE.
# X265_ASM=OFF turns the assembly off.
#
# x265 is compiled for one bit depth at a time. As its own
# build/linux/multilib.sh does, the 10 and 12-bit libraries are built without
# the C API (EXPORT_C_API=OFF; everything they define is in the x265_10bit and
# x265_12bit namespaces), and the 8-bit library is told they are linked with it
# (LINKED_10BIT, LINKED_12BIT), which is what makes x265_api_get(10) and
# x265_api_get(12) return them. The three archives are then merged into the
# libx265.a that x265.pc points to.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

build_x265_multilib() {
  x265_build="$1"; x265_cli="$2"; x265_ldflags="$3"

  # Use the bitbucket downloads/ tarball: it carries x265Version.txt, without
  # which no x265.pc is generated at all.
  fetch x265 "https://bitbucket.org/multicoreware/x265_git/downloads/x265_$X265_VERSION.tar.gz" \
        "x265-$X265_VERSION.tar.gz" "x265_$X265_VERSION"
  x265_source="$SRCDIR/x265_$X265_VERSION/source"

  x265_common="-DENABLE_SHARED=OFF -DENABLE_LIBNUMA=OFF -DLIB_INSTALL_DIR=lib -DENABLE_ASSEMBLY=${X265_ASM:-ON}"
  case "$MINGW_TRIPLE" in
    aarch64-*) x265_common="$x265_common -DCROSS_COMPILE_ARM64=ON" ;;
  esac

  for x265_depth in 12 10; do
    msg "building x265 ($x265_depth-bit)"
    x265_depth_args="-DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF"
    [ "$x265_depth" != 12 ] || x265_depth_args="$x265_depth_args -DMAIN12=ON"
    # shellcheck disable=SC2086
    cmake -S "$x265_source" -B "$WORKDIR/$x265_build-${x265_depth}bit" $CMAKE_COMMON $CMAKE_CROSS_ARGS \
      $x265_common $x265_depth_args
    cmake --build "$WORKDIR/$x265_build-${x265_depth}bit" --parallel "$JOBS" --target x265-static
  done

  msg "building x265 (8-bit)"
  # EXTRA_LIB is what the x265 tool is linked with next to the 8-bit library.
  # It must be set even without the tool: LINKED_10BIT and LINKED_12BIT are
  # ignored otherwise.
  # shellcheck disable=SC2086
  cmake -S "$x265_source" -B "$WORKDIR/$x265_build" $CMAKE_COMMON $CMAKE_CROSS_ARGS $x265_common \
    "-DEXTRA_LIB=$WORKDIR/$x265_build-10bit/libx265.a;$WORKDIR/$x265_build-12bit/libx265.a" \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON -DENABLE_CLI="$x265_cli" \
    "-DCMAKE_EXE_LINKER_FLAGS=$x265_ldflags"
  cmake --build "$WORKDIR/$x265_build" --parallel "$JOBS"
  cmake --install "$WORKDIR/$x265_build"
  purge_shared_libs

  msg "merging the 8, 10 and 12-bit x265 libraries"
  # The three archives have members of the same name, so they are merged as
  # archives (libtool -static, ADDLIB) rather than extracted and repacked.
  rm -f "$PREFIX/lib/libx265.a"
  case "$TARGET" in
    osx-*)
      libtool -static -o "$PREFIX/lib/libx265.a" \
        "$WORKDIR/$x265_build/libx265.a" \
        "$WORKDIR/$x265_build-10bit/libx265.a" \
        "$WORKDIR/$x265_build-12bit/libx265.a"
      ;;
    *)
      # The MRI script takes file names without quoting, hence the copies
      # next to each other and the relative names.
      rm -rf "$WORKDIR/$x265_build-merge"; mkdir -p "$WORKDIR/$x265_build-merge"
      cp "$WORKDIR/$x265_build/libx265.a" "$WORKDIR/$x265_build-merge/main.a"
      cp "$WORKDIR/$x265_build-10bit/libx265.a" "$WORKDIR/$x265_build-merge/main10.a"
      cp "$WORKDIR/$x265_build-12bit/libx265.a" "$WORKDIR/$x265_build-merge/main12.a"
      (
        cd "$WORKDIR/$x265_build-merge"
        printf 'CREATE libx265.a\nADDLIB main.a\nADDLIB main10.a\nADDLIB main12.a\nSAVE\nEND\n' \
          | "${MINGW_TRIPLE:+$MINGW_TRIPLE-}ar" -M
      )
      cp "$WORKDIR/$x265_build-merge/libx265.a" "$PREFIX/lib/libx265.a"
      rm -rf "$WORKDIR/$x265_build-merge"
      ;;
  esac
  [ -s "$PREFIX/lib/libx265.a" ] || { echo "the merged libx265.a was not written" >&2; exit 1; }
}
