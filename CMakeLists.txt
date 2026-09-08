cmake_minimum_required(VERSION 3.24)

project(haxeon_native LANGUAGES C CXX)

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
add_subdirectory(vendor/hashlink hashlink EXCLUDE_FROM_ALL)

add_library(realtime_runtime SHARED native/runtime.c)
target_include_directories(realtime_runtime PRIVATE vendor/hashlink/src)
target_link_libraries(realtime_runtime PRIVATE libhl)
set_target_properties(realtime_runtime PROPERTIES
  PREFIX ""
  SUFFIX ".hdll"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/out"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/out"
)

set_target_properties(hl libhl PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
)

# Haxeon's HDLL calls the patching API compiled into the VM executable. This is
# the portable CMake equivalent of HashLink's Makefile --export-dynamic flag and
# also produces the import information required by Windows executable exports.
set_target_properties(hl PROPERTIES ENABLE_EXPORTS ON)

if(UNIX)
  set_target_properties(realtime_runtime PROPERTIES
    BUILD_RPATH "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  )
endif()

add_custom_target(haxeon-native DEPENDS hl realtime_runtime)
