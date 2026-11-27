# What the nativekit package gives the packages that build on NativeKit, the same in an app's graph (the package's
# CMakeLists.txt includes this file) and in the shared native cache (its build's NativeKitPackageConfig.cmake does):
# NATIVEKIT_SOURCE_DIR, NATIVEKIT_VERSION and nativekit_add_module(<module>).
include_guard(GLOBAL)

# NativeKit's sources: copied into the package when it is published (its manifest's publish.vendor), the repository's
# submodule in a checkout. Cache entries, so the other packages of an app's graph see them too.
get_filename_component(_nativekit_package_dir "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(EXISTS "${_nativekit_package_dir}/nativekit/CMakeLists.txt")
    set(NATIVEKIT_SOURCE_DIR "${_nativekit_package_dir}/nativekit" CACHE INTERNAL "NativeKit's sources")
else()
    get_filename_component(NATIVEKIT_SOURCE_DIR "${_nativekit_package_dir}/../../vendor/nativekit" ABSOLUTE)
    set(NATIVEKIT_SOURCE_DIR "${NATIVEKIT_SOURCE_DIR}" CACHE INTERNAL "NativeKit's sources")
endif()
file(STRINGS "${NATIVEKIT_SOURCE_DIR}/CMakeLists.txt" _nativekit_project REGEX "^project[(]nativekit VERSION ")
string(REGEX REPLACE "^project[(]nativekit VERSION ([0-9.]+).*" "\\1" _nativekit_version "${_nativekit_project}")
if(NOT _nativekit_version MATCHES "^[0-9]+[.][0-9]+")
    message(FATAL_ERROR "Could not read the NativeKit version from ${NATIVEKIT_SOURCE_DIR}/CMakeLists.txt")
endif()
set(NATIVEKIT_VERSION "${_nativekit_version}" CACHE INTERNAL "NativeKit's version")

#   nativekit_add_module(<module>)
#
# Adds NativeKit's module (audio, credentials) to the calling package's project as the library
# nativekit_<module>, built on this package's NativeKit. Only the module's directory is added, with what NativeKit's own
# CMakeLists.txt sets for its modules, so NativeKit is neither configured nor built again for it.
function(nativekit_add_module module)
    if(APPLE)
        enable_language(OBJCXX)
    endif()
    include(GNUInstallDirs)
    set(NK_BUILD_TESTS OFF)
    set(NK_BUILD_EXAMPLES OFF)
    set(NK_LIBRARY_TYPE STATIC)
    if(NK_BUILD_SHARED AND NOT EMSCRIPTEN)
        set(NK_LIBRARY_TYPE SHARED)
    endif()
    set(NK_VENDOR_DIR "${NATIVEKIT_SOURCE_DIR}/vendor")
    # A module reads NativeKit's headers and version through its project's variables.
    set(PROJECT_SOURCE_DIR "${NATIVEKIT_SOURCE_DIR}")
    set(PROJECT_VERSION "${NATIVEKIT_VERSION}")
    # NativeKit's, when it is in this graph; a module's own tree is never installed.
    if(NOT COMMAND nk_install_component)
        function(nk_install_component name)
        endfunction()
    endif()
    add_subdirectory("${NATIVEKIT_SOURCE_DIR}/modules/${module}" "nativekit-${module}")
    nativekit_output_to_package("nativekit_${module}")
endfunction()

# Sends the libraries to where Haxeon loads the package's from (HAXEON_NATIVE_OUTPUT_DIR), over the runtime directory
# NativeKit sets for itself on Windows. In an app's graph, which names its libraries' directory in
# CMAKE_RUNTIME_OUTPUT_DIRECTORY (haxeon_add_native_packages), the Windows DLLs go there, beside the executable.
function(nativekit_output_to_package)
    if(DEFINED HAXEON_NATIVE_OUTPUT_DIR)
        set_target_properties(${ARGN} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
            RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
            ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
    elseif(WIN32 AND CMAKE_RUNTIME_OUTPUT_DIRECTORY)
        set_target_properties(${ARGN} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
    endif()
endfunction()
