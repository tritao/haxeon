# Building an app's runner with Haxeon's SDK (docs/design/PROJECT_BUILDS.md, SDK_LAYOUT.md): haxeon_add_app, which the
# runner's CMakeLists.txt calls after the generated fragment and find_package(Haxeon).
#
#   haxeon_add_app(<target> [MODULE <path.hl>] [NATIVE_TARGETS <target>...])
#
# makes the executable <target>: the VM started on the app's module (by default the fragment's HAXEON_MODULE), copied beside
# it as <target>.hl, after every native package the fragment lists (haxeon_add_native_packages), whose shared libraries land
# beside it too and are found there at run time ($ORIGIN, @loader_path or the executable's directory).
#
# The fragment is data: HAXEON_MODULE, HAXEON_APP_NAME/ID/VERSION, and per package in HAXEON_PACKAGES (dependencies first)
# HAXEON_PACKAGE_<name>_SOURCE, _TARGET and _DEFINITIONS (NAME=VALUE cache settings from its native.cmake.definitions).

# Adds each native package the fragment lists to this graph, dependencies first, with its definitions, and sets
# HAXEON_NATIVE_TARGETS in the caller to their targets. Packages' own tests stay out of an app's build.
function(haxeon_add_native_packages)
  set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
  set(_targets)
  foreach(_package IN LISTS HAXEON_PACKAGES)
    foreach(_definition IN LISTS HAXEON_PACKAGE_${_package}_DEFINITIONS)
      string(FIND "${_definition}" "=" _equals)
      string(SUBSTRING "${_definition}" 0 ${_equals} _name)
      math(EXPR _value_start "${_equals} + 1")
      string(SUBSTRING "${_definition}" ${_value_start} -1 _value)
      set(${_name} "${_value}" CACHE STRING "" FORCE)
    endforeach()
    add_subdirectory("${HAXEON_PACKAGE_${_package}_SOURCE}" "${CMAKE_BINARY_DIR}/packages/${_package}")
    list(APPEND _targets ${HAXEON_PACKAGE_${_package}_TARGET})
  endforeach()
  set(HAXEON_NATIVE_TARGETS ${_targets} PARENT_SCOPE)
endfunction()

# The libraries come from HaxeonConfig.cmake (find_package(Haxeon)), which includes this file.
if(NOT TARGET Haxeon::app)
  message(FATAL_ERROR "HaxeonApp.cmake is part of the Haxeon package: use find_package(Haxeon)")
endif()
if(WIN32)
  set(HAXEON_APP_SYSTEM_LIBRARIES advapi32 bcrypt ws2_32 user32 winmm dbghelp dxguid)
else()
  set(HAXEON_APP_SYSTEM_LIBRARIES ${CMAKE_DL_LIBS} m pthread)
endif()

function(haxeon_add_app target)
  cmake_parse_arguments(PARSE_ARGV 1 APP "" "MODULE" "NATIVE_TARGETS")
  if(NOT APP_MODULE)
    set(APP_MODULE "${HAXEON_MODULE}")
  endif()
  if(NOT APP_MODULE)
    message(FATAL_ERROR "haxeon_add_app(${target}) has no module: include the fragment haxeon build generates, or pass MODULE")
  endif()
  if(NOT DEFINED APP_NATIVE_TARGETS AND NOT "NATIVE_TARGETS" IN_LIST APP_KEYWORDS_MISSING_VALUES)
    haxeon_add_native_packages()
    set(APP_NATIVE_TARGETS ${HAXEON_NATIVE_TARGETS})
  endif()
  add_executable(${target} "${HAXEON_SDK_DIR}/src/haxeon_app.c")
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
  # The whole VM: the module's natives are found by name in the executable, so nothing of it may be dropped.
  target_link_libraries(${target} PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,Haxeon::app>" Haxeon::ffi
    ${HAXEON_APP_SYSTEM_LIBRARIES})
  # Native libraries a module loads resolve the VM's API from the executable.
  set_target_properties(${target} PROPERTIES ENABLE_EXPORTS ON C_STANDARD 11)
  if(APPLE)
    set_target_properties(${target} PROPERTIES BUILD_RPATH "@loader_path" INSTALL_RPATH "@loader_path")
  elseif(UNIX)
    set_target_properties(${target} PROPERTIES BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
  endif()
  if(MSVC)
    target_link_options(${target} PRIVATE /STACK:8388608)
  elseif(WIN32)
    target_link_options(${target} PRIVATE -Wl,--stack,8388608)
  endif()
  # The module beside the executable, under its name, whenever the module changes.
  set(_module_copy "$<TARGET_FILE_DIR:${target}>/$<TARGET_FILE_BASE_NAME:${target}>.hl")
  add_custom_target(${target}-module ALL
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${APP_MODULE}" "${_module_copy}"
    DEPENDS "${APP_MODULE}" ${target}
    COMMENT "Copying the app's module beside ${target}"
    VERBATIM)
  # The native packages build before the app; the fragment sends their libraries to the app's directory.
  foreach(_native IN LISTS APP_NATIVE_TARGETS)
    if(NOT TARGET ${_native})
      message(FATAL_ERROR "haxeon_add_app(${target}): no native target ${_native}")
    endif()
    add_dependencies(${target} ${_native})
  endforeach()
endfunction()
