cmake_minimum_required(VERSION 3.24)

# This is intentionally a narrow Windows x64 build of the pinned libffi
# sources. Upstream's configure script currently provides no native MSVC/CMake
# project, but its x86-64 Windows backend already includes MASM source.
cmake_policy(SET CMP0091 NEW)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" CACHE STRING
  "MSVC runtime used by the Haxeon libffi archive")

project(haxeon_pinned_libffi LANGUAGES C)

if(NOT MSVC)
  message(FATAL_ERROR "This CMake build is only for the MSVC Windows toolchain")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The Haxeon Windows libffi build currently supports x64 only")
endif()

set(LIBFFI_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../vendor/libffi")
set(LIBFFI_GENERATED_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/include")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${LIBFFI_SOURCE_DIR}/configure.ac")
file(MAKE_DIRECTORY "${LIBFFI_GENERATED_INCLUDE_DIR}")

# Keep generated public-header version constants tied to the exact vendored
# libffi release rather than copying the version into this build definition.
file(READ "${LIBFFI_SOURCE_DIR}/configure.ac" libffi_configure_ac)
string(REGEX MATCH "AC_INIT\\(\\[libffi\\],\\[([0-9]+\\.[0-9]+\\.[0-9]+)\\]"
  _libffi_version_match "${libffi_configure_ac}")
if(NOT _libffi_version_match)
  message(FATAL_ERROR "Could not read libffi version from configure.ac")
endif()
set(FFI_VERSION_STRING "${CMAKE_MATCH_1}")
string(REGEX MATCH "^([0-9]+)\\.([0-9]+)\\.([0-9]+)$" _libffi_numeric_version "${FFI_VERSION_STRING}")
math(EXPR FFI_VERSION_NUMBER "${CMAKE_MATCH_1} * 10000 + ${CMAKE_MATCH_2} * 100 + ${CMAKE_MATCH_3}")
set(VERSION "${FFI_VERSION_STRING}")
set(TARGET X86_WIN64)
set(HAVE_LONG_DOUBLE 0)
set(FFI_EXEC_TRAMPOLINE_TABLE 0)
configure_file("${LIBFFI_SOURCE_DIR}/include/ffi.h.in"
  "${LIBFFI_GENERATED_INCLUDE_DIR}/ffi.h" @ONLY)
configure_file("${LIBFFI_SOURCE_DIR}/src/x86/ffitarget.h"
  "${LIBFFI_GENERATED_INCLUDE_DIR}/ffitarget.h" COPYONLY)
configure_file("${CMAKE_CURRENT_LIST_DIR}/fficonfig.h"
  "${LIBFFI_GENERATED_INCLUDE_DIR}/fficonfig.h" COPYONLY)

set(LIBFFI_ASM_SOURCE "${LIBFFI_SOURCE_DIR}/src/x86/win64_intel.S")
set(LIBFFI_ASM_FILE "${CMAKE_CURRENT_BINARY_DIR}/win64_intel.asm")
set(LIBFFI_ASM_OBJECT "${CMAKE_CURRENT_BINARY_DIR}/win64_intel.obj")
find_program(LIBFFI_ML64_EXECUTABLE ml64 REQUIRED)
add_custom_command(
  OUTPUT "${LIBFFI_ASM_OBJECT}"
  COMMAND "${CMAKE_COMMAND}"
    "-DMSVC_C_COMPILER=${CMAKE_C_COMPILER}"
    "-DINPUT_FILE=${LIBFFI_ASM_SOURCE}"
    "-DOUTPUT_FILE=${LIBFFI_ASM_FILE}"
    "-DGENERATED_INCLUDE_DIR=${LIBFFI_GENERATED_INCLUDE_DIR}"
    "-DLIBFFI_SOURCE_DIR=${LIBFFI_SOURCE_DIR}"
    -P "${CMAKE_CURRENT_LIST_DIR}/PreprocessMasm.cmake"
  COMMAND "${LIBFFI_ML64_EXECUTABLE}" /nologo /c "/Fo${LIBFFI_ASM_OBJECT}" "${LIBFFI_ASM_FILE}"
  DEPENDS
    "${LIBFFI_ASM_SOURCE}"
    "${LIBFFI_SOURCE_DIR}/src/x86/asmnames.h"
    "${LIBFFI_SOURCE_DIR}/src/x86/ffitarget.h"
    "${LIBFFI_SOURCE_DIR}/include/ffi_cfi.h"
    "${LIBFFI_SOURCE_DIR}/include/ffi.h.in"
    "${LIBFFI_SOURCE_DIR}/configure.ac"
    "${LIBFFI_GENERATED_INCLUDE_DIR}/ffi.h"
    "${LIBFFI_GENERATED_INCLUDE_DIR}/ffitarget.h"
    "${LIBFFI_GENERATED_INCLUDE_DIR}/fficonfig.h"
    "${CMAKE_CURRENT_LIST_DIR}/fficonfig.h"
    "${CMAKE_CURRENT_LIST_DIR}/PreprocessMasm.cmake"
  VERBATIM
)
set_source_files_properties("${LIBFFI_ASM_OBJECT}" PROPERTIES
  GENERATED TRUE
  EXTERNAL_OBJECT TRUE
)

add_library(ffi STATIC
  "${LIBFFI_SOURCE_DIR}/src/prep_cif.c"
  "${LIBFFI_SOURCE_DIR}/src/types.c"
  "${LIBFFI_SOURCE_DIR}/src/raw_api.c"
  "${LIBFFI_SOURCE_DIR}/src/java_raw_api.c"
  "${LIBFFI_SOURCE_DIR}/src/closures.c"
  "${LIBFFI_SOURCE_DIR}/src/tramp.c"
  "${LIBFFI_SOURCE_DIR}/src/x86/ffiw64.c"
  "${LIBFFI_ASM_OBJECT}"
)
set_target_properties(ffi PROPERTIES OUTPUT_NAME ffi)
target_compile_definitions(ffi PUBLIC FFI_STATIC_BUILD)
target_include_directories(ffi
  PUBLIC
    "$<BUILD_INTERFACE:${LIBFFI_GENERATED_INCLUDE_DIR}>"
  PRIVATE
    "${LIBFFI_SOURCE_DIR}/include"
    "${LIBFFI_SOURCE_DIR}/src"
    "${LIBFFI_SOURCE_DIR}/src/x86"
)

install(TARGETS ffi ARCHIVE DESTINATION lib)
install(FILES
  "${LIBFFI_GENERATED_INCLUDE_DIR}/ffi.h"
  "${LIBFFI_GENERATED_INCLUDE_DIR}/ffitarget.h"
  DESTINATION include
)

enable_testing()
add_executable(libffi-smoke smoke.c)
target_link_libraries(libffi-smoke PRIVATE ffi)
add_test(NAME libffi-smoke COMMAND libffi-smoke)
