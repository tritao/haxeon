# Copies the runtime libraries a shared native CMake tree produced (-DFROM) to a project's native directory (-DTO).
# Libraries that are already there with the same timestamp are skipped, so one a running program holds is not rewritten.
# Import libraries and exports stay in the tree; the FFI link steps read them there.
file(MAKE_DIRECTORY "${TO}")
file(GLOB libraries LIST_DIRECTORIES false RELATIVE "${FROM}" "${FROM}/*.dll" "${FROM}/*.hdll" "${FROM}/*.so" "${FROM}/*.so.*" "${FROM}/*.dylib")
foreach(library IN LISTS libraries)
  file(COPY "${FROM}/${library}" DESTINATION "${TO}")
endforeach()
