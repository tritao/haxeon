cmake_minimum_required(VERSION 3.24)
project(haxeon_android LANGUAGES C)

set(HAXEON_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../..")
get_filename_component(HAXEON_ROOT "${HAXEON_ROOT}" ABSOLUTE)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build HashLink as a static library for the Android host" FORCE)
set(WITH_VM OFF CACHE BOOL "The Android host supplies the VM executable sources" FORCE)
set(HL_BUILD_TESTS OFF CACHE BOOL "Do not build HashLink tests for Android" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "Do not build HashLink tests for Android" FORCE)
option(HL_JIT_AARCH64_OLD
    "Use the legacy direct HL-bytecode AArch64 JIT instead of the HL2 IR backend"
    OFF)

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
target_link_libraries(haxeon PRIVATE libhl android log)
