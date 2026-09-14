cmake_minimum_required(VERSION 3.24)

project(haxeon_native LANGUAGES C CXX)

# Keep the CRT choice explicit for every MSVC-compatible compiler. This makes
# the Release and Debug presets use the matching dynamic CRT (/MD and /MDd)
# instead of inheriting an undocumented toolchain default.
if(MSVC AND NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" CACHE STRING
    "MSVC runtime library used by Haxeon and HashLink")
endif()

# HashLink already carries the platform-specific compiler, linker, and system
# library knowledge. Keep it as a real CMake dependency instead of duplicating
# that knowledge in Haxeon's launch scripts.
set(WITH_VM ON CACHE BOOL "Build the HashLink VM" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "Do not build vendored HashLink tests" FORCE)
set(WITH_FMT OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_OPENAL OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_SDL OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_SQLITE OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_SSL OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_UI OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_UV OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_VIDEO OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)
set(WITH_HEAPS OFF CACHE BOOL "Do not build optional HashLink libraries" FORCE)

# The upstream HL2 AArch64 JIT is still being validated against Haxeon's
# legacy backend. Keep the known-good backend as this project's ARM64 default;
# pass -DHL_JIT_AARCH64_OLD=OFF to explicitly exercise the HL2 implementation.
set(HAXEON_AARCH64_JIT_DEFAULT OFF)
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
  if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64" AND NOT CMAKE_OSX_ARCHITECTURES MATCHES "x86_64")
    set(HAXEON_AARCH64_JIT_DEFAULT ON)
  endif()
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(HAXEON_AARCH64_JIT_DEFAULT ON)
endif()
option(HL_JIT_AARCH64_OLD "Use the legacy direct HL-bytecode AArch64 JIT" ${HAXEON_AARCH64_JIT_DEFAULT})

add_subdirectory(vendor/hashlink hashlink EXCLUDE_FROM_ALL)
set_target_properties(hlprof-live PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "$<1:${CMAKE_SOURCE_DIR}/.tools/hashlink>"
)

# Haxeon's HDLL calls the patching API compiled into the VM executable. This is
# the portable CMake equivalent of HashLink's Makefile --export-dynamic flag and
# also produces the import information required by Windows executable exports.
set_target_properties(hl PROPERTIES ENABLE_EXPORTS ON)

add_library(haxeon_runtime SHARED native/runtime.c)
target_include_directories(haxeon_runtime PRIVATE vendor/hashlink/src)
target_link_libraries(haxeon_runtime PRIVATE libhl hl)
if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
  # MSVC gates its C11 <stdatomic.h> implementation behind this opt-in.
  target_compile_options(haxeon_runtime PRIVATE /experimental:c11atomics)
endif()
set(HAXEON_LIBFFI_ROOT "${CMAKE_SOURCE_DIR}/.tools/libffi" CACHE PATH "Pinned libffi installation prefix")
find_path(HAXEON_PINNED_LIBFFI_INCLUDE_DIR NAMES ffi.h
  PATHS "${HAXEON_LIBFFI_ROOT}/include"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(HAXEON_PINNED_LIBFFI_LIBRARY NAMES ffi libffi ffi-8 libffi-8
  PATHS "${HAXEON_LIBFFI_ROOT}/lib" "${HAXEON_LIBFFI_ROOT}/lib64"
  NO_DEFAULT_PATH
  REQUIRED
)
target_include_directories(haxeon_runtime PRIVATE "${HAXEON_PINNED_LIBFFI_INCLUDE_DIR}")
target_link_libraries(haxeon_runtime PRIVATE "${HAXEON_PINNED_LIBFFI_LIBRARY}")
target_link_libraries(haxeon_runtime PRIVATE ${CMAKE_DL_LIBS})
if(APPLE)
  # The runtime bridge resolves HashLink's host-owned runtime API from the
  # executable that loads it. Apple ld requires this to be explicit for a
  # shared library; ELF linkers allow the same unresolved host symbols by
  # default.
  target_link_options(haxeon_runtime PRIVATE "-Wl,-undefined,dynamic_lookup")
endif()
set_target_properties(haxeon_runtime PROPERTIES
  PREFIX ""
  SUFFIX ".hdll"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/out"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/out"
)

add_subdirectory(tests/native)

set_target_properties(hl libhl PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
)

if(UNIX)
  set_target_properties(haxeon_runtime PROPERTIES
    BUILD_RPATH "${CMAKE_SOURCE_DIR}/.tools/hashlink;${HAXEON_LIBFFI_ROOT}/lib"
  )
endif()

add_custom_target(haxeon-native DEPENDS hl hlprof-live haxeon_runtime)
