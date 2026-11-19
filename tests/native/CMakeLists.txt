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

# The C programs and HashLink libraries the GC and JIT integration tests run (tests/integration/test-gc-*.sh and
# test-jit-*-allocation.sh), built with the VM so they take its compile settings: its C runtime with MSVC, its headers, its
# optimization. A program hosts the VM itself and links the static core; a library is loaded into hl and takes the VM's API
# from it. They land in <build>/native-tests, beside hashlink-runtime.
set(HAXEON_NATIVE_TEST_DIR "${CMAKE_BINARY_DIR}/native-tests")
set(HAXEON_NATIVE_TEST_PROGRAMS
  gc_allocation_paths gc_empty_pages gc_owner_pages gc_owner_tlab gc_owner_classes gc_alloc_groups gc_mark_completion gc_stack_boundary
  string_map_hash)
set(HAXEON_NATIVE_TESTS)
foreach(_program IN LISTS HAXEON_NATIVE_TEST_PROGRAMS)
  set(_target haxeon-native-test-${_program})
  add_executable(${_target} ${_program}.c)
  target_link_libraries(${_target} PRIVATE hlvm)
  # The program defines the VM's functions itself rather than importing them from a DLL; on Linux it exports them, as hl
  # does, to the libraries it loads.
  target_compile_definitions(${_target} PRIVATE LIBHL_STATIC)
  set_target_properties(${_target} PROPERTIES
    OUTPUT_NAME ${_program}
    ENABLE_EXPORTS ON
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_TEST_DIR}"
  )
  list(APPEND HAXEON_NATIVE_TESTS ${_target})
endforeach()
# The JIT allocation hooks, loaded by @:hlNative library name.
foreach(_library IN ITEMS "jitbox:jit_box_hooks" "jitalloc:jit_alloc_hooks")
  string(REPLACE ":" ";" _parts "${_library}")
  list(GET _parts 0 _name)
  list(GET _parts 1 _source)
  set(_target haxeon-native-test-${_name})
  add_library(${_target} SHARED ${_source}.c)
  target_include_directories(${_target} PRIVATE "${CMAKE_SOURCE_DIR}/vendor/hashlink/src")
  target_link_libraries(${_target} PRIVATE hl)
  if(APPLE)
    target_link_options(${_target} PRIVATE "-Wl,-undefined,dynamic_lookup")
  endif()
  set_target_properties(${_target} PROPERTIES
    OUTPUT_NAME ${_name}
    PREFIX ""
    SUFFIX ".hdll"
    RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_TEST_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_TEST_DIR}"
  )
  list(APPEND HAXEON_NATIVE_TESTS ${_target})
endforeach()
add_custom_target(haxeon-native-tests DEPENDS ${HAXEON_NATIVE_TESTS})
