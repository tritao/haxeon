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
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  # Keep development binaries from replacing the optimized VM used by tools
  # and performance captures. Each preset has its own CMake build directory.
  set(HAXEON_HASHLINK_OUTPUT_DIR "${CMAKE_BINARY_DIR}/hashlink-runtime")
  set(HAXEON_RUNTIME_OUTPUT_DIR "${CMAKE_BINARY_DIR}/runtime")
else()
  set(HAXEON_HASHLINK_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/.tools/hashlink")
  set(HAXEON_RUNTIME_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/out")
endif()
set_target_properties(hlprof-live PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
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
set(HAXEON_STATIC_LIBFFI_ROOT "${CMAKE_SOURCE_DIR}/.tools/libffi-static")
if(WIN32)
  # The runtime has both /MD and /MDd configurations, so its static libffi
  # archive must use the matching MSVC CRT for each configuration.
  set(HAXEON_LIBFFI_RELEASE_ROOT "${HAXEON_STATIC_LIBFFI_ROOT}/msvc-release")
  set(HAXEON_LIBFFI_DEBUG_ROOT "${HAXEON_STATIC_LIBFFI_ROOT}/msvc-debug")
  find_path(HAXEON_VENDORED_LIBFFI_INCLUDE_DIR NAMES ffi.h
    PATHS "${HAXEON_LIBFFI_RELEASE_ROOT}/include" "${HAXEON_LIBFFI_DEBUG_ROOT}/include"
    NO_DEFAULT_PATH
    REQUIRED
  )
  find_library(HAXEON_VENDORED_LIBFFI_RELEASE_LIBRARY NAMES ffi libffi ffi-8 libffi-8
    PATHS "${HAXEON_LIBFFI_RELEASE_ROOT}/lib"
    NO_DEFAULT_PATH
    REQUIRED
  )
  find_library(HAXEON_VENDORED_LIBFFI_DEBUG_LIBRARY NAMES ffi libffi ffi-8 libffi-8
    PATHS "${HAXEON_LIBFFI_DEBUG_ROOT}/lib"
    NO_DEFAULT_PATH
    REQUIRED
  )
  add_library(haxeon_pinned_libffi STATIC IMPORTED GLOBAL)
  set_target_properties(haxeon_pinned_libffi PROPERTIES
    IMPORTED_CONFIGURATIONS "DEBUG;RELEASE;RELWITHDEBINFO;MINSIZEREL"
    IMPORTED_LOCATION_DEBUG "${HAXEON_VENDORED_LIBFFI_DEBUG_LIBRARY}"
    IMPORTED_LOCATION_RELEASE "${HAXEON_VENDORED_LIBFFI_RELEASE_LIBRARY}"
    IMPORTED_LOCATION_RELWITHDEBINFO "${HAXEON_VENDORED_LIBFFI_RELEASE_LIBRARY}"
    IMPORTED_LOCATION_MINSIZEREL "${HAXEON_VENDORED_LIBFFI_RELEASE_LIBRARY}"
  )
else()
  find_path(HAXEON_VENDORED_LIBFFI_INCLUDE_DIR NAMES ffi.h
    PATHS "${HAXEON_STATIC_LIBFFI_ROOT}/include"
    NO_DEFAULT_PATH
    REQUIRED
  )
  find_library(HAXEON_VENDORED_LIBFFI_LIBRARY NAMES ffi libffi ffi-8 libffi-8
    PATHS "${HAXEON_STATIC_LIBFFI_ROOT}/lib" "${HAXEON_STATIC_LIBFFI_ROOT}/lib64"
    NO_DEFAULT_PATH
    REQUIRED
  )
  add_library(haxeon_pinned_libffi STATIC IMPORTED GLOBAL)
  set_target_properties(haxeon_pinned_libffi PROPERTIES
    IMPORTED_LOCATION "${HAXEON_VENDORED_LIBFFI_LIBRARY}"
  )
endif()
set_target_properties(haxeon_pinned_libffi PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${HAXEON_VENDORED_LIBFFI_INCLUDE_DIR}"
)
target_link_libraries(haxeon_runtime PRIVATE haxeon_pinned_libffi)
if(MSVC)
  target_compile_definitions(haxeon_runtime PRIVATE FFI_STATIC_BUILD)
endif()
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
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_RUNTIME_OUTPUT_DIR}"
  LIBRARY_OUTPUT_DIRECTORY "${HAXEON_RUNTIME_OUTPUT_DIR}"
)

add_subdirectory(tests/native)

set_target_properties(hl libhl PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
  LIBRARY_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
  ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
)

if(UNIX)
  set_target_properties(haxeon_runtime PROPERTIES
    BUILD_RPATH "${HAXEON_HASHLINK_OUTPUT_DIR}"
  )
endif()

add_custom_target(haxeon-native DEPENDS hl hlprof-live haxeon_runtime)
