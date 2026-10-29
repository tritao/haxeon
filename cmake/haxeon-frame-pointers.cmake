# Frame pointers for native packages on Linux and macOS, included by haxeon-native.cmake.
#
# The sampling profiler walks a stopped thread's stack along its frame-pointer chain; code built without frame pointers
# breaks the chain, and the native frames above it are missing from samples. Distributions now build with them
# (Ubuntu 24.04, Fedora 38) for the same reason, at a cost of about 1%. Windows x64 is walked with unwind data instead.

include_guard(GLOBAL)

if(WIN32)
  return()
endif()

include(CheckCompilerFlag)
foreach(language IN ITEMS C CXX)
  get_property(languages GLOBAL PROPERTY ENABLED_LANGUAGES)
  if(NOT language IN_LIST languages)
    continue()
  endif()
  foreach(flag IN ITEMS -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer)
    string(MAKE_C_IDENTIFIER "HAXEON_${language}${flag}" supported)
    check_compiler_flag(${language} ${flag} ${supported})
    if(${supported})
      add_compile_options($<$<COMPILE_LANGUAGE:${language}>:${flag}>)
    endif()
  endforeach()
endforeach()
