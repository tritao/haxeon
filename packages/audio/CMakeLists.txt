cmake_minimum_required(VERSION 3.21)
project(haxeon_audio LANGUAGES C CXX)
set(NATIVEKIT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/nativekit" CACHE PATH "NativeKit source directory")
set(NK_BUILD_SHARED ON CACHE BOOL "Build the audio runtime as a shared library" FORCE)
set(NK_BUILD_AUDIO ON CACHE BOOL "Enable audio" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "Build native tests")
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "Build native examples")
add_subdirectory("${NATIVEKIT_DIR}" nativekit)
if(HAXEON_NATIVE_OUTPUT_DIR)
    set_target_properties(nativekit PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
        ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
endif()
