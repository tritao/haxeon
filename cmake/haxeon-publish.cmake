# Copies the runtime libraries a shared native CMake tree produced (-DFROM) to a project's native directory (-DTO).
# Libraries that are already there with the same content are skipped, so one a running program holds is not rewritten.
# Import libraries and exports stay in the tree; the FFI link steps read them there. The names published are recorded in
# TO/.haxeon-published, so a library that the tree stopped producing is removed again without touching other files of
# the directory (the FFI libraries of the package, for one).
#
# On Windows a library a running program has loaded can be neither overwritten nor deleted, but it can be renamed. Such a
# library is moved aside to <name>.replaced-<random> and the new one is published under its name: the running program
# keeps the copy it mapped, and the next program loads the new one. Moved-aside copies that no program holds any more are
# removed by the next publish.
file(MAKE_DIRECTORY "${TO}")
file(GLOB libraries LIST_DIRECTORIES false RELATIVE "${FROM}" "${FROM}/*.dll" "${FROM}/*.hdll" "${FROM}/*.so" "${FROM}/*.so.*" "${FROM}/*.dylib")
set(manifest "${TO}/.haxeon-published")

file(GLOB replaced LIST_DIRECTORIES false "${TO}/*.replaced-*")
foreach(old IN LISTS replaced)
  # Fails while a running program still holds it; a later publish tries again.
  execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -f "${old}" RESULT_VARIABLE ignored OUTPUT_QUIET ERROR_QUIET)
endforeach()

# Sets `moved` in the caller to whether `path`, a library a running program holds, was renamed out of the way.
function(move_aside path)
  set(moved FALSE PARENT_SCOPE)
  if(NOT CMAKE_HOST_WIN32 OR NOT EXISTS "${path}")
    return()
  endif()
  string(RANDOM LENGTH 8 ALPHABET "0123456789abcdef" suffix)
  file(RENAME "${path}" "${path}.replaced-${suffix}" RESULT status NO_REPLACE)
  if(status STREQUAL "0")
    set(moved TRUE PARENT_SCOPE)
  endif()
endfunction()

set(previous "")
if(EXISTS "${manifest}")
  file(STRINGS "${manifest}" previous)
endif()
foreach(library IN LISTS previous)
  if(NOT library IN_LIST libraries AND EXISTS "${TO}/${library}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -f "${TO}/${library}" RESULT_VARIABLE status ERROR_VARIABLE problem)
    if(NOT status EQUAL 0 OR EXISTS "${TO}/${library}")
      move_aside("${TO}/${library}")
    endif()
    if(EXISTS "${TO}/${library}")
      message(FATAL_ERROR "Cannot remove ${TO}/${library}, which the package no longer produces: a running program probably holds it open. Stop that program and build again.\n${problem}")
    endif()
  endif()
endforeach()
foreach(library IN LISTS libraries)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${FROM}/${library}" "${TO}/${library}" RESULT_VARIABLE status ERROR_VARIABLE problem)
  if(NOT status EQUAL 0)
    move_aside("${TO}/${library}")
    if(moved)
      execute_process(COMMAND "${CMAKE_COMMAND}" -E copy "${FROM}/${library}" "${TO}/${library}" RESULT_VARIABLE status ERROR_VARIABLE retry)
      string(APPEND problem "${retry}")
    endif()
  endif()
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "Cannot publish ${library} to ${TO}: a running program probably holds ${TO}/${library} open. Stop that program and build again.\n${problem}")
  endif()
endforeach()
string(REPLACE ";" "\n" listing "${libraries}")
file(WRITE "${manifest}" "${listing}\n")
