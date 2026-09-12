# Build an isolated HashLink host for the JIT-support lifetime regression.
# Unlike `hl`, this host does not JIT an application module before loading the
# first runtime module, so the test can retire the module that first installed
# the C2HL trampoline.
if(UNIX AND NOT APPLE)
  get_target_property(_hl_vm_sources hl SOURCES)
  get_target_property(_hl_vm_source_dir hl SOURCE_DIR)
  set(_haxeon_jit_lifetime_sources)
  foreach(_source IN LISTS _hl_vm_sources)
    get_filename_component(_source_name "${_source}" NAME)
    if(_source_name STREQUAL "main.c")
      continue()
    endif()
    if(IS_ABSOLUTE "${_source}")
      list(APPEND _haxeon_jit_lifetime_sources "${_source}")
    else()
      list(APPEND _haxeon_jit_lifetime_sources "${_hl_vm_source_dir}/${_source}")
    endif()
  endforeach()

  add_executable(haxeon-jit-support-lifetime EXCLUDE_FROM_ALL
    ${_haxeon_jit_lifetime_sources}
    jit_support_lifetime.c
  )
  target_include_directories(haxeon-jit-support-lifetime PRIVATE "${_hl_vm_source_dir}/src")
  target_link_libraries(haxeon-jit-support-lifetime PRIVATE $<TARGET_PROPERTY:hl,LINK_LIBRARIES>)
  target_compile_features(haxeon-jit-support-lifetime PRIVATE c_std_11)
  set_target_properties(haxeon-jit-support-lifetime PROPERTIES
    ENABLE_EXPORTS ON
    BUILD_RPATH "${CMAKE_SOURCE_DIR}/.tools/hashlink"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/.tools/hashlink"
  )
  foreach(_property IN ITEMS COMPILE_DEFINITIONS COMPILE_OPTIONS LINK_OPTIONS)
    get_target_property(_value hl ${_property})
    if(_value)
      set_property(TARGET haxeon-jit-support-lifetime APPEND PROPERTY ${_property} "${_value}")
    endif()
  endforeach()
endif()
