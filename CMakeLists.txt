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
# hl is one self-contained file: libhl (here) and the Haxeon runtime (below) are compiled into it.
set(HL_LIBHL_IN_VM ON CACHE BOOL "Compile libhl into the hl executable" FORCE)

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
# Files earlier layouts built that nothing uses now. A stale libhl shared library beside libhl.a would be what `-lhl`
# links, and a stale haxeon_runtime.hdll reads as if the VM loaded it.
file(GLOB _haxeon_stale_files
  "${HAXEON_HASHLINK_OUTPUT_DIR}/libhl.so*" "${HAXEON_HASHLINK_OUTPUT_DIR}/libhl*.dylib" "${HAXEON_HASHLINK_OUTPUT_DIR}/libhl.dll"
  "${CMAKE_BINARY_DIR}/runtime/haxeon_runtime.hdll" "${CMAKE_SOURCE_DIR}/out/haxeon_runtime.hdll"
  "${CMAKE_SOURCE_DIR}/out/haxeon-cli.hl" "${CMAKE_SOURCE_DIR}/out/haxeon-cli.hl.inputs")
if(_haxeon_stale_files)
  file(REMOVE ${_haxeon_stale_files})
endif()

# Test libraries the driver loads into hl (by name, from the library path).
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(HAXEON_RUNTIME_OUTPUT_DIR "${CMAKE_BINARY_DIR}/runtime")
else()
  set(HAXEON_RUNTIME_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/out")
endif()

# Libraries the VM loads (test HDLLs, native packages) resolve the libhl and patching API from the executable. This is
# the portable CMake equivalent of HashLink's Makefile --export-dynamic flag and also produces the import library that
# Windows libraries link against.
set_target_properties(hl PROPERTIES ENABLE_EXPORTS ON)

# The main thread of a program that runs Haxe code gets the 8 MB stack Linux and macOS give it. Windows reserves only
# what the executable's header asks for, 1 MB by default, and the compiler's recursion (typing an initializer forces the
# fields it reads, each in a nested typing) overflows that on inputs the other platforms compile.
function(haxeon_use_unix_main_stack target)
  if(MSVC)
    target_link_options(${target} PRIVATE /STACK:8388608)
  elseif(WIN32)
    target_link_options(${target} PRIVATE -Wl,--stack,8388608)
  endif()
endfunction()
haxeon_use_unix_main_stack(hl)

# Native builds consume the checked-in lane policy; ValueLaneRuntimeMain verifies it against the SSA generator.

# The Haxeon runtime, compiled once. Its objects are part of hl, which resolves `haxeon_runtime` natives from itself
# (HAXEON_EMBEDDED_RUNTIME), so the VM and the runtime cannot be out of step and no runtime file is loaded.
add_library(haxeon_runtime_objects OBJECT native/runtime.c)
set_target_properties(haxeon_runtime_objects PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(haxeon_runtime_objects PRIVATE vendor/hashlink/src)
# C11, as HashLink compiles its sources (MSVC's <stdatomic.h> requires it); nothing linked here carries libhl's setting.
set_target_properties(haxeon_runtime_objects PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
# NativeKit is an optional submodule that bootstrap does not fetch. Only the trace sink in native_trace.c uses it.
if(EXISTS "${CMAKE_SOURCE_DIR}/vendor/nativekit/include/nativekit_trace.h")
  target_include_directories(haxeon_runtime_objects PRIVATE vendor/nativekit/include)
  target_compile_definitions(haxeon_runtime_objects PRIVATE HAXEON_WITH_NATIVEKIT)
endif()
if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
  # MSVC gates its C11 <stdatomic.h> implementation behind this opt-in.
  target_compile_options(haxeon_runtime_objects PRIVATE /experimental:c11atomics)
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
set(HAXEON_RUNTIME_SYSTEM_LIBRARIES ${CMAKE_DL_LIBS})
if(WIN32)
  list(APPEND HAXEON_RUNTIME_SYSTEM_LIBRARIES advapi32 bcrypt ws2_32)
endif()
target_link_libraries(haxeon_runtime_objects PRIVATE haxeon_pinned_libffi)
if(MSVC)
  target_compile_definitions(haxeon_runtime_objects PRIVATE FFI_STATIC_BUILD)
endif()

# HashLink links hl with the plain target_link_libraries signature, which a target cannot mix with the keyword one.
target_sources(hl PRIVATE $<TARGET_OBJECTS:haxeon_runtime_objects>)
target_compile_definitions(hl PRIVATE HAXEON_EMBEDDED_RUNTIME)
target_link_libraries(hl haxeon_pinned_libffi ${HAXEON_RUNTIME_SYSTEM_LIBRARIES})

# The VM as a static library: everything in hl but main.c. C programs that host the VM themselves link it, the tests of
# the GC, the profiler and the runtime among them, and each then contains the whole VM. It is named libhl (`-lhl`;
# libhl.lib with MSVC, where hl.lib is the executable's import library).
add_library(hlvm STATIC
  "$<FILTER:$<TARGET_OBJECTS:hl>,EXCLUDE,/src/main\\.c\\.(o|obj)$>"
  $<TARGET_OBJECTS:libhl>
  $<TARGET_OBJECTS:haxeon_runtime_objects>
)
target_include_directories(hlvm INTERFACE vendor/hashlink/src)
target_compile_features(hlvm INTERFACE c_std_11)
target_link_libraries(hlvm INTERFACE haxeon_pinned_libffi ${HAXEON_RUNTIME_SYSTEM_LIBRARIES})
if(WIN32)
  target_link_libraries(hlvm INTERFACE ws2_32 user32 winmm dbghelp dxguid)
else()
  target_link_libraries(hlvm INTERFACE m dl pthread)
endif()
set_target_properties(hlvm PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}")
if(MSVC)
  set_target_properties(hlvm PROPERTIES OUTPUT_NAME libhl)
else()
  set_target_properties(hlvm PROPERTIES OUTPUT_NAME hl)
endif()

# The SDK a `--target=hlc` build compiles against (`--c-sdk`, docs/design/AOT_BACKEND.md): the VM library and libffi in
# lib/, the runtime headers in include/, and the entry point the generated C links with in src/.
set(HAXEON_HLC_SDK_DIR "${CMAKE_BINARY_DIR}/hlc-sdk")
set(_hlc_sdk_headers
  vendor/hashlink/src/hl.h vendor/hashlink/src/hlc.h vendor/hashlink/src/hlmodule.h vendor/hashlink/src/hlsystem.h
  vendor/hashlink/src/opcodes.h vendor/hashlink/src/gc_write.h vendor/hashlink/src/hl_ffi.h)
list(TRANSFORM _hlc_sdk_headers PREPEND "${CMAKE_SOURCE_DIR}/")
add_custom_target(haxeon-hlc-sdk ALL
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${HAXEON_HLC_SDK_DIR}/include" "${HAXEON_HLC_SDK_DIR}/lib"
    "${HAXEON_HLC_SDK_DIR}/src"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${_hlc_sdk_headers} "${HAXEON_HLC_SDK_DIR}/include"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_SOURCE_DIR}/native/aot/hlc_main.c"
    "${CMAKE_SOURCE_DIR}/native/aot/hlc_stack.c" "${HAXEON_HLC_SDK_DIR}/src"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:hlvm>" "${HAXEON_HLC_SDK_DIR}/lib"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:haxeon_pinned_libffi>"
    "${HAXEON_HLC_SDK_DIR}/lib/libffi${CMAKE_STATIC_LIBRARY_SUFFIX}"
  DEPENDS hlvm "${CMAKE_SOURCE_DIR}/native/aot/hlc_main.c" "${CMAKE_SOURCE_DIR}/native/aot/hlc_stack.c"
  COMMENT "Assembling the hlc SDK"
  VERBATIM
)

add_subdirectory(tests/native)

# The wasm32 runtimes committed in stdlib/haxeon/wasm: haxeon-wasm-runtime and haxeon-wasm-runtime-check.
include(cmake/haxeon-wasm-runtime.cmake)

# The haxeon command: the VM with an entry point that runs the Haxeon CLI's bytecode (native/haxeon_main.c), which is
# compiled here with the pinned Haxe from the CLI's sources. It needs the pinned Haxe; without it only hl is built.
set(HAXEON_PINNED_HAXE "${CMAKE_SOURCE_DIR}/.tools/haxe/haxe${CMAKE_EXECUTABLE_SUFFIX}")
set(HAXEON_PROGRAM_STAGING_DIR "${CMAKE_BINARY_DIR}/hashlink-staging")
set(HAXEON_PROGRAMS hl hlprof-live)
if(EXISTS "${HAXEON_PINNED_HAXE}")
  set(HAXEON_CLI_BYTECODE "${HAXEON_HASHLINK_OUTPUT_DIR}/haxeon-cli.hl")
  add_executable(haxeon native/haxeon_main.c native/haxeon_vm_main.c)
  target_include_directories(haxeon PRIVATE vendor/hashlink/src)
  target_link_libraries(haxeon PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,hlvm>")
  target_compile_definitions(haxeon PRIVATE
    "HAXEON_SOURCE_DIR=\"${CMAKE_SOURCE_DIR}\""
    "HAXEON_HASHLINK_DIR=\"${HAXEON_HASHLINK_OUTPUT_DIR}\""
    "HAXEON_CLI_BYTECODE=\"${HAXEON_CLI_BYTECODE}\""
  )
  set_target_properties(haxeon PROPERTIES ENABLE_EXPORTS ON C_STANDARD 11 C_STANDARD_REQUIRED ON)
  haxeon_use_unix_main_stack(haxeon)
  # HashLink's main.c is compiled as hl compiles it.
  foreach(_property IN ITEMS COMPILE_DEFINITIONS COMPILE_OPTIONS)
    get_target_property(_value hl ${_property})
    if(_value)
      set_property(TARGET haxeon APPEND PROPERTY ${_property} "${_value}")
    endif()
  endforeach()
  # On Apple Silicon a JIT needs the allow-jit entitlement, as the HashLink build signs hl (the same condition as its
  # HL_JIT_AARCH64, which is not visible here).
  if(APPLE AND ((CMAKE_OSX_ARCHITECTURES MATCHES "arm64" AND NOT CMAKE_OSX_ARCHITECTURES MATCHES "x86_64")
      OR (NOT CMAKE_OSX_ARCHITECTURES AND CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")))
    add_custom_command(TARGET haxeon POST_BUILD
      COMMAND codesign --force --sign - --entitlements
        "${CMAKE_SOURCE_DIR}/vendor/hashlink/other/osx/hl_jit.entitlements" "$<TARGET_FILE:haxeon>"
      COMMENT "Signing haxeon with allow-jit entitlement"
    )
  endif()
  list(APPEND HAXEON_PROGRAMS haxeon)

  # The CLI's bytecode, rebuilt when a source of the compiler's class paths or the pinned Haxe changes.
  file(GLOB_RECURSE _haxeon_cli_sources CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/*.hx" "${CMAKE_SOURCE_DIR}/lib/*.hx")
  set(_haxeon_cli_staged "${HAXEON_PROGRAM_STAGING_DIR}/haxeon-cli.hl")
  add_custom_command(OUTPUT "${_haxeon_cli_staged}"
    COMMAND "${HAXEON_PINNED_HAXE}" --cwd "${CMAKE_SOURCE_DIR}" common.hxml -main tools.HaxeonCli -hl "${_haxeon_cli_staged}"
    DEPENDS ${_haxeon_cli_sources} "${CMAKE_SOURCE_DIR}/common.hxml" "${HAXEON_PINNED_HAXE}"
    COMMENT "Compiling the Haxeon CLI"
    VERBATIM
  )
  add_custom_command(OUTPUT "${HAXEON_CLI_BYTECODE}"
    COMMAND "${CMAKE_COMMAND}" "-DFROM=${_haxeon_cli_staged}" "-DTO=${HAXEON_CLI_BYTECODE}"
      -P "${CMAKE_SOURCE_DIR}/cmake/haxeon-replace.cmake"
    DEPENDS "${_haxeon_cli_staged}" "${CMAKE_SOURCE_DIR}/cmake/haxeon-replace.cmake"
    COMMENT "Publishing the Haxeon CLI"
    VERBATIM
  )
else()
  message(STATUS "No pinned Haxe at ${HAXEON_PINNED_HAXE}: building hl without the haxeon command (scripts/bootstrap-tools.sh installs it)")
endif()

# The programs link in a staging directory and are published to the HashLink directory by rename, never overwritten
# in place: a running VM (the CLI, the test driver, a compiler worker) keeps the file it started from while the native
# build replaces it. The import library Windows libraries link against stays in the HashLink directory.
set(HAXEON_PUBLISHED_PROGRAMS)
foreach(_program IN LISTS HAXEON_PROGRAMS)
  set_target_properties(${_program} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_PROGRAM_STAGING_DIR}"
    ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
  )
  set(_published "${HAXEON_HASHLINK_OUTPUT_DIR}/${_program}${CMAKE_EXECUTABLE_SUFFIX}")
  add_custom_command(OUTPUT "${_published}"
    COMMAND "${CMAKE_COMMAND}" "-DFROM=$<TARGET_FILE:${_program}>" "-DTO=${_published}"
      -P "${CMAKE_SOURCE_DIR}/cmake/haxeon-replace.cmake"
    DEPENDS ${_program} "$<TARGET_FILE:${_program}>" "${CMAKE_SOURCE_DIR}/cmake/haxeon-replace.cmake"
    COMMENT "Publishing ${_program}"
    VERBATIM
  )
  list(APPEND HAXEON_PUBLISHED_PROGRAMS "${_published}")
endforeach()

# Instrumented native builds link the function hooks from the HashLink tools directory: hlprof_penter.lib for /Gh /GH
# on Windows, libhlprof_hooks.a for the compiler's -finstrument-functions on Linux.
foreach(_hooks IN ITEMS hlprof_penter hlprof_hooks)
  if(TARGET ${_hooks})
    set_target_properties(${_hooks} PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}")
  endif()
endforeach()

add_custom_target(haxeon-native DEPENDS ${HAXEON_PUBLISHED_PROGRAMS} ${HAXEON_CLI_BYTECODE} hldump hlvm jit_native_properties
  haxeon-native-tests)
# What the haxeon launchers bring up to date before running it: the command and the CLI's bytecode.
if(TARGET haxeon)
  add_custom_target(haxeon-command DEPENDS "${HAXEON_HASHLINK_OUTPUT_DIR}/haxeon${CMAKE_EXECUTABLE_SUFFIX}" "${HAXEON_CLI_BYTECODE}")
endif()
foreach(_hooks IN ITEMS hlprof_penter hlprof_hooks)
  if(TARGET ${_hooks})
    add_dependencies(haxeon-native ${_hooks})
  endif()
endforeach()
