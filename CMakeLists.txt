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
# The SDK this build makes (docs/design/SDK_LAYOUT.md). The build of a preset the path table names (out/cmake/PRESET with an
# entry in cmake/hashlink-output-paths.txt, which the scripts read too) publishes the checkout's own, whose bin the table gives;
# any other build stages one in its build directory, so it never replaces the VM the checkout runs.
set(_sdk_default "${CMAKE_BINARY_DIR}/sdk")
get_filename_component(_build_name "${CMAKE_BINARY_DIR}" NAME)
if(CMAKE_BINARY_DIR STREQUAL "${CMAKE_SOURCE_DIR}/out/cmake/${_build_name}")
  file(STRINGS "${CMAKE_SOURCE_DIR}/cmake/hashlink-output-paths.txt" _path_entries REGEX "^${_build_name}=")
  if(_path_entries)
    string(REGEX REPLACE "^[^=]*=(.*)/bin$" "\\1" _sdk_relative "${_path_entries}")
    set(_sdk_default "${CMAKE_SOURCE_DIR}/${_sdk_relative}")
  endif()
endif()
set(HAXEON_SDK_DIR "${_sdk_default}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/cmake/hashlink-output-paths.txt")
# The VM and the programs beside it are the SDK's bin, which the haxeon launcher finds the SDK from (bin/..).
set(HAXEON_HASHLINK_OUTPUT_DIR "${HAXEON_SDK_DIR}/bin")
# The directory earlier layouts published the VM in.
file(REMOVE_RECURSE "${CMAKE_BINARY_DIR}/hashlink-runtime")
# Files earlier layouts built that nothing uses now. A stale libhl shared library beside libhl.a would be what `-lhl`
# links, and a stale haxeon_runtime.hdll reads as if the VM loaded it. haxeon-compiler was the executable built ahead of
# time before it held the CLI (now haxeon-aot), with its C build in out/aot-compiler.
file(GLOB _haxeon_stale_files
  "${HAXEON_HASHLINK_OUTPUT_DIR}/libhl.so*" "${HAXEON_HASHLINK_OUTPUT_DIR}/libhl*.dylib" "${HAXEON_HASHLINK_OUTPUT_DIR}/libhl.dll"
  "${CMAKE_BINARY_DIR}/runtime/haxeon_runtime.hdll" "${CMAKE_SOURCE_DIR}/out/haxeon_runtime.hdll"
  "${CMAKE_SOURCE_DIR}/out/haxeon-cli.hl" "${CMAKE_SOURCE_DIR}/out/haxeon-cli.hl.inputs"
  "${HAXEON_HASHLINK_OUTPUT_DIR}/haxeon-compiler" "${HAXEON_HASHLINK_OUTPUT_DIR}/haxeon-compiler.exe"
  "${HAXEON_HASHLINK_OUTPUT_DIR}/haxeon-compiler.sources" "${HAXEON_HASHLINK_OUTPUT_DIR}/haxeon-compiler.pdb")
if(_haxeon_stale_files)
  file(REMOVE ${_haxeon_stale_files})
endif()
file(REMOVE_RECURSE "${CMAKE_SOURCE_DIR}/out/aot-compiler")

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

# The VM of an app's runner (docs/design/PROJECT_BUILDS.md, the SDK's lib/libhaxeon-app): hlvm with HashLink's entry point
# (hl_vm_main) and the app entry point that starts it on the module beside the executable (native/app/haxeon_app_main.c).
# The runner compiles only a two-line main (native/app/haxeon_app.c), so these are compiled here with hl's own flags.
add_library(haxeon_app_entry OBJECT native/haxeon_vm_main.c native/app/haxeon_app_main.c)
target_include_directories(haxeon_app_entry PRIVATE vendor/hashlink/src)
set_target_properties(haxeon_app_entry PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON POSITION_INDEPENDENT_CODE ON)
foreach(_property IN ITEMS COMPILE_DEFINITIONS COMPILE_OPTIONS)
  get_target_property(_value hl ${_property})
  if(_value)
    set_property(TARGET haxeon_app_entry APPEND PROPERTY ${_property} "${_value}")
  endif()
endforeach()
add_library(haxeon_app STATIC
  "$<FILTER:$<TARGET_OBJECTS:hl>,EXCLUDE,/src/main\\.c\\.(o|obj)$>"
  $<TARGET_OBJECTS:libhl>
  $<TARGET_OBJECTS:haxeon_runtime_objects>
  $<TARGET_OBJECTS:haxeon_app_entry>
)
set_target_properties(haxeon_app PROPERTIES OUTPUT_NAME haxeon-app)

# The VM library of executables compiled ahead of time (the SDK's lib/<target>/libhl-aot): hlvm with no JIT. Its objects are hlvm's
# but for the JIT's, whose entry points jit_none.c gives as a VM without the JIT (hl_module_init_aot only).
include(vendor/hashlink/cmake/hl-sources.cmake)
add_library(hlvm_jit_none OBJECT ${HL_NO_JIT_SOURCES})
target_include_directories(hlvm_jit_none PRIVATE vendor/hashlink/src)
set_target_properties(hlvm_jit_none PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON POSITION_INDEPENDENT_CODE ON)
# zlib's inflate, with which the stack traces read the compressed DWARF of release executables (native/aot/hlc_stack.c): prefixed
# and hidden, so it never meets another zlib a native library brings.
add_library(hlc_zlib OBJECT
  vendor/hashlink/include/zlib/adler32.c vendor/hashlink/include/zlib/crc32.c vendor/hashlink/include/zlib/inffast.c
  vendor/hashlink/include/zlib/inflate.c vendor/hashlink/include/zlib/inftrees.c vendor/hashlink/include/zlib/zutil.c)
target_compile_definitions(hlc_zlib PRIVATE Z_PREFIX)
set_target_properties(hlc_zlib PROPERTIES C_VISIBILITY_PRESET hidden POSITION_INDEPENDENT_CODE ON)
add_library(hlvm_aot STATIC
  "$<FILTER:$<TARGET_OBJECTS:hl>,EXCLUDE,/src/(main|jit[a-z0-9_]*)\\.c\\.(o|obj)$>"
  $<TARGET_OBJECTS:hlvm_jit_none>
  $<TARGET_OBJECTS:hlc_zlib>
  $<TARGET_OBJECTS:libhl>
  $<TARGET_OBJECTS:haxeon_runtime_objects>
)
set_target_properties(hlvm_aot PROPERTIES OUTPUT_NAME hl-aot)

# The SDK a `--target=hlc` build compiles against (`--c-sdk`, docs/design/AOT_BACKEND.md): the VM library without the JIT and libffi in
# lib/, the runtime headers and the generated C's fixed part (native/aot/hlc_prelude.h) in include/, the entry point the generated C
# links with in src/, and in `target` the target it was built for, as build.Target spells it (OS-ARCH-ABI, macos-ARCH), from which
# the C build takes its default toolchain and checks a chosen one.
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _sdk_arch)
if(_sdk_arch MATCHES "^(amd64|x86_64|x64)$")
  set(_sdk_arch x86_64)
elseif(_sdk_arch MATCHES "^(aarch64|arm64)$")
  set(_sdk_arch arm64)
endif()
if(WIN32)
  if(MSVC)
    set(_sdk_target "windows-${_sdk_arch}-msvc")
  else()
    set(_sdk_target "windows-${_sdk_arch}-gnu")
  endif()
elseif(APPLE)
  set(_sdk_target "macos-${_sdk_arch}")
else()
  set(_sdk_target "linux-${_sdk_arch}-gnu")
endif()
set(_sdk_headers
  vendor/hashlink/src/hl.h vendor/hashlink/src/hlc.h vendor/hashlink/src/hlmodule.h vendor/hashlink/src/hlsystem.h
  vendor/hashlink/src/opcodes.h vendor/hashlink/src/gc_write.h vendor/hashlink/src/hl_ffi.h
  vendor/hashlink/include/zlib/zlib.h vendor/hashlink/include/zlib/zconf.h native/aot/hlc_prelude.h)
list(TRANSFORM _sdk_headers PREPEND "${CMAKE_SOURCE_DIR}/")

# The SDK (docs/design/SDK_LAYOUT.md): what an app's runner and an ahead-of-time build consume, in the layout a release ships.
# A checkout stages it in HAXEON_SDK_DIR (out/sdk); its manifest names the checkout's own stdlib and templates, and the checkout
# as the source root. Libraries go under lib/<target>, the target this build makes them for. The manifest is written when
# CMake configures, as the launcher reads it before anything is built.
file(STRINGS "${CMAKE_SOURCE_DIR}/src/project/PackageCompatibility.hx" _haxeon_version_line
  REGEX "CURRENT_HAXEON = \"[0-9]+\\.[0-9]+\\.[0-9]+\"")
string(REGEX MATCH "[0-9]+\\.[0-9]+\\.[0-9]+" HAXEON_VERSION "${_haxeon_version_line}")
if(NOT HAXEON_VERSION)
  message(FATAL_ERROR "No CURRENT_HAXEON in src/project/PackageCompatibility.hx")
endif()
set(_sdk_generated "${CMAKE_BINARY_DIR}/sdk-generated")
include(CMakePackageConfigHelpers)
write_basic_package_version_file("${_sdk_generated}/HaxeonConfigVersion.cmake" VERSION "${HAXEON_VERSION}"
  COMPATIBILITY SameMinorVersion ARCH_INDEPENDENT)
file(CONFIGURE OUTPUT "${HAXEON_SDK_DIR}/haxeon-sdk.toml" CONTENT "# Haxeon's SDK manifest (docs/design/SDK_LAYOUT.md).
version = \"${HAXEON_VERSION}\"
# The checkout this SDK was built from: its tools, sources and tests.
source = \"${CMAKE_SOURCE_DIR}\"

[roots]
stdlib = \"${CMAKE_SOURCE_DIR}/stdlib\"
templates = \"${CMAKE_SOURCE_DIR}/templates\"
")
set(_sdk_lib "${HAXEON_SDK_DIR}/lib/${_sdk_target}")
add_custom_target(haxeon-sdk ALL
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_sdk_lib}" "${HAXEON_SDK_DIR}/include" "${HAXEON_SDK_DIR}/src"
    "${HAXEON_SDK_DIR}/cmake"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:hlvm>" "${_sdk_lib}/${CMAKE_STATIC_LIBRARY_PREFIX}hl${CMAKE_STATIC_LIBRARY_SUFFIX}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:hlvm_aot>" "${_sdk_lib}/${CMAKE_STATIC_LIBRARY_PREFIX}hl-aot${CMAKE_STATIC_LIBRARY_SUFFIX}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:haxeon_app>" "${_sdk_lib}/${CMAKE_STATIC_LIBRARY_PREFIX}haxeon-app${CMAKE_STATIC_LIBRARY_SUFFIX}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:haxeon_pinned_libffi>" "${_sdk_lib}/${CMAKE_STATIC_LIBRARY_PREFIX}ffi${CMAKE_STATIC_LIBRARY_SUFFIX}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${_sdk_headers} "${HAXEON_SDK_DIR}/include"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_SOURCE_DIR}/native/app/haxeon_app.c"
    "${CMAKE_SOURCE_DIR}/native/aot/hlc_main.c" "${CMAKE_SOURCE_DIR}/native/aot/hlc_stack.c" "${HAXEON_SDK_DIR}/src"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_SOURCE_DIR}/cmake/sdk/HaxeonConfig.cmake"
    "${CMAKE_SOURCE_DIR}/cmake/sdk/HaxeonApp.cmake" "${_sdk_generated}/HaxeonConfigVersion.cmake" "${HAXEON_SDK_DIR}/cmake"
  DEPENDS hlvm hlvm_aot haxeon_app "${CMAKE_SOURCE_DIR}/native/app/haxeon_app.c" "${CMAKE_SOURCE_DIR}/native/aot/hlc_main.c"
    "${CMAKE_SOURCE_DIR}/native/aot/hlc_stack.c" "${CMAKE_SOURCE_DIR}/cmake/sdk/HaxeonConfig.cmake"
    "${CMAKE_SOURCE_DIR}/cmake/sdk/HaxeonApp.cmake"
  COMMENT "Staging the Haxeon SDK in ${HAXEON_SDK_DIR}"
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
  haxeon-sdk
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
