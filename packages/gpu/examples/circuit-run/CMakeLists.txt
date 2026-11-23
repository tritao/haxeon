cmake_minimum_required(VERSION 3.21)
project(haxeon_circuit_run LANGUAGES C CXX)

get_filename_component(HAXEON_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)
set(NATIVEKIT_DIR "${HAXEON_ROOT}/vendor/nativekit" CACHE PATH "NativeKit source directory")
if(EMSCRIPTEN)
    set(NK_BUILD_SHARED OFF CACHE BOOL "Build shared runtimes" FORCE)
    set(NK_SOKOL_BACKEND gles3 CACHE STRING "WebGL2 GPU backend" FORCE)
else()
    set(NK_BUILD_SHARED ON CACHE BOOL "Build shared runtimes" FORCE)
endif()
set(NK_BUILD_AUDIO ON CACHE BOOL "Enable audio" FORCE)
set(NK_BUILD_GPU ON CACHE BOOL "Enable GPU" FORCE)
set(NK_BUILD_TESTS OFF CACHE BOOL "Build dependency tests" FORCE)
set(NK_BUILD_EXAMPLES OFF CACHE BOOL "Build dependency examples" FORCE)
add_subdirectory("${NATIVEKIT_DIR}" nativekit)
set(NKUI_NATIVEKIT_DIR "${NATIVEKIT_DIR}" CACHE PATH "NativeKit source for UI" FORCE)
add_subdirectory("${HAXEON_ROOT}/packages/ui" ui)

if(HAXEON_NATIVE_OUTPUT_DIR)
    foreach(runtime IN ITEMS nativekit nativekit_gpu nativekit_ui)
        set_target_properties(${runtime} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
            RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
            ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")
    endforeach()
endif()
add_custom_target(circuit_run_native DEPENDS nativekit nativekit_gpu nativekit_ui)

if(EMSCRIPTEN)
    set(circuit_run_web_dir "${CMAKE_CURRENT_SOURCE_DIR}/web")
    set(NKUI_HAXEON_MEMORY_CONTRACT_VERSION 1)
    set(NKUI_HAXEON_WASM_PAGE_SIZE 65536)
    set(NKUI_HAXEON_HOST_HEAP_BASE 0)
    set(NKUI_HAXEON_HOST_HEAP_LIMIT "${NK_WASM_HOST_HEAP_LIMIT}")
    set(NKUI_HAXEON_GUEST_MEMORY_BASE "${NKUI_HAXEON_HOST_HEAP_LIMIT}")
    set(NKUI_HAXEON_GUEST_MEMORY_LIMIT 268435456)
    set(NKUI_HAXEON_MEMORY_LIMIT "${NKUI_HAXEON_GUEST_MEMORY_LIMIT}")
    set(memory_contract "${CMAKE_CURRENT_BINARY_DIR}/nativekit_haxeon_memory_contract.json")
    configure_file("${HAXEON_ROOT}/packages/ui/cmake/wasm_memory_contract.json.in" "${memory_contract}" @ONLY)

    find_program(node_executable node REQUIRED)
    file(GLOB_RECURSE guest_sources CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/src/*"
        "${HAXEON_ROOT}/packages/platform/src/*.hx"
        "${HAXEON_ROOT}/packages/gpu/src/*.hx"
        "${HAXEON_ROOT}/packages/audio/src/*.hx"
        "${HAXEON_ROOT}/packages/editor/src/*.hx"
        "${HAXEON_ROOT}/packages/ui/haxe/*.hx"
        "${HAXEON_ROOT}/packages/ui/bindings/haxe/*.hx"
        "${HAXEON_ROOT}/stdlib/*.hx")
    set(guest_wasm "${CMAKE_CURRENT_BINARY_DIR}/circuit_run_guest.wasm")
    set(host_exports "${CMAKE_CURRENT_BINARY_DIR}/circuit_run_exports.json")
    add_custom_command(OUTPUT "${guest_wasm}" "${host_exports}"
        COMMAND bash "${circuit_run_web_dir}/build-guest.sh" "${guest_wasm}" "${memory_contract}"
        COMMAND "${node_executable}" "${circuit_run_web_dir}/exports.js" "${guest_wasm}" "${host_exports}"
        DEPENDS ${guest_sources} "${memory_contract}" "${circuit_run_web_dir}/build-guest.sh"
            "${circuit_run_web_dir}/exports.js"
            "${NATIVEKIT_DIR}/modules/gpu/include/nativekit_gpu.h"
            "${HAXEON_ROOT}/packages/gpu/bindings/nativekit_gpu_import.h"
            "${HAXEON_ROOT}/packages/gpu/bindings/nativekit-gpu.hxmap"
            "${HAXEON_ROOT}/packages/platform/bindings/nativekit-wasm.hxi"
            "${HAXEON_ROOT}/packages/platform/bindings/nativekit-net-wasm.hxi"
            "${HAXEON_ROOT}/packages/audio/bindings/nativekit-audio-wasm.hxi"
            "${HAXEON_ROOT}/packages/ui/bindings/nativekit-ui-wasm.hxi"
            "${HAXEON_ROOT}/packages/platform/bindings/nativekit.hxmap"
            "${HAXEON_ROOT}/packages/platform/bindings/nativekit-net.hxmap"
            "${HAXEON_ROOT}/packages/audio/bindings/nativekit-audio.hxmap"
            "${HAXEON_ROOT}/packages/ui/bindings/nativekit-ui.hxmap"
        USES_TERMINAL VERBATIM)
    add_custom_target(circuit_run_guest DEPENDS "${guest_wasm}" "${host_exports}")

    add_executable(circuit_run "${circuit_run_web_dir}/host.c")
    add_dependencies(circuit_run circuit_run_guest)
    set(plex_font "${HAXEON_ROOT}/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf")
    set_property(TARGET circuit_run APPEND PROPERTY LINK_DEPENDS "${host_exports}" "${plex_font}")
    target_link_libraries(circuit_run PRIVATE NativeKit::ui NativeKit::nativekit
        NativeKit::wasm_host_allocator)
    target_link_options(circuit_run PRIVATE
        "-sINITIAL_MEMORY=${NKUI_HAXEON_MEMORY_LIMIT}" "-sALLOW_MEMORY_GROWTH=0"
        "-sEXPORTED_FUNCTIONS=@${host_exports}" "-sEXPORTED_RUNTIME_METHODS=addFunction,removeFunction"
        "-sALLOW_TABLE_GROWTH=1" "-sNO_EXIT_RUNTIME=1"
        "--preload-file=${plex_font}@/assets/IBMPlexSans-Regular.ttf")
    add_custom_target(circuit_run_site ALL
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${circuit_run_web_dir}/index.html"
            "${CMAKE_CURRENT_BINARY_DIR}/index.html"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${HAXEON_ROOT}/stdlib/haxeon/wasm/haxeon-host.js"
            "${CMAKE_CURRENT_BINARY_DIR}/haxeon-host.js"
        DEPENDS circuit_run VERBATIM)
endif()
