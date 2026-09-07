# CMake toolchain file for cross-compiling to Windows with llvm-mingw.
# Pass -DMINGW_TRIPLE=x86_64-w64-mingw32 or -DMINGW_TRIPLE=aarch64-w64-mingw32.

set(CMAKE_SYSTEM_NAME Windows)

# CMake re-includes this file for every try_compile sub-project, but does NOT
# forward -DMINGW_TRIPLE to them, so fall back to the environment and ask CMake
# to carry the variable across.
if(NOT MINGW_TRIPLE)
  set(MINGW_TRIPLE "$ENV{MINGW_TRIPLE}")
endif()
if(NOT MINGW_TRIPLE)
  message(FATAL_ERROR "MINGW_TRIPLE must be set (x86_64-w64-mingw32 or aarch64-w64-mingw32)")
endif()
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES MINGW_TRIPLE)

if(MINGW_TRIPLE MATCHES "^aarch64")
  set(CMAKE_SYSTEM_PROCESSOR aarch64)
else()
  set(CMAKE_SYSTEM_PROCESSOR x86_64)
endif()

set(CMAKE_C_COMPILER   "${MINGW_TRIPLE}-clang")
set(CMAKE_CXX_COMPILER "${MINGW_TRIPLE}-clang++")
set(CMAKE_ASM_COMPILER "${MINGW_TRIPLE}-clang")
set(CMAKE_RC_COMPILER  "${MINGW_TRIPLE}-windres")
set(CMAKE_AR           "${MINGW_TRIPLE}-ar")
set(CMAKE_RANLIB       "${MINGW_TRIPLE}-ranlib")
set(CMAKE_STRIP        "${MINGW_TRIPLE}-strip")

# Look for headers and libraries only in the cross prefix, never on the host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
