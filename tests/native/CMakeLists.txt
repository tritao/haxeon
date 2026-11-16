# Build an isolated HashLink host for the JIT-support lifetime regression.
# Unlike `hl`, this host does not JIT an application module before loading the
# first runtime module, so the test can retire the module that first installed
# the C2HL trampoline.
if(UNIX AND NOT APPLE)
  # The whole VM core, as hl links it, so the host exports the same API to the modules it loads.
  add_executable(haxeon-jit-support-lifetime EXCLUDE_FROM_ALL jit_support_lifetime.c)
  target_link_libraries(haxeon-jit-support-lifetime PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,hlvm>")
  target_compile_features(haxeon-jit-support-lifetime PRIVATE c_std_11)
  set_target_properties(haxeon-jit-support-lifetime PROPERTIES
    ENABLE_EXPORTS ON
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_HASHLINK_OUTPUT_DIR}"
  )
  # Its own source sees the VM's headers as hl's sources do.
  foreach(_property IN ITEMS COMPILE_DEFINITIONS COMPILE_OPTIONS)
    get_target_property(_value hl ${_property})
    if(_value)
      set_property(TARGET haxeon-jit-support-lifetime APPEND PROPERTY ${_property} "${_value}")
    endif()
  endforeach()
endif()

# Exercise primitive metadata across the external HDLL boundary.
add_library(jit_native_properties SHARED jit_native_properties.c)
target_include_directories(jit_native_properties PRIVATE "${CMAKE_SOURCE_DIR}/vendor/hashlink/src")
# Loaded into hl, so it resolves the libhl API from the executable rather than loading a second libhl.
target_link_libraries(jit_native_properties PRIVATE hl)
if(APPLE)
  target_link_options(jit_native_properties PRIVATE "-Wl,-undefined,dynamic_lookup")
endif()
set_target_properties(jit_native_properties PROPERTIES
  PREFIX ""
  SUFFIX ".hdll"
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_RUNTIME_OUTPUT_DIR}"
  LIBRARY_OUTPUT_DIRECTORY "${HAXEON_RUNTIME_OUTPUT_DIR}"
)
