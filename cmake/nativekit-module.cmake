# Builds one NativeKit module (credentials, filesystem) on its own, for a Haxeon package's native CMake project:
#
#   cmake_minimum_required(VERSION 3.21)
#   include("${CMAKE_CURRENT_SOURCE_DIR}/../../../cmake/nativekit-module.cmake")
#   project(haxeon_nativekit_credentials VERSION ${NK_VERSION} LANGUAGES C CXX)
#   haxeon_nativekit_module(credentials)
#
# The modules need NativeKit's options, version and include directory, not NativeKit itself. Adding all of NativeKit
# configured libwebsockets (some 65 compiler checks) and downloaded WebView2 for a build of one or two files, so only the
# module's directory is added, with what NativeKit's own CMakeLists would have set for it.

include_guard(GLOBAL)

set(NK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../vendor/nativekit")
file(STRINGS "${NK_ROOT}/CMakeLists.txt" NK_PROJECT_LINE REGEX "^project[(]nativekit VERSION ")
string(REGEX REPLACE "^project[(]nativekit VERSION ([0-9.]+).*" "\\1" NK_VERSION "${NK_PROJECT_LINE}")
if(NOT NK_VERSION MATCHES "^[0-9]+[.][0-9]+")
    message(FATAL_ERROR "Could not read the NativeKit version from ${NK_ROOT}/CMakeLists.txt")
endif()

# A macro, so that the variables it sets are those of the package's directory, which the module's directory inherits.
macro(haxeon_nativekit_module module)
    if(APPLE)
        enable_language(OBJCXX)
    endif()
    if(DEFINED HAXEON_NATIVE_OUTPUT_DIR)
        set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
    endif()
    if(DEFINED HAXEON_TARGET)
        message(STATUS "Building NativeKit ${module} for ${HAXEON_TARGET}")
    endif()

    include(GNUInstallDirs)
    option(NK_BUILD_SHARED "Build NativeKit as a shared library" ON)
    option(NK_ENABLE_NO_EXCEPTIONS "Compile NativeKit production targets without C++ exception support" ON)
    set(NK_BUILD_TESTS OFF)
    set(NK_LIBRARY_TYPE STATIC)
    if(NK_BUILD_SHARED AND NOT EMSCRIPTEN)
        set(NK_LIBRARY_TYPE SHARED)
    endif()
    add_subdirectory("${NK_ROOT}/modules/${module}" ${module})
    target_include_directories(nativekit_${module} PUBLIC "${NK_ROOT}/include")
endmacro()
