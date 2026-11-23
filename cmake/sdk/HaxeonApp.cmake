# Building an app's runner with Haxeon's SDK (docs/design/PROJECT_BUILDS.md, SDK_LAYOUT.md): haxeon_add_app, which the
# runner's CMakeLists.txt calls after the generated fragment and find_package(Haxeon).
#
#   haxeon_add_app(<target> [MODULE <path.hl>] [NATIVE_TARGETS <target>...])
#
# makes the executable <target>, after every native package the fragment lists (haxeon_add_native_packages), whose shared
# libraries land beside it and are found there at run time ($ORIGIN, @loader_path or the executable's directory). It is
# either the JIT VM started on the app's module (by default the fragment's HAXEON_MODULE), copied beside it as <target>.hl,
# or, when the fragment gives HAXEON_MODULE_C (a release build), the program compiled ahead of time: the C the compiler wrote
# there, with the SDK's entry point, linked against the VM without the JIT (docs/design/AOT_BACKEND.md).
#
# The fragment is data: HAXEON_MODULE or HAXEON_MODULE_C, HAXEON_APP_NAME/ID/VERSION, and per package in HAXEON_PACKAGES (dependencies first)
# HAXEON_PACKAGE_<name>_SOURCE and _TARGET.

# Adds each native package the fragment lists to this graph, dependencies first, and sets
# HAXEON_NATIVE_TARGETS in the caller to their targets. Packages' own tests stay out of an app's build.
function(haxeon_add_native_packages)
  set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
  set(_targets)
  foreach(_package IN LISTS HAXEON_PACKAGES)
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

# The flags generated C is compiled with, as HlcBuild's gnuFlags and msvcFlags give a release build (docs/design/AOT_BACKEND.md):
# wrapping arithmetic, no type-based aliasing and no sibling calls, which the stack capture relies on; line tables for the
# stack traces; the generated code's warnings off.
include(CheckCCompilerFlag)
if(MSVC)
  set(HAXEON_C_MODULE_OPTIONS /O2 /Z7 /w)
  if(CMAKE_C_COMPILER_ID STREQUAL "Clang")
    list(APPEND HAXEON_C_MODULE_OPTIONS -gline-tables-only /clang:-fwrapv /clang:-fno-strict-aliasing
      /clang:-fno-optimize-sibling-calls)
  endif()
else()
  set(HAXEON_C_MODULE_OPTIONS -O2 -g1 -fwrapv -fno-strict-aliasing -fno-optimize-sibling-calls -fvisibility=hidden -w)
  check_c_compiler_flag(-fno-crossjumping HAXEON_C_HAS_NO_CROSSJUMPING)
  if(HAXEON_C_HAS_NO_CROSSJUMPING)
    list(APPEND HAXEON_C_MODULE_OPTIONS -fno-crossjumping)
  endif()
endif()

# The executable of a program compiled ahead of time: the C in `directory`, with the SDK's main and stack capture.
function(_haxeon_add_c_executable target directory)
  file(GLOB _sources CONFIGURE_DEPENDS "${directory}/*.c")
  if(NOT _sources)
    message(FATAL_ERROR "haxeon_add_app(${target}): no C sources in ${directory}; haxeon build --build-mode=release writes them")
  endif()
  add_executable(${target} ${_sources} "${HAXEON_SDK_DIR}/src/hlc_main.c" "${HAXEON_SDK_DIR}/src/hlc_stack.c")
  target_include_directories(${target} PRIVATE "${directory}")
  target_compile_options(${target} PRIVATE ${HAXEON_C_MODULE_OPTIONS})
  set_target_properties(${target} PROPERTIES C_STANDARD 11 C_EXTENSIONS ON)
  # libhl is linked statically: its functions are referenced directly, not through a DLL's import table.
  if(WIN32)
    target_compile_definitions(${target} PRIVATE HL_IMPORT=extern)
  endif()
  if(MINGW)
    target_link_options(${target} PRIVATE -municode)
  endif()
  target_link_libraries(${target} PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,Haxeon::aot>" Haxeon::ffi
    ${HAXEON_APP_SYSTEM_LIBRARIES})
endfunction()

function(haxeon_add_app target)
  cmake_parse_arguments(PARSE_ARGV 1 APP "" "MODULE" "NATIVE_TARGETS")
  if(NOT APP_MODULE)
    set(APP_MODULE "${HAXEON_MODULE}")
  endif()
  if(NOT APP_MODULE AND NOT HAXEON_MODULE_C)
    message(FATAL_ERROR "haxeon_add_app(${target}) has no module: include the fragment haxeon build generates, or pass MODULE")
  endif()
  if(NOT DEFINED APP_NATIVE_TARGETS AND NOT "NATIVE_TARGETS" IN_LIST APP_KEYWORDS_MISSING_VALUES)
    haxeon_add_native_packages()
    set(APP_NATIVE_TARGETS ${HAXEON_NATIVE_TARGETS})
  endif()
  if(APP_MODULE)
    add_executable(${target} "${HAXEON_SDK_DIR}/src/haxeon_app.c")
    # The whole VM: the module's natives are found by name in the executable, so nothing of it may be dropped.
    target_link_libraries(${target} PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,Haxeon::app>" Haxeon::ffi
      ${HAXEON_APP_SYSTEM_LIBRARIES})
  else()
    _haxeon_add_c_executable(${target} "${HAXEON_MODULE_C}")
  endif()
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
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
  # The module beside the executable, under its name, whenever the module changes; a program compiled ahead of time is in it.
  set(_module_copy "$<TARGET_FILE_DIR:${target}>/$<TARGET_FILE_BASE_NAME:${target}>.hl")
  if(APP_MODULE)
    add_custom_target(${target}-module ALL
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${APP_MODULE}" "${_module_copy}"
      DEPENDS "${APP_MODULE}" ${target}
      COMMENT "Copying the app's module beside ${target}"
      VERBATIM)
  else()
    add_custom_command(TARGET ${target} POST_BUILD COMMAND "${CMAKE_COMMAND}" -E rm -f "${_module_copy}" VERBATIM)
  endif()
  # The native packages build before the app; the fragment sends their libraries to the app's directory.
  foreach(_native IN LISTS APP_NATIVE_TARGETS)
    if(NOT TARGET ${_native})
      message(FATAL_ERROR "haxeon_add_app(${target}): no native target ${_native}")
    endif()
    add_dependencies(${target} ${_native})
  endforeach()
endfunction()
