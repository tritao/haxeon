# The C runtimes Haxeon links into wasm32 modules (docs/design/WASM_LINEAR_RUNTIME.md): linear-runtime.wasm from
# native/wasm/*.c and crypto-runtime.wasm from native/wasm/crypto/*.c, each with a runtime-neutral variant, which imports
# only a module-local fuel-charge helper besides linear memory. They are committed in stdlib/haxeon/wasm, so compiling for
# Wasm needs no clang.
#
#   cmake --build <build> --target haxeon-wasm-runtime        rebuild them into stdlib/haxeon/wasm
#   cmake --build <build> --target haxeon-wasm-runtime-check  fail if a committed one differs from a fresh build
#
# Building them needs a clang with a wasm32 target: HAXEON_WASM_CLANG (the cache variable, or the environment variable when
# the build is configured), else an Emscripten SDK's clang next to this checkout, where NativeKit keeps one. Without one
# the check says it is skipped and succeeds, and the build fails saying what to set. Each module built is checked with
# cmake/check-wasm-runtime-modules.js (Node) before it is installed or compared.

set(_haxeon_wasm_clang_default "$ENV{HAXEON_WASM_CLANG}")
if(NOT _haxeon_wasm_clang_default)
  foreach(_candidate IN ITEMS "${CMAKE_SOURCE_DIR}/../nativekit/.tools/emsdk/upstream/bin/clang${CMAKE_EXECUTABLE_SUFFIX}"
      "${CMAKE_SOURCE_DIR}/../../materia/nativekit/.tools/emsdk/upstream/bin/clang${CMAKE_EXECUTABLE_SUFFIX}")
    if(EXISTS "${_candidate}")
      set(_haxeon_wasm_clang_default "${_candidate}")
      break()
    endif()
  endforeach()
endif()
set(HAXEON_WASM_CLANG "${_haxeon_wasm_clang_default}" CACHE FILEPATH "A clang with a wasm32 target, for the wasm32 runtimes")

set(_haxeon_wasm_committed "${CMAKE_SOURCE_DIR}/stdlib/haxeon/wasm")
set(_haxeon_wasm_names linear-runtime crypto-runtime linear-runtime-neutral crypto-runtime-neutral)

if(NOT HAXEON_WASM_CLANG OR NOT EXISTS "${HAXEON_WASM_CLANG}")
  add_custom_target(haxeon-wasm-runtime
    COMMAND "${CMAKE_COMMAND}" -E echo "No clang with a wasm32 target; set HAXEON_WASM_CLANG and configure again"
    COMMAND "${CMAKE_COMMAND}" -E false
    VERBATIM
  )
  add_custom_target(haxeon-wasm-runtime-check
    COMMAND "${CMAKE_COMMAND}" -E echo "SKIP: Wasm runtime freshness (no clang with a wasm32 target; set HAXEON_WASM_CLANG)"
    VERBATIM
  )
  return()
endif()

find_program(HAXEON_NODE node REQUIRED)
file(GLOB _haxeon_wasm_sources CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/native/wasm/*.c")
file(GLOB _haxeon_wasm_crypto_sources CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/native/wasm/crypto/*.c")
file(GLOB_RECURSE _haxeon_wasm_headers CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/native/wasm/*.h" "${CMAKE_SOURCE_DIR}/native/shared/*.h")
set(_haxeon_wasm_flags --target=wasm32 -O2 -nostdlib -mbulk-memory -fno-exceptions -ffreestanding -Wall -Wextra -Werror
  -Wl,--no-entry -Wl,--import-memory -Wl,--strip-all)
set(_haxeon_wasm_work "${CMAKE_BINARY_DIR}/wasm-runtime")

set(_haxeon_wasm_built)
foreach(_name IN LISTS _haxeon_wasm_names)
  if(_name MATCHES "^crypto")
    set(_sources ${_haxeon_wasm_crypto_sources})
  else()
    set(_sources ${_haxeon_wasm_sources})
  endif()
  set(_flags ${_haxeon_wasm_flags})
  if(_name MATCHES "neutral")
    list(APPEND _flags -DHAXEON_WASM_RUNTIME_NEUTRAL)
  endif()
  # The standard crypto runtime calls nothing outside itself; the others call back into the guest.
  if(NOT _name STREQUAL "crypto-runtime")
    list(APPEND _flags -Wl,--allow-undefined)
  endif()
  set(_output "${_haxeon_wasm_work}/${_name}.wasm")
  add_custom_command(OUTPUT "${_output}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_haxeon_wasm_work}"
    COMMAND "${HAXEON_WASM_CLANG}" ${_flags} -o "${_output}" ${_sources}
    DEPENDS ${_sources} ${_haxeon_wasm_headers}
    COMMENT "Building the wasm32 runtime ${_name}.wasm"
    VERBATIM
  )
  list(APPEND _haxeon_wasm_built "${_output}")
endforeach()

set(_haxeon_wasm_checked "${_haxeon_wasm_work}/checked.stamp")
add_custom_command(OUTPUT "${_haxeon_wasm_checked}"
  COMMAND "${HAXEON_NODE}" "${CMAKE_SOURCE_DIR}/cmake/check-wasm-runtime-modules.js" ${_haxeon_wasm_built}
  COMMAND "${CMAKE_COMMAND}" -E touch "${_haxeon_wasm_checked}"
  DEPENDS ${_haxeon_wasm_built} "${CMAKE_SOURCE_DIR}/cmake/check-wasm-runtime-modules.js"
  COMMENT "Checking the wasm32 runtimes' imports, exports and sections"
  VERBATIM
)

set(_haxeon_wasm_install)
set(_haxeon_wasm_compare)
foreach(_name IN LISTS _haxeon_wasm_names)
  list(APPEND _haxeon_wasm_install COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${_haxeon_wasm_work}/${_name}.wasm" "${_haxeon_wasm_committed}/${_name}.wasm")
  list(APPEND _haxeon_wasm_compare COMMAND "${CMAKE_COMMAND}" -E compare_files
    "${_haxeon_wasm_work}/${_name}.wasm" "${_haxeon_wasm_committed}/${_name}.wasm")
endforeach()
add_custom_target(haxeon-wasm-runtime
  ${_haxeon_wasm_install}
  COMMAND "${CMAKE_COMMAND}" -E echo "Installed the wasm32 runtimes in ${_haxeon_wasm_committed}"
  DEPENDS "${_haxeon_wasm_checked}"
  VERBATIM
)
add_custom_target(haxeon-wasm-runtime-check
  ${_haxeon_wasm_compare}
  COMMAND "${CMAKE_COMMAND}" -E echo "Wasm runtimes are up to date"
  DEPENDS "${_haxeon_wasm_checked}"
  VERBATIM
)
