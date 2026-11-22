# Haxeon's SDK as a CMake package (docs/design/SDK_LAYOUT.md): find_package(Haxeon) gives an app's runner the VM libraries of
# the platform it builds for and haxeon_add_app (HaxeonApp.cmake).
#
#   Haxeon::app   the JIT VM with the app entry point (lib/<target>/libhaxeon-app)
#   Haxeon::vm    the JIT VM alone (lib/<target>/libhl)
#   Haxeon::aot   the VM without the JIT, for code compiled ahead of time (lib/<target>/libhl-aot)
#   Haxeon::ffi   the pinned libffi the VMs call natives through
#
# Libraries are per target (`lib/linux-x86_64-gnu/`, `lib/windows-x86_64-msvc/`, ...), named as `build.Target` spells them.

cmake_minimum_required(VERSION 3.24)

get_filename_component(HAXEON_SDK_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _haxeon_arch)
if(_haxeon_arch MATCHES "^(amd64|x86_64|x64)$")
  set(_haxeon_arch x86_64)
elseif(_haxeon_arch MATCHES "^(aarch64|arm64)$")
  set(_haxeon_arch arm64)
endif()
if(WIN32)
  if(MSVC)
    set(HAXEON_TARGET "windows-${_haxeon_arch}-msvc")
  else()
    set(HAXEON_TARGET "windows-${_haxeon_arch}-gnu")
  endif()
elseif(APPLE)
  set(HAXEON_TARGET "macos-${_haxeon_arch}")
else()
  set(HAXEON_TARGET "linux-${_haxeon_arch}-gnu")
endif()
set(HAXEON_LIBRARY_DIR "${HAXEON_SDK_DIR}/lib/${HAXEON_TARGET}")

if(NOT EXISTS "${HAXEON_LIBRARY_DIR}")
  set(Haxeon_FOUND FALSE)
  set(Haxeon_NOT_FOUND_MESSAGE "This Haxeon SDK (${HAXEON_SDK_DIR}) has no libraries for ${HAXEON_TARGET}")
  return()
endif()

if(NOT TARGET Haxeon::app)
  foreach(_library IN ITEMS app:haxeon-app vm:hl aot:hl-aot ffi:ffi)
    string(REPLACE ":" ";" _parts "${_library}")
    list(GET _parts 0 _name)
    list(GET _parts 1 _file)
    add_library(Haxeon::${_name} STATIC IMPORTED)
    set_target_properties(Haxeon::${_name} PROPERTIES
      IMPORTED_LOCATION "${HAXEON_LIBRARY_DIR}/${CMAKE_STATIC_LIBRARY_PREFIX}${_file}${CMAKE_STATIC_LIBRARY_SUFFIX}"
      INTERFACE_INCLUDE_DIRECTORIES "${HAXEON_SDK_DIR}/include")
  endforeach()
endif()

include("${CMAKE_CURRENT_LIST_DIR}/HaxeonApp.cmake")
