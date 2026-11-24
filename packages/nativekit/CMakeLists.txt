# The nativekit package: NativeKit, the native core the other packages bind (packages/README.md), built once for all of
# them. In an app's runner it is added to the graph before the packages that depend on it, which then use its targets
# (NativeKit::nativekit, NativeKit::gpu) and nativekit_add_module instead of adding NativeKit themselves
# (docs/design/PROJECT_BUILDS.md, one native graph per app). Built on its own, in the shared native cache for programs that
# are not apps, it leaves the same for their trees in its build directory (below).
cmake_minimum_required(VERSION 3.21)
project(haxeon_nativekit LANGUAGES C CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/NativeKitPackage.cmake")

# The core and the GPU module, which UI uses; the other modules are built by the packages that bind them
# (nativekit_add_module). NativeKit's own tests and examples stay out of an app's build.
set(NK_BUILD_SHARED ON CACHE BOOL "Build NativeKit as a shared library")
set(NK_BUILD_GPU ON CACHE BOOL "Build NativeKit's GPU module, which the UI package uses" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "Build NativeKit tests" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "Build NativeKit examples" FORCE)
add_subdirectory("${NATIVEKIT_SOURCE_DIR}" nativekit)
nativekit_output_to_package(nativekit nativekit_gpu)
# The target the package's manifest names: both libraries it declares (native.cmake.libraries), which `nativekit` alone
# leaves out of a build that is not an app's.
add_custom_target(haxeon_nativekit DEPENDS nativekit nativekit_gpu)

# Haxeon configures the trees of the packages that depend on this one with its build directory in CMAKE_PREFIX_PATH, where
# find_package(NativeKitPackage) gives them NativeKit as this build made it.
if(PROJECT_IS_TOP_LEVEL)
    export(EXPORT NativeKitTargets NAMESPACE NativeKit:: FILE "${CMAKE_BINARY_DIR}/NativeKitTargets.cmake")
    export(EXPORT NativeKitGpuTargets NAMESPACE NativeKit:: FILE "${CMAKE_BINARY_DIR}/NativeKitGpuTargets.cmake")
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/NativeKitPackageConfig.cmake" @ONLY CONTENT [[
# Written by the nativekit package's build: NativeKit as it was built in this directory, for the packages built on it.
set(NK_BUILD_SHARED @NK_BUILD_SHARED@)
set(NK_ENABLE_NO_EXCEPTIONS @NK_ENABLE_NO_EXCEPTIONS@)
include("${CMAKE_CURRENT_LIST_DIR}/NativeKitTargets.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/NativeKitGpuTargets.cmake")
include("@CMAKE_CURRENT_SOURCE_DIR@/cmake/NativeKitPackage.cmake")
]])
endif()
