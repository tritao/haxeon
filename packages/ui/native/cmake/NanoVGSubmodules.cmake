foreach(dependency IN ITEMS nanovg)
    # A submodule in a checkout, its files in a published package: either way, not an empty directory.
    file(GLOB _nkui_vendored "${NKUI_VENDOR_DIR}/${dependency}/*")
    if(NOT _nkui_vendored)
        message(FATAL_ERROR
            "${dependency} submodule is missing; run git submodule update --init")
    endif()
endforeach()

add_library(nkui_nanovg_core STATIC
    "${NKUI_VENDOR_DIR}/nanovg/src/nanovg.c")
target_include_directories(nkui_nanovg_core
    PUBLIC "$<BUILD_INTERFACE:${NKUI_VENDOR_DIR}/nanovg/src>"
)
target_compile_definitions(nkui_nanovg_core
    PUBLIC NVG_NO_TEXT=1
    PRIVATE NVG_NO_STB=1)
set_target_properties(nkui_nanovg_core PROPERTIES
    POSITION_INDEPENDENT_CODE YES
    C_VISIBILITY_PRESET hidden)
