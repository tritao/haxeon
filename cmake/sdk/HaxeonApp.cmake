# Building with Haxeon's SDK (docs/design/PROJECT_BUILDS.md, SDK_LAYOUT.md): haxeon_add_app, which an app's runner's
# CMakeLists.txt calls after the generated fragment and find_package(Haxeon), and haxeon_add_c_executable, an executable from
# the C of a program compiled ahead of time, which haxeon_add_app uses for a release build and cmake/aot for any other.
#
#   haxeon_add_app(<target> [MODULE <path.hl>] [NATIVE_TARGETS <target>...])
#
# makes the executable <target>, after every native package the fragment lists (haxeon_add_native_packages), whose shared
# libraries land beside it and are found there at run time ($ORIGIN, @loader_path or the executable's directory). It is
# either the JIT VM started on the app's module (by default the fragment's HAXEON_MODULE), copied beside it as <target>.hl,
# or, when the fragment gives HAXEON_MODULE_C (a release build), the program compiled ahead of time: the C the compiler wrote
# there, built by haxeon_add_c_executable (docs/design/AOT_BACKEND.md).
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

# The flags generated C is compiled with (docs/design/AOT_BACKEND.md, "Debug information" and "Building the C"): wrapping
# arithmetic, no type-based aliasing and no sibling calls, which the stack capture relies on (a jump leaves no frame to restore);
# no cross-jumping where the compiler has the flag, which would merge identical calls of different Haxe lines and lose their
# inlined frames; line tables and inline records for the stack traces (-g1, CodeView in each object with MSVC) but not the
# variables and types a debugger shows; generated functions not exported; the generated code's warnings off.
include(CheckCCompilerFlag)
if(MSVC)
  set(HAXEON_C_MODULE_OPTIONS /Z7 /w)
  if(CMAKE_C_COMPILER_ID STREQUAL "Clang")
    list(APPEND HAXEON_C_MODULE_OPTIONS -gline-tables-only /clang:-fwrapv /clang:-fno-strict-aliasing
      /clang:-fno-optimize-sibling-calls)
  endif()
else()
  set(HAXEON_C_MODULE_OPTIONS -g1 -fwrapv -fno-strict-aliasing -fno-optimize-sibling-calls -fvisibility=hidden -w)
  check_c_compiler_flag(-fno-crossjumping HAXEON_C_HAS_NO_CROSSJUMPING)
  if(HAXEON_C_HAS_NO_CROSSJUMPING)
    list(APPEND HAXEON_C_MODULE_OPTIONS -fno-crossjumping)
  endif()
endif()

#   haxeon_add_c_executable(<target> SOURCES_DIR <dir> [DEVELOPMENT])
#
# makes the executable <target> of a program compiled ahead of time (`--target=hlc`): the C the compiler wrote in <dir>, with
# the SDK's entry point and stack capture, linked against the VM without the JIT. A release build (the default) is optimized
# and lets the C compiler inline generated functions, whose frames the stack capture restores from the debug information; on
# Linux its DWARF is compressed and its symbol table dropped. DEVELOPMENT builds quickly and inlines nothing (-O0,
# HLC_EXACT_FRAMES), so its frames are the JIT's one for one. Configure with no build type or Release: the flags here set the
# optimization.
function(haxeon_add_c_executable target)
  cmake_parse_arguments(PARSE_ARGV 1 C "DEVELOPMENT" "SOURCES_DIR" "")
  if(NOT C_SOURCES_DIR)
    message(FATAL_ERROR "haxeon_add_c_executable(${target}) needs SOURCES_DIR, the directory --target=hlc wrote")
  endif()
  file(GLOB _sources CONFIGURE_DEPENDS "${C_SOURCES_DIR}/*.c")
  if(NOT _sources)
    message(FATAL_ERROR "haxeon_add_c_executable(${target}): no C sources in ${C_SOURCES_DIR}; --target=hlc writes them")
  endif()
  add_executable(${target} ${_sources} "${HAXEON_SDK_DIR}/src/hlc_main.c" "${HAXEON_SDK_DIR}/src/hlc_stack.c")
  target_include_directories(${target} PRIVATE "${C_SOURCES_DIR}")
  target_compile_options(${target} PRIVATE ${HAXEON_C_MODULE_OPTIONS})
  if(C_DEVELOPMENT)
    target_compile_definitions(${target} PRIVATE HLC_EXACT_FRAMES)
  endif()
  if(MSVC)
    target_compile_options(${target} PRIVATE $<IF:$<BOOL:${C_DEVELOPMENT}>,/Od,/O2>)
  else()
    target_compile_options(${target} PRIVATE $<IF:$<BOOL:${C_DEVELOPMENT}>,-O0,-O2>)
  endif()
  # The DLL C runtime, as the SDK's libraries are built with.
  set_target_properties(${target} PROPERTIES C_STANDARD 11 C_EXTENSIONS ON MSVC_RUNTIME_LIBRARY MultiThreadedDLL
    ENABLE_EXPORTS ON)
  # libhl is linked statically: its functions are referenced directly, not through a DLL's import table.
  if(WIN32)
    target_compile_definitions(${target} PRIVATE HL_IMPORT=extern)
  endif()
  # The whole VM: the loader resolves natives by name (hlp_*) in the executable, so nothing of it may be dropped.
  target_link_libraries(${target} PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,Haxeon::aot>" Haxeon::ffi
    ${HAXEON_APP_SYSTEM_LIBRARIES})
  # The entry point is wmain, as the runtime's arguments are UTF-16 there, and the main thread gets the 8 MB stack the other
  # platforms give it. With MSVC the link writes the PDB the stack traces read in both modes; identical functions are not
  # folded and the link is not incremental, so each generated function keeps an address of its own, with no jump thunk.
  if(MSVC)
    target_link_options(${target} PRIVATE /DEBUG /INCREMENTAL:NO /OPT:REF /OPT:NOICF /STACK:8388608)
  elseif(WIN32)
    target_link_options(${target} PRIVATE -municode -Wl,--stack,8388608)
  elseif(APPLE)
    target_link_options(${target} PRIVATE -Wl,-export_dynamic)
  elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND NOT C_DEVELOPMENT)
    # The DWARF compressed with zlib, which the stack traces inflate and gdb, perf and addr2line read as it is; then the
    # symbol table and .debug_aranges dropped, as the traces name frames from the module image and read only the line
    # tables and inline records. The dynamic symbols the loader resolves natives by stay.
    target_link_options(${target} PRIVATE -Wl,--compress-debug-sections=zlib)
    set(_objcopy "${CMAKE_OBJCOPY}")
    if(NOT _objcopy)
      set(_objcopy objcopy)
    endif()
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND "${_objcopy}" --strip-all "--keep-section=!.debug_aranges" "--keep-section=.debug_*" "$<TARGET_FILE:${target}>"
      VERBATIM)
  endif()
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
    if(MSVC)
      target_link_options(${target} PRIVATE /STACK:8388608)
    elseif(WIN32)
      target_link_options(${target} PRIVATE -Wl,--stack,8388608)
    endif()
  else()
    haxeon_add_c_executable(${target} SOURCES_DIR "${HAXEON_MODULE_C}")
  endif()
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")
  # Native libraries a module loads resolve the VM's API from the executable.
  set_target_properties(${target} PROPERTIES ENABLE_EXPORTS ON C_STANDARD 11)
  if(APPLE)
    set_target_properties(${target} PROPERTIES BUILD_RPATH "@loader_path" INSTALL_RPATH "@loader_path")
  elseif(UNIX)
    set_target_properties(${target} PROPERTIES BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
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
