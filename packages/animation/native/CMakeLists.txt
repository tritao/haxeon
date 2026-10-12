cmake_minimum_required(VERSION 3.24)
project(animkit_core VERSION 0.1.0 LANGUAGES C CXX)

include(CTest)
if(NOT DEFINED RK_BUILD_SHARED)
    set(RK_BUILD_SHARED ON)
endif()
option(AK_BUILD_SHARED "Build AnimKit as a shared library" ${RK_BUILD_SHARED})

foreach(AK_SUBMODULE cgltf/cgltf.h stb/stb_image.h ozz-animation/CMakeLists.txt)
    if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/${AK_SUBMODULE}")
        message(FATAL_ERROR "Initialize the animkit/native/vendor submodules (missing ${AK_SUBMODULE})")
    endif()
endforeach()

# Only ozz's runtime, offline builder, and geometry libraries are linked. Its
# own glTF/FBX importers, tools, samples, and tests are disabled.
set(AK_OWN_BUILD_TESTING ${BUILD_TESTING})
set(BUILD_SHARED_LIBS OFF)
set(ozz_build_tools OFF CACHE BOOL "" FORCE)
set(ozz_build_fbx OFF CACHE BOOL "" FORCE)
set(ozz_build_gltf OFF CACHE BOOL "" FORCE)
set(ozz_build_data OFF CACHE BOOL "" FORCE)
set(ozz_build_samples OFF CACHE BOOL "" FORCE)
set(ozz_build_howtos OFF CACHE BOOL "" FORCE)
set(ozz_build_tests OFF CACHE BOOL "" FORCE)
set(ozz_build_postfix OFF CACHE BOOL "" FORCE)
add_subdirectory(vendor/ozz-animation EXCLUDE_FROM_ALL)
set(BUILD_TESTING ${AK_OWN_BUILD_TESTING})
foreach(AK_OZZ_TARGET ozz_base ozz_animation ozz_animation_offline ozz_geometry)
    set_target_properties(${AK_OZZ_TARGET} PROPERTIES POSITION_INDEPENDENT_CODE ON)
endforeach()

if(AK_BUILD_SHARED)
    set(AK_LIBRARY_TYPE SHARED)
else()
    set(AK_LIBRARY_TYPE STATIC)
endif()

add_library(animkit_core ${AK_LIBRARY_TYPE} src/api.cpp src/import.cpp src/runtime.cpp src/vendor.cpp)
target_compile_features(animkit_core PUBLIC cxx_std_17)
target_link_libraries(animkit_core PRIVATE ozz_animation_offline ozz_animation ozz_geometry ozz_base)
target_include_directories(animkit_core PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
target_include_directories(animkit_core SYSTEM PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cgltf
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/stb)
target_compile_definitions(animkit_core PRIVATE AK_BUILDING_LIBRARY)
if(NOT AK_BUILD_SHARED)
    target_compile_definitions(animkit_core PUBLIC AK_STATIC)
endif()
set_target_properties(animkit_core PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    VERSION ${PROJECT_VERSION}
    SOVERSION 0)

if(HAXEON_NATIVE_OUTPUT_DIR)
    set_target_properties(animkit_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
        ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
endif()

if(BUILD_TESTING)
    add_executable(animkit_gltf_tests tests/gltf.cpp)
    target_link_libraries(animkit_gltf_tests PRIVATE animkit_core)
    add_test(NAME animkit_gltf COMMAND animkit_gltf_tests)
    set_tests_properties(animkit_gltf PROPERTIES LABELS animkit)
endif()
