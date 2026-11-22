# Builds the pinned libffi (vendor/libffi) as a static library into install_dir, for Bootstrap.cmake.
# Sets LIBFFI_INCLUDE_DIR and LIBFFI_LIBRARY in the caller's scope; on Windows install_dir holds one
# install per MSVC runtime (msvc-release, msvc-debug) and the two variables name the release one.

set(LIBFFI_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(libffi_run description working_dir)
  execute_process(
    COMMAND ${ARGN}
    WORKING_DIRECTORY "${working_dir}"
    RESULT_VARIABLE status
    COMMAND_ECHO STDOUT
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "${description} failed with exit code ${status}")
  endif()
endfunction()

function(build_pinned_libffi root_dir install_dir)
  set(submodule_dir "${root_dir}/vendor/libffi")
  if(NOT EXISTS "${submodule_dir}/configure.ac")
    message(FATAL_ERROR "pinned libffi submodule is missing; initialize vendor/libffi first")
  endif()

  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
    find_program(CTEST_EXECUTABLE ctest REQUIRED)
    foreach(config IN ITEMS Release Debug)
      string(TOLOWER "${config}" config_lower)
      set(build_dir "${root_dir}/out/libffi/msvc-x64-static-${config_lower}")
      set(config_install_dir "${install_dir}/msvc-${config_lower}")
      libffi_run("Configure pinned libffi ${config}" "${root_dir}"
        "${CMAKE_COMMAND}" -S "${LIBFFI_MODULE_DIR}/libffi" -B "${build_dir}"
        -G Ninja
        "-DCMAKE_BUILD_TYPE=${config}"
        "-DCMAKE_INSTALL_PREFIX=${config_install_dir}")
      libffi_run("Build pinned libffi ${config}" "${root_dir}"
        "${CMAKE_COMMAND}" --build "${build_dir}" --parallel)
      libffi_run("Test pinned libffi ${config}" "${root_dir}"
        "${CTEST_EXECUTABLE}" --test-dir "${build_dir}" --output-on-failure -C "${config}")
      libffi_run("Install pinned libffi ${config}" "${root_dir}"
        "${CMAKE_COMMAND}" --install "${build_dir}")
    endforeach()
    set(LIBFFI_INCLUDE_DIR "${install_dir}/msvc-release/include" PARENT_SCOPE)
    set(LIBFFI_LIBRARY "${install_dir}/msvc-release/lib/ffi.lib" PARENT_SCOPE)
    return()
  endif()

  find_program(GIT_EXECUTABLE git REQUIRED)
  set(git_safe "-c" "safe.directory=${root_dir}" "-c" "safe.directory=${submodule_dir}")
  execute_process(
    COMMAND "${GIT_EXECUTABLE}" ${git_safe} -C "${submodule_dir}" rev-parse HEAD
    OUTPUT_VARIABLE revision
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
  )
  execute_process(
    COMMAND uname -m
    OUTPUT_VARIABLE host_arch
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  set(source_dir "${root_dir}/out/libffi/source-${revision}")
  set(build_dir "${root_dir}/out/libffi/native-static")
  set(stamp_file "${install_dir}/.build-stamp")
  set(stamp_value "${revision} native-static ${CMAKE_HOST_SYSTEM_NAME}-${host_arch}")
  set(LIBFFI_INCLUDE_DIR "${install_dir}/include" PARENT_SCOPE)
  set(LIBFFI_LIBRARY "${install_dir}/lib/libffi.a" PARENT_SCOPE)

  if(EXISTS "${stamp_file}" AND EXISTS "${install_dir}/include/ffi.h" AND EXISTS "${install_dir}/lib/libffi.a")
    file(STRINGS "${stamp_file}" installed_stamp LIMIT_COUNT 1)
    if(installed_stamp STREQUAL stamp_value)
      message(STATUS "Pinned libffi ${revision} is already installed")
      return()
    endif()
  endif()

  foreach(tool IN ITEMS autoreconf make tar)
    find_program(libffi_tool_${tool} "${tool}")
    if(NOT libffi_tool_${tool})
      message(FATAL_ERROR "missing required libffi build tool: ${tool}")
    endif()
  endforeach()

  if(NOT EXISTS "${source_dir}/configure.ac")
    file(MAKE_DIRECTORY "${source_dir}")
    execute_process(
      COMMAND "${GIT_EXECUTABLE}" ${git_safe} -C "${submodule_dir}" archive HEAD
      COMMAND tar -x -C "${source_dir}"
      COMMAND_ERROR_IS_FATAL ANY
    )
  endif()
  # libffi's configure.ac calls a Libtool macro that newer libtoolize installs no longer ship.
  file(COPY_FILE "${LIBFFI_MODULE_DIR}/libffi-libtool-compat.m4" "${source_dir}/m4/libtool-compat.m4")
  file(READ "${source_dir}/acinclude.m4" acinclude)
  if(NOT acinclude MATCHES "m4/libtool-compat\\.m4")
    file(APPEND "${source_dir}/acinclude.m4" "\nm4_include([m4/libtool-compat.m4])\n")
  endif()
  libffi_run("Regenerate libffi configure" "${source_dir}" autoreconf -f -v -i)

  # A rebuild starts clean: a build tree configured for other sources keeps their paths in its dependencies.
  file(REMOVE_RECURSE "${build_dir}")
  file(MAKE_DIRECTORY "${build_dir}" "${install_dir}")
  libffi_run("Configure pinned libffi" "${build_dir}"
    "${source_dir}/configure" "--prefix=${install_dir}"
    --enable-static --disable-shared --with-pic --disable-docs)

  set(jobs "$ENV{BUILD_JOBS}")
  if(NOT jobs MATCHES "^[1-9][0-9]*$")
    cmake_host_system_information(RESULT jobs QUERY NUMBER_OF_LOGICAL_CORES)
  endif()
  libffi_run("Build pinned libffi" "${build_dir}" make "-j${jobs}")
  libffi_run("Install pinned libffi" "${build_dir}" make install)

  file(WRITE "${stamp_file}" "${stamp_value}\n")
  message(STATUS "Built pinned libffi ${revision} into ${install_dir}")
endfunction()
