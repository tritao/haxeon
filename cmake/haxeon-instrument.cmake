# Natively instrumented builds (MSVC x64). Haxeon passes this file as CMAKE_PROJECT_INCLUDE when it configures a
# package's CMake project for the instrumented build flavor, with:
#
#   HAXEON_INSTRUMENT_HOOKS    the hook library (hlprof_penter.lib) that defines _penter and _pexit
#   HAXEON_INSTRUMENT_INCLUDE  glob patterns of the sources to instrument
#   HAXEON_INSTRUMENT_EXCLUDE  glob patterns of the sources to leave alone
#
# A pattern matches a source's path relative to the top CMake source directory, or its absolute path, with forward
# slashes: `*` matches within one path component, `**` across components and `?` one character. Matching sources are
# compiled with /Gh /GH. Every module gets a PDB, so the profiler can name its functions, and links the hooks.

include_guard(GLOBAL)

if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  return()
endif()

add_compile_options($<$<COMPILE_LANGUAGE:C,CXX>:/Z7>)
add_link_options(/DEBUG /OPT:REF /OPT:ICF /INCREMENTAL:NO "${HAXEON_INSTRUMENT_HOOKS}")

function(_haxeon_instrument_regex pattern out)
  string(REGEX REPLACE [=[([][.+^$(){}|\\])]=] [[\\\1]] regex "${pattern}")
  string(REPLACE "**/" "<haxeon-dirs>" regex "${regex}")
  string(REPLACE "**" "<haxeon-any>" regex "${regex}")
  string(REPLACE "*" "[^/]*" regex "${regex}")
  string(REPLACE "?" "[^/]" regex "${regex}")
  string(REPLACE "<haxeon-dirs>" "(.*/)?" regex "${regex}")
  string(REPLACE "<haxeon-any>" ".*" regex "${regex}")
  set(${out} "^${regex}$" PARENT_SCOPE)
endfunction()

function(_haxeon_instrument_matches path patterns out)
  file(RELATIVE_PATH relative "${CMAKE_SOURCE_DIR}" "${path}")
  foreach(pattern IN LISTS patterns)
    _haxeon_instrument_regex("${pattern}" regex)
    if(relative MATCHES "${regex}" OR path MATCHES "${regex}")
      set(${out} TRUE PARENT_SCOPE)
      return()
    endif()
  endforeach()
  set(${out} FALSE PARENT_SCOPE)
endfunction()

function(_haxeon_instrument_directory directory)
  get_property(targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(target IN LISTS targets)
    get_target_property(type ${target} TYPE)
    get_target_property(imported ${target} IMPORTED)
    if(imported OR NOT type MATCHES "^(STATIC_LIBRARY|SHARED_LIBRARY|MODULE_LIBRARY|OBJECT_LIBRARY|EXECUTABLE)$")
      continue()
    endif()
    if(NOT type MATCHES "^(STATIC_LIBRARY|OBJECT_LIBRARY)$")
      set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${HAXEON_INSTRUMENT_HOOKS}")
    endif()
    get_target_property(sources ${target} SOURCES)
    get_target_property(source_directory ${target} SOURCE_DIR)
    foreach(source IN LISTS sources)
      if(source MATCHES "\\$<" OR NOT source MATCHES "\\.(c|cc|cpp|cxx|c\\+\\+)$")
        continue()
      endif()
      get_filename_component(path "${source}" ABSOLUTE BASE_DIR "${source_directory}")
      _haxeon_instrument_matches("${path}" "${HAXEON_INSTRUMENT_INCLUDE}" included)
      if(NOT included)
        continue()
      endif()
      _haxeon_instrument_matches("${path}" "${HAXEON_INSTRUMENT_EXCLUDE}" excluded)
      if(NOT excluded)
        set_property(SOURCE "${path}" TARGET_DIRECTORY ${target} APPEND PROPERTY COMPILE_OPTIONS /Gh /GH)
      endif()
    endforeach()
  endforeach()
  get_property(subdirectories DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
  foreach(subdirectory IN LISTS subdirectories)
    _haxeon_instrument_directory("${subdirectory}")
  endforeach()
endfunction()

function(_haxeon_instrument_sources)
  _haxeon_instrument_directory("${CMAKE_SOURCE_DIR}")
endfunction()

# Targets exist only once the whole project is read.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _haxeon_instrument_sources)
