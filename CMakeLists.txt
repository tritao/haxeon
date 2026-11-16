cmake_minimum_required(VERSION 3.24)

project(haxeon_native LANGUAGES C CXX)

# The sampling profiler walks native stacks along frame pointers; the runtime and the other native targets keep them,
# as the native packages Haxeon builds do.
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/haxeon-frame-pointers.cmake")

# Keep the CRT choice explicit for every MSVC-compatible compiler. This makes
# the Release and Debug presets use the matching dynamic CRT (/MD and /MDd)
# instead of inheriting an undocumented toolchain default.
if(MSVC AND NOT DEFINED CMAKE_MSVC_RUNTIME_LIBRARY)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" CACHE STRING
    "MSVC runtime library used by Haxeon and HashLink")
endif()

# Write PDBs for Release and MinSizeRel MSVC builds (RelWithDebInfo already
# does) so debuggers and the profiler can name native frames with their
# functions and source lines. /Z7 keeps the debug info in each object, which
# avoids a shared compiler PDB under parallel builds, and the explicit /OPT and
# /INCREMENTAL flags keep the linked code identical to a build without /DEBUG.
if(MSVC)
  add_compile_options($<$<CONFIG:Release,MinSizeRel>:/Z7>)
  add_link_options($<$<CONFIG:Release,MinSizeRel>:/DEBUG> $<$<CONFIG:Release,MinSizeRel>:/OPT:REF>
    $<$<CONFIG:Release,MinSizeRel>:/OPT:ICF> $<$<CONFIG:Release,MinSizeRel>:/INCREMENTAL:NO>)
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

option(HAXEON_GC_APPLE_SOFTWARE_TEST "Build unvalidated Apple AArch64 software GC test backend" OFF)
if(HAXEON_GC_APPLE_SOFTWARE_TEST)
  if(NOT APPLE OR NOT CMAKE_OSX_ARCHITECTURES MATCHES "arm64" OR CMAKE_OSX_ARCHITECTURES MATCHES "x86_64")
    message(FATAL_ERROR "Apple software GC tests require an Apple AArch64 target")
  endif()
endif()

add_subdirectory(vendor/hashlink hashlink EXCLUDE_FROM_ALL)
if(HAXEON_GC_APPLE_SOFTWARE_TEST)
  target_compile_definitions(libhl PRIVATE HL_GC_APPLE_SOFTWARE_TEST=1)
endif()
# Keep all built VM binaries in this checkout, away from the shared toolchain.
set(HAXEON_HASHLINK_OUTPUT_DIR "${CMAKE_BINARY_DIR}/hashlink-runtime")
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(HAXEON_RUNTIME_OUTPUT_DIR "${CMAKE_BINARY_DIR}/runtime")
else()
  set(HAXEON_RUNTIME_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/out")
endif()
set_target_properties(hlprof-live PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
)

# Haxeon's HDLL calls the patching API compiled into the VM executable. This is
# the portable CMake equivalent of HashLink's Makefile --export-dynamic flag and
# also produces the import information required by Windows executable exports.
set_target_properties(hl PROPERTIES ENABLE_EXPORTS ON)

# Native builds consume the checked-in lane policy; ValueLaneRuntimeMain verifies it against the SSA generator.

# The runtime is either a library the VM loads (haxeon_runtime.hdll, the default) or, with HAXEON_EMBED_RUNTIME, part of
# the VM executable: the VM then resolves `haxeon_runtime` natives from itself and no runtime file exists. Embedded, the
# VM and the runtime cannot be out of step and no library search path has to name the runtime.
option(HAXEON_EMBED_RUNTIME "Compile the Haxeon runtime into the hl executable instead of haxeon_runtime.hdll" OFF)
if(HAXEON_EMBED_RUNTIME)
  set(HAXEON_RUNTIME_TARGET hl)
  # HashLink links hl with the plain signature, which a target cannot mix with the keyword one.
  set(HAXEON_RUNTIME_LINK_SCOPE "")
  target_sources(hl PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/native/runtime.c")
  target_compile_definitions(hl PRIVATE HAXEON_EMBEDDED_RUNTIME)
else()
  set(HAXEON_RUNTIME_TARGET haxeon_runtime)
  set(HAXEON_RUNTIME_LINK_SCOPE PRIVATE)
  add_library(haxeon_runtime SHARED native/runtime.c)
  target_link_libraries(haxeon_runtime PRIVATE libhl hl)
endif()
target_include_directories(${HAXEON_RUNTIME_TARGET} PRIVATE vendor/hashlink/src)
# NativeKit is an optional submodule that bootstrap does not fetch. Only the trace sink in native_trace.c uses it.
if(EXISTS "${CMAKE_SOURCE_DIR}/vendor/nativekit/include/nativekit_trace.h")
  target_include_directories(${HAXEON_RUNTIME_TARGET} PRIVATE vendor/nativekit/include)
  target_compile_definitions(${HAXEON_RUNTIME_TARGET} PRIVATE HAXEON_WITH_NATIVEKIT)
endif()
if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
  # MSVC gates its C11 <stdatomic.h> implementation behind this opt-in.
  target_compile_options(${HAXEON_RUNTIME_TARGET} PRIVATE /experimental:c11atomics)
endif()
set(HAXEON_STATIC_LIBFFI_ROOT "${CMAKE_SOURCE_DIR}/.tools/libffi-static")
if(WIN32)
  target_link_libraries(${HAXEON_RUNTIME_TARGET} ${HAXEON_RUNTIME_LINK_SCOPE} advapi32 bcrypt ws2_32)
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
target_link_libraries(${HAXEON_RUNTIME_TARGET} ${HAXEON_RUNTIME_LINK_SCOPE} haxeon_pinned_libffi)
if(MSVC)
  target_compile_definitions(${HAXEON_RUNTIME_TARGET} PRIVATE FFI_STATIC_BUILD)
endif()
target_link_libraries(${HAXEON_RUNTIME_TARGET} ${HAXEON_RUNTIME_LINK_SCOPE} ${CMAKE_DL_LIBS})
if(APPLE AND NOT HAXEON_EMBED_RUNTIME)
  # The runtime bridge resolves HashLink's host-owned runtime API from the
  # executable that loads it. Apple ld requires this to be explicit for a
  # shared library; ELF linkers allow the same unresolved host symbols by
  # default.
  target_link_options(haxeon_runtime PRIVATE "-Wl,-undefined,dynamic_lookup")
endif()
if(NOT HAXEON_EMBED_RUNTIME)
  set_target_properties(haxeon_runtime PROPERTIES
    PREFIX ""
    SUFFIX ".hdll"
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_RUNTIME_OUTPUT_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${HAXEON_RUNTIME_OUTPUT_DIR}"
  )
endif()

add_subdirectory(tests/native)

set_target_properties(hl libhl PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
  LIBRARY_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
  ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
)

if(UNIX AND NOT HAXEON_EMBED_RUNTIME)
  set_target_properties(haxeon_runtime PROPERTIES
    BUILD_RPATH "${HAXEON_HASHLINK_OUTPUT_DIR}"
  )
endif()

# Instrumented native builds link the function hooks from the HashLink tools directory: hlprof_penter.lib for /Gh /GH
# on Windows, libhlprof_hooks.a for the compiler's -finstrument-functions on Linux.
foreach(_hooks IN ITEMS hlprof_penter hlprof_hooks)
  if(TARGET ${_hooks})
    set_target_properties(${_hooks} PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}")
  endif()
endforeach()

add_custom_target(haxeon-native DEPENDS hl hldump hlprof-live ${HAXEON_RUNTIME_TARGET} jit_native_properties)
foreach(_hooks IN ITEMS hlprof_penter hlprof_hooks)
  if(TARGET ${_hooks})
    add_dependencies(haxeon-native ${_hooks})
  endif()
endforeach()
