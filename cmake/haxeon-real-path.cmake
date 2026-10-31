# Prints the real path of -DP=<path>: junctions and symbolic links followed, forward slashes. Used by
# build/native/NativeCache to name shared CMake trees the same way from every route to a directory.
file(REAL_PATH "${P}" real)
execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${real}")
