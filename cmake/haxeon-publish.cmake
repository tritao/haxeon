# Copies the runtime libraries a shared native CMake tree produced (-DFROM) to a project's native directory (-DTO).
# Libraries that are already there with the same content are skipped, so one a running program holds is not rewritten.
# Import libraries and exports stay in the tree; the FFI link steps read them there. The names published are recorded in
# TO/.haxeon-published, so a library that the tree stopped producing is removed again without touching other files of
# the directory (the FFI libraries of the package, for one).
file(MAKE_DIRECTORY "${TO}")
file(GLOB libraries LIST_DIRECTORIES false RELATIVE "${FROM}" "${FROM}/*.dll" "${FROM}/*.hdll" "${FROM}/*.so" "${FROM}/*.so.*" "${FROM}/*.dylib")
set(manifest "${TO}/.haxeon-published")
set(previous "")
if(EXISTS "${manifest}")
  file(STRINGS "${manifest}" previous)
endif()
foreach(library IN LISTS previous)
  if(NOT library IN_LIST libraries AND EXISTS "${TO}/${library}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -f "${TO}/${library}" RESULT_VARIABLE status ERROR_VARIABLE problem)
    if(NOT status EQUAL 0 OR EXISTS "${TO}/${library}")
      message(FATAL_ERROR "Cannot remove ${TO}/${library}, which the package no longer produces: a running program probably holds it open. Stop that program and build again.\n${problem}")
    endif()
  endif()
endforeach()
foreach(library IN LISTS libraries)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${FROM}/${library}" "${TO}/${library}" RESULT_VARIABLE status ERROR_VARIABLE problem)
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "Cannot publish ${library} to ${TO}: a running program probably holds ${TO}/${library} open. Stop that program and build again.\n${problem}")
  endif()
endforeach()
string(REPLACE ";" "\n" listing "${libraries}")
file(WRITE "${manifest}" "${listing}\n")
