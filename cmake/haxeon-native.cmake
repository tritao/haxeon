# The one CMAKE_PROJECT_INCLUDE Haxeon passes when it configures a package's CMake project. CMake takes a single file
# there, so this file includes the pieces a build needs:
#
#   haxeon-frame-pointers.cmake  always; it does nothing on Windows
#   haxeon-instrument.cmake      for the instrumented build flavor, when HAXEON_INSTRUMENT_HOOKS is set

include_guard(GLOBAL)

include("${CMAKE_CURRENT_LIST_DIR}/haxeon-frame-pointers.cmake")
if(DEFINED HAXEON_INSTRUMENT_HOOKS)
  include("${CMAKE_CURRENT_LIST_DIR}/haxeon-instrument.cmake")
endif()
