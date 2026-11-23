# The nativekit package: NativeKit, the native core the other packages bind (packages/README.md). In an app's runner it is
# added to the graph before the packages that depend on it, which then use its targets (NativeKit::nativekit, NativeKit::gpu)
# instead of adding NativeKit themselves (docs/design/PROJECT_BUILDS.md, one native graph per app).
cmake_minimum_required(VERSION 3.21)
project(haxeon_nativekit LANGUAGES C CXX)

# NativeKit's sources: copied into the package when it is published (its manifest's publish.vendor), the repository's
# submodule in a checkout.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/nativekit/CMakeLists.txt")
    set(HAXEON_NATIVEKIT_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/nativekit")
else()
    set(HAXEON_NATIVEKIT_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/nativekit")
endif()

# The modules the first-party packages use; NativeKit's own tests and examples stay out of an app's build.
set(NK_BUILD_SHARED ON CACHE BOOL "Build NativeKit as a shared library")
set(NK_BUILD_GPU ON CACHE BOOL "Build NativeKit's GPU module, which the UI package uses" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "Build NativeKit tests" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "Build NativeKit examples" FORCE)
add_subdirectory("${HAXEON_NATIVEKIT_SOURCE}" nativekit)
