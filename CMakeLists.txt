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
add_subdirectory(vendor/hashlink hashlink EXCLUDE_FROM_ALL)

# Haxeon's HDLL calls the patching API compiled into the VM executable. This is
# the portable CMake equivalent of HashLink's Makefile --export-dynamic flag and
# also produces the import information required by Windows executable exports.
set_target_properties(hl PROPERTIES ENABLE_EXPORTS ON)

add_library(haxeon_runtime SHARED native/runtime.c)
target_include_directories(haxeon_runtime PRIVATE vendor/hashlink/src)
target_link_libraries(haxeon_runtime PRIVATE libhl hl)
find_library(HAXEON_LIBFFI_LIBRARY NAMES ffi REQUIRED)
target_link_libraries(haxeon_runtime PRIVATE "${HAXEON_LIBFFI_LIBRARY}" ${CMAKE_DL_LIBS})
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

set_target_properties(hl libhl PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
)

if(UNIX)
  set_target_properties(haxeon_runtime PROPERTIES
    BUILD_RPATH "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  )
endif()

add_custom_target(haxeon-native DEPENDS hl haxeon_runtime)
