# Runs a command while holding the cross-process lock of a shared native CMake tree (see build/native/NativeCache):
#
#   cmake -DLOCK=<file> -DHOLDER=<text> [-DWAIT=<seconds>] [-DCACHE_FILE=<CMakeCache.txt> -DSOURCE=<dir>]
#         -P haxeon-locked.cmake <command> [<arguments>...]
#
# The lock is an operating system file lock, so it is released when this process ends, however it ends; a killed build
# never blocks the next one. While the holder lives the wait has no fixed end (a cold build of a large package takes
# minutes): it reports every 30 s who holds the lock, and gives up after WAIT seconds (default 30 minutes) as a safety net.
# HOLDER is written beside the lock so a waiter can name who has it.
#
# With CACHE_FILE and SOURCE, a CMake cache that another source directory generated is deleted once the lock is held,
# because CMake refuses to configure a tree for another source.
if(NOT DEFINED WAIT)
  set(WAIT 1800)
endif()
get_filename_component(directory "${LOCK}" DIRECTORY)
file(MAKE_DIRECTORY "${directory}")
file(LOCK "${LOCK}" GUARD PROCESS TIMEOUT 0 RESULT_VARIABLE locked)
set(waited 0)
while(NOT locked STREQUAL "0")
  set(holder "unknown")
  if(EXISTS "${LOCK}.holder")
    file(READ "${LOCK}.holder" holder)
    string(STRIP "${holder}" holder)
  endif()
  if(waited GREATER_EQUAL WAIT)
    message(FATAL_ERROR "Gave up after ${waited} s waiting for the native build lock ${LOCK}, held by: ${holder}")
  endif()
  message(STATUS "haxeon: waiting ${waited} s for another build to finish with ${LOCK} (held by: ${holder})")
  file(LOCK "${LOCK}" GUARD PROCESS TIMEOUT 30 RESULT_VARIABLE locked)
  math(EXPR waited "${waited} + 30")
endwhile()
file(WRITE "${LOCK}.holder" "${HOLDER}\n")

if(DEFINED CACHE_FILE AND DEFINED SOURCE AND EXISTS "${CACHE_FILE}")
  file(STRINGS "${CACHE_FILE}" line REGEX "^CMAKE_HOME_DIRECTORY:" LIMIT_COUNT 1)
  string(REGEX REPLACE "^[^=]*=" "" generated "${line}")
  file(REAL_PATH "${SOURCE}" wanted)
  if(EXISTS "${generated}")
    file(REAL_PATH "${generated}" generated)
  endif()
  if(WIN32)
    string(TOLOWER "${wanted}" wanted)
    string(TOLOWER "${generated}" generated)
  endif()
  if(NOT generated STREQUAL wanted)
    file(REMOVE "${CACHE_FILE}")
  endif()
endif()

# Everything after the script path is the command. A semicolon inside an argument is escaped so the list keeps it whole.
set(command "")
set(seen FALSE)
set(skip FALSE)
math(EXPR last "${CMAKE_ARGC} - 1")
foreach(index RANGE 1 ${last})
  set(argument "${CMAKE_ARGV${index}}")
  if(seen)
    if(skip)
      set(skip FALSE)
    else()
      string(REPLACE ";" "\;" argument "${argument}")
      list(APPEND command "${argument}")
    endif()
  elseif(argument STREQUAL "-P")
    set(seen TRUE)
    set(skip TRUE)
  endif()
endforeach()
execute_process(COMMAND ${command} RESULT_VARIABLE status)
if(NOT status EQUAL 0)
  message(FATAL_ERROR "${command} exited with ${status}")
endif()
