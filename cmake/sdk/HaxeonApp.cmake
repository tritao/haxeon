# Building an app's runner with Haxeon's SDK (docs/design/PROJECT_BUILDS.md, SDK_LAYOUT.md): haxeon_add_app, which the
# runner's CMakeLists.txt calls after the generated fragment and find_package(Haxeon).
#
#   haxeon_add_app(<target> MODULE <path.hl> [NATIVE_TARGETS <target>...])
#
# makes the executable <target>: the VM started on the app's module, copied beside it as <target>.hl. The fragment sets the
# output directories so the native packages' shared libraries land beside it too, found there at run time ($ORIGIN,
# @loader_path or the executable's directory).

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
    message(FATAL_ERROR "haxeon_add_app(${target}) needs MODULE, the app's compiled module")
  endif()
  add_executable(${target} "${HAXEON_SDK_DIR}/src/haxeon_app.c")
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
