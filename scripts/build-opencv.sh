#!/usr/bin/env bash
#
# Builds a statically linked opencv-oracle, the command-line tool of this
# repository (scripts/opencv-oracle.cpp) that runs OpenCV functions on images
# and points and prints their results as JSON, with OpenCV built from the
# release tarball:
#
#   opencv-oracle-<target>[.exe]
#
#   bash scripts/build-opencv.sh <target>
#
# Targets: linux-x64 | linux-arm64 | win-x64 | osx-arm64
#
# OpenCV is built with the modules the tool uses only: core, imgproc,
# calib3d, features2d, flann (which calib3d and features2d need), photo and
# imgcodecs, with PNG (the libpng and zlib of the OpenCV sources) and no other
# image format, statically, and without the GUI, video, DNN, IPP, OpenCL,
# Eigen, LAPACK and any other optional library. The parallel framework is not
# built (no pthreads, OpenMP or TBB): every function runs on one thread.
#
# win-x64 is cross-compiled from Linux with llvm-mingw; point LLVM_MINGW_ROOT at
# the extracted toolchain. Every other target builds natively.
#
# OPENCV_VERSION comes from the environment (see .github/workflows/ci.yml).
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

TARGET="$1"
case "$TARGET" in
  linux-x64|linux-arm64|win-x64|osx-arm64) ;;
  *) echo "usage: $0 <linux-x64|linux-arm64|win-x64|osx-arm64>" >&2; exit 2 ;;
esac

TOOL_ID=opencv
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pdf-deps.sh"

require_versions OPENCV_VERSION

# OpenCV uses std::back_inserter without <iterator>, which the libc++ of
# llvm-mingw does not include from the other headers.
CXX_FLAGS_ARGS=""
[ "$TARGET" = win-x64 ] && CXX_FLAGS_ARGS="-DCMAKE_CXX_FLAGS=-include iterator"

if ! stamp_done "opencv-$OPENCV_VERSION"; then
  fetch OpenCV "https://github.com/opencv/opencv/archive/refs/tags/$OPENCV_VERSION.tar.gz" \
        "opencv-$OPENCV_VERSION.tar.gz" "opencv-$OPENCV_VERSION"
  # shellcheck disable=SC2086
  run_cmake opencv "$SRCDIR/opencv-$OPENCV_VERSION" ${CXX_FLAGS_ARGS:+"$CXX_FLAGS_ARGS"} \
    -DBUILD_LIST=core,imgproc,calib3d,features2d,flann,photo,imgcodecs \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF -DBUILD_opencv_apps=OFF \
    -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF -DBUILD_opencv_python_bindings_generator=OFF -DBUILD_opencv_js=OFF \
    -DBUILD_ZLIB=ON -DBUILD_PNG=ON -DWITH_PNG=ON -DWITH_SPNG=OFF -DWITH_JPEG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
    -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DWITH_OPENEXR=OFF -DWITH_IMGCODEC_HDR=OFF -DWITH_IMGCODEC_SUNRASTER=OFF \
    -DWITH_IMGCODEC_PXM=OFF -DWITH_IMGCODEC_PFM=OFF -DWITH_AVIF=OFF -DWITH_JPEGXL=OFF -DWITH_GDAL=OFF -DWITH_GDCM=OFF \
    -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_OPENCLAMDFFT=OFF -DWITH_OPENCLAMDBLAS=OFF -DWITH_VA=OFF \
    -DWITH_LAPACK=OFF -DWITH_EIGEN=OFF -DWITH_PTHREADS_PF=OFF -DWITH_OPENMP=OFF -DWITH_TBB=OFF -DWITH_HPX=OFF \
    -DWITH_PROTOBUF=OFF -DWITH_QUIRC=OFF -DWITH_ADE=OFF -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_V4L=OFF \
    -DWITH_GTK=OFF -DWITH_QT=OFF -DWITH_WIN32UI=OFF -DWITH_COCOA=OFF -DWITH_OBSENSOR=OFF -DWITH_DSHOW=OFF -DWITH_MSMF=OFF \
    -DWITH_CAROTENE=OFF -DWITH_KLEIDICV=OFF -DWITH_FASTCV=OFF -DWITH_NDSRVP=OFF -DWITH_VULKAN=OFF -DWITH_CUDA=OFF \
    -DOPENCV_GENERATE_PKGCONFIG=OFF -DOPENCV_ENABLE_NONFREE=OFF -DBUILD_WITH_STATIC_CRT=ON -DENABLE_PRECOMPILED_HEADERS=OFF \
    -DOPENCV_BIN_INSTALL_PATH=bin -DOPENCV_LIB_INSTALL_PATH=lib -DOPENCV_3P_LIB_INSTALL_PATH=lib -DOPENCV_CONFIG_INSTALL_PATH=lib/cmake/opencv4
  stamp_mark "opencv-$OPENCV_VERSION"
fi

# The tool: a CMake project of one file, linked with the OpenCV of the prefix.
APP="$WORKDIR/build-opencv-oracle-src"
rm -rf "$APP"
mkdir -p "$APP"
cp "$SCRIPT_DIR/opencv-oracle.cpp" "$APP/"
cat > "$APP/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(opencv_oracle CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(OpenCV REQUIRED COMPONENTS core imgproc calib3d features2d photo imgcodecs)
add_executable(opencv-oracle opencv-oracle.cpp)
target_link_libraries(opencv-oracle PRIVATE ${OpenCV_LIBS})
CMAKE
BUILD="$WORKDIR/build-opencv-oracle"
msg "building opencv-oracle with OpenCV $OPENCV_VERSION for $TARGET"
rm -rf "$BUILD"
# shellcheck disable=SC2086
cmake -S "$APP" -B "$BUILD" $CMAKE_COMMON $CMAKE_CROSS_ARGS -DOpenCV_DIR="$PREFIX/lib/cmake/opencv4" \
  -DOpenCV_STATIC=ON "-DCMAKE_EXE_LINKER_FLAGS=$EXE_LDFLAGS"
cmake --build "$BUILD" --parallel "$JOBS"

out="$WORKDIR/opencv-oracle-$TARGET$EXE"
cp "$BUILD/opencv-oracle$EXE" "$out"
finish_outputs "$out"
msg "built opencv-oracle for $TARGET"
