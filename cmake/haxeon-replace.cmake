# Replaces the file TO with a copy of FROM by rename, never by writing into TO:
#
#   cmake -DFROM=<built file> -DTO=<published file> -P cmake/haxeon-replace.cmake
#
# A process running TO keeps the file it started from, so the native build can publish a new VM while the CLI, the test
# driver or a compiler worker runs on the old one. The copy is staged beside TO, on the same file system, so the final
# step is a rename. Windows does not let a running executable be replaced, but does let it be renamed: TO is moved aside
# first, and copies moved aside earlier are deleted when nothing runs them any more.
if(NOT DEFINED FROM OR NOT DEFINED TO)
  message(FATAL_ERROR "usage: cmake -DFROM=<file> -DTO=<file> -P haxeon-replace.cmake")
endif()

string(RANDOM LENGTH 10 ALPHABET "0123456789abcdefghijklmnopqrstuvwxyz" suffix)
set(staged "${TO}.new-${suffix}")
file(COPY_FILE "${FROM}" "${staged}")

if(CMAKE_HOST_WIN32 AND EXISTS "${TO}")
  file(RENAME "${TO}" "${TO}.old-${suffix}")
endif()
file(RENAME "${staged}" "${TO}")

# Earlier copies moved aside; one still running stays until a later build.
file(GLOB retired "${TO}.old-*")
foreach(old IN LISTS retired)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E rm -f "${old}" RESULT_VARIABLE ignored OUTPUT_QUIET ERROR_QUIET)
endforeach()
