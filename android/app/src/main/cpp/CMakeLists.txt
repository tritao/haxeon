cmake_minimum_required(VERSION 3.24)
project(haxeon_android LANGUAGES C)
enable_language(ASM)

set(HAXEON_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../..")
get_filename_component(HAXEON_ROOT "${HAXEON_ROOT}" ABSOLUTE)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build HashLink as a static library for the Android host" FORCE)
set(WITH_VM OFF CACHE BOOL "The Android host supplies the VM executable sources" FORCE)
set(HL_BUILD_TESTS OFF CACHE BOOL "Do not build HashLink tests for Android" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "Do not build HashLink tests for Android" FORCE)
set(HL_JIT_AARCH64_OLD_DEFAULT OFF)
if(NOT EXISTS "${HAXEON_ROOT}/vendor/hashlink/src/jit_aarch64.c"
    OR NOT EXISTS "${HAXEON_ROOT}/vendor/hashlink/src/jit_aarch64_emit.c")
    set(HL_JIT_AARCH64_OLD_DEFAULT ON)
endif()
option(HL_JIT_AARCH64_OLD
    "Use the legacy direct HL-bytecode AArch64 JIT instead of the HL2 IR backend"
    ${HL_JIT_AARCH64_OLD_DEFAULT})

# Android does not ship libffi headers or a runtime library in its NDK. Build
# the pinned upstream submodule with the same NDK compiler and link it
# statically so Haxeon's native-call bridge remains available in Android
# projects.
set(HAXEON_LIBFFI_VERSION "3.8.0")
set(HAXEON_LIBFFI_SOURCE_DIR "${HAXEON_ROOT}/vendor/libffi")
set(HAXEON_LIBFFI_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/haxeon-libffi-generated")
if(NOT EXISTS "${HAXEON_LIBFFI_SOURCE_DIR}/include/ffi.h.in")
    message(FATAL_ERROR
        "libffi ${HAXEON_LIBFFI_VERSION} submodule is missing; run git submodule update --init vendor/libffi")
endif()
file(MAKE_DIRECTORY "${HAXEON_LIBFFI_GENERATED_DIR}")

if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(HAXEON_LIBFFI_TARGET "AARCH64")
    set(HAXEON_LIBFFI_ARCH_DIR "aarch64")
    set(HAXEON_LIBFFI_ARCH_SOURCES
        "${HAXEON_LIBFFI_SOURCE_DIR}/src/aarch64/ffi.c"
        "${HAXEON_LIBFFI_SOURCE_DIR}/src/aarch64/sysv.S")
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(HAXEON_LIBFFI_TARGET "X86_64")
    set(HAXEON_LIBFFI_ARCH_DIR "x86")
    set(HAXEON_LIBFFI_ARCH_SOURCES
        "${HAXEON_LIBFFI_SOURCE_DIR}/src/x86/ffi64.c"
        "${HAXEON_LIBFFI_SOURCE_DIR}/src/x86/unix64.S"
        "${HAXEON_LIBFFI_SOURCE_DIR}/src/x86/ffiw64.c"
        "${HAXEON_LIBFFI_SOURCE_DIR}/src/x86/win64.S")
else()
    message(FATAL_ERROR "Haxeon Android libffi does not support ABI ${ANDROID_ABI}")
endif()

function(haxeon_generate_libffi_header output_path ffi_target)
    set(VERSION "${HAXEON_LIBFFI_VERSION}")
    set(TARGET "${ffi_target}")
    set(HAVE_LONG_DOUBLE 1)
    set(FFI_EXEC_TRAMPOLINE_TABLE 0)
    set(FFI_VERSION_STRING "${HAXEON_LIBFFI_VERSION}")
    string(REPLACE "." ";" ffi_version_parts "${HAXEON_LIBFFI_VERSION}")
    list(GET ffi_version_parts 0 ffi_version_major)
    list(GET ffi_version_parts 1 ffi_version_minor)
    list(GET ffi_version_parts 2 ffi_version_patch)
    math(EXPR FFI_VERSION_NUMBER "${ffi_version_major} * 10000 + ${ffi_version_minor} * 100 + ${ffi_version_patch}")
    configure_file(
        "${HAXEON_LIBFFI_SOURCE_DIR}/include/ffi.h.in"
        "${output_path}"
        @ONLY)
endfunction()
haxeon_generate_libffi_header(
    "${HAXEON_LIBFFI_GENERATED_DIR}/ffi.h"
    "${HAXEON_LIBFFI_TARGET}")
configure_file(
    "${CMAKE_CURRENT_LIST_DIR}/libffi-fficonfig-android.h"
    "${HAXEON_LIBFFI_GENERATED_DIR}/fficonfig.h"
    COPYONLY)

add_library(haxeon_libffi STATIC
    "${HAXEON_LIBFFI_SOURCE_DIR}/src/prep_cif.c"
    "${HAXEON_LIBFFI_SOURCE_DIR}/src/types.c"
    "${HAXEON_LIBFFI_SOURCE_DIR}/src/raw_api.c"
    "${HAXEON_LIBFFI_SOURCE_DIR}/src/java_raw_api.c"
    "${HAXEON_LIBFFI_SOURCE_DIR}/src/closures.c"
    "${HAXEON_LIBFFI_SOURCE_DIR}/src/tramp.c"
    ${HAXEON_LIBFFI_ARCH_SOURCES})
target_include_directories(haxeon_libffi
    PUBLIC "${HAXEON_LIBFFI_GENERATED_DIR}" "${HAXEON_LIBFFI_SOURCE_DIR}/src/${HAXEON_LIBFFI_ARCH_DIR}"
    PRIVATE "${HAXEON_LIBFFI_SOURCE_DIR}/src" "${HAXEON_LIBFFI_SOURCE_DIR}/include")
target_compile_definitions(haxeon_libffi PRIVATE HAVE_CONFIG_H)
target_compile_options(haxeon_libffi PRIVATE -fexceptions)
target_compile_features(haxeon_libffi PUBLIC c_std_99)

set(HASHLINK_ROOT "${HAXEON_ROOT}/vendor/hashlink")
file(GLOB HASHLINK_PCRE_SOURCES CONFIGURE_DEPENDS "${HASHLINK_ROOT}/include/pcre/*.c")
list(FILTER HASHLINK_PCRE_SOURCES EXCLUDE REGEX "pcre2_jit_(match|misc)\\.c$")
file(GLOB HASHLINK_STD_SOURCES CONFIGURE_DEPENDS "${HASHLINK_ROOT}/src/std/*.c")

# The upstream HashLink CMake file also declares its desktop tools and test
# programs. Android only needs the embeddable runtime, so keep this target
# deliberately small and link it into the app's shared library.
add_library(libhl STATIC
    "${HASHLINK_ROOT}/src/gc.c"
    ${HASHLINK_PCRE_SOURCES}
    ${HASHLINK_STD_SOURCES}
)
target_include_directories(libhl PUBLIC "${HASHLINK_ROOT}/src")
target_include_directories(libhl PRIVATE "${HASHLINK_ROOT}/include/pcre")
target_compile_features(libhl PUBLIC c_std_11)
target_compile_definitions(libhl PRIVATE
    _USRDLL
    LIBHL_EXPORTS
    PCRE2_CODE_UNIT_WIDTH=16
    HAVE_CONFIG_H
)
target_link_libraries(libhl PUBLIC m dl log)
set_target_properties(libhl PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_definitions(libhl PRIVATE
    HL_ANDROID_ACTIVITY=\"org/haxeon/android/MainActivity\"
)

set(HAXEON_VM_SOURCES
    "${HAXEON_ROOT}/vendor/hashlink/src/code.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/hlpatch.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/hlruntime.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/module.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/debugger.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/diagnostics.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/diagnostics_transport.c"
    "${HAXEON_ROOT}/vendor/hashlink/src/profile.c"
)

if(ANDROID_ABI STREQUAL "arm64-v8a")
    if(HL_JIT_AARCH64_OLD)
        set(HAXEON_JIT_SOURCES
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_arm64.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_arm64_compat.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_gdb.c"
        )
    else()
        set(HAXEON_JIT_SOURCES
            "${HAXEON_ROOT}/vendor/hashlink/src/jit.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_emit.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_regs.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_aarch64.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_aarch64_emit.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_dump.c"
            "${HAXEON_ROOT}/vendor/hashlink/src/jit_gdb.c"
        )
    endif()
else()
    set(HAXEON_JIT_SOURCES
        "${HAXEON_ROOT}/vendor/hashlink/src/jit.c"
        "${HAXEON_ROOT}/vendor/hashlink/src/jit_emit.c"
        "${HAXEON_ROOT}/vendor/hashlink/src/jit_regs.c"
        "${HAXEON_ROOT}/vendor/hashlink/src/jit_x86_64.c"
        "${HAXEON_ROOT}/vendor/hashlink/src/jit_dump.c"
        "${HAXEON_ROOT}/vendor/hashlink/src/jit_gdb.c"
    )
endif()

add_library(haxeon SHARED
    haxeon_jni.c
    "${HAXEON_ROOT}/native/runtime.c"
    ${HAXEON_VM_SOURCES}
    ${HAXEON_JIT_SOURCES}
)

target_include_directories(haxeon PRIVATE
    "${HAXEON_ROOT}/vendor/hashlink/src"
    "${HAXEON_ROOT}/native"
)
target_compile_definitions(haxeon PRIVATE HAXEON_ANDROID_HOST=1)
target_link_libraries(haxeon PRIVATE libhl haxeon_libffi android log)
