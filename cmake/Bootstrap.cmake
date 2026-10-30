cmake_minimum_required(VERSION 3.24)

get_filename_component(HAXEON_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(TOOLS_DIR "${HAXEON_ROOT}/.tools")
set(HAXE_VERSION "4.3.7")
set(FORMATTER_VERSION "1.18.0")
set(FORMATTER_SHA256 "2d29c9b56e54b2643e07ee64003c3fc30a5bc133bdcb4cc15c48f09acda7a047")

find_program(GIT_EXECUTABLE git REQUIRED)
find_program(NODE_EXECUTABLE node REQUIRED)
file(MAKE_DIRECTORY "${TOOLS_DIR}")

function(run_checked description)
  execute_process(
    COMMAND ${ARGN}
    WORKING_DIRECTORY "${HAXEON_ROOT}"
    RESULT_VARIABLE status
    COMMAND_ECHO STDOUT
  )
  if(NOT status EQUAL 0)
    message(FATAL_ERROR "${description} failed with exit code ${status}")
  endif()
endfunction()

function(download_checked url destination sha256)
  if(NOT EXISTS "${destination}")
    message(STATUS "Downloading ${url}")
    file(DOWNLOAD "${url}" "${destination}"
      EXPECTED_HASH "SHA256=${sha256}"
      TLS_VERIFY ON
      SHOW_PROGRESS
      STATUS download_status
    )
    list(GET download_status 0 status)
    list(GET download_status 1 detail)
    if(NOT status EQUAL 0)
      file(REMOVE "${destination}")
      message(FATAL_ERROR "Download failed: ${detail}")
    endif()
  endif()
endfunction()

function(extract_single_directory archive destination)
  if(EXISTS "${destination}")
    return()
  endif()
  set(temp_dir "${destination}.unpack")
  file(REMOVE_RECURSE "${temp_dir}")
  file(MAKE_DIRECTORY "${temp_dir}")
  file(ARCHIVE_EXTRACT INPUT "${archive}" DESTINATION "${temp_dir}")
  file(GLOB children LIST_DIRECTORIES TRUE "${temp_dir}/*")
  list(LENGTH children child_count)
  if(NOT child_count EQUAL 1 OR NOT IS_DIRECTORY "${children}")
    message(FATAL_ERROR "Expected ${archive} to contain one top-level directory")
  endif()
  file(RENAME "${children}" "${destination}")
  file(REMOVE_RECURSE "${temp_dir}")
endfunction()

# Initialize the exact submodule revisions recorded by this checkout.
run_checked("Submodule initialization"
  "${GIT_EXECUTABLE}" submodule update --init vendor/hashlink vendor/hashlink-debugger vendor/utest vendor/libffi)

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
  find_program(CTEST_EXECUTABLE ctest REQUIRED)
  foreach(libffi_config IN ITEMS Release Debug)
    string(TOLOWER "${libffi_config}" libffi_config_lower)
    set(libffi_build_dir "${HAXEON_ROOT}/out/libffi/msvc-x64-static-${libffi_config_lower}")
    set(libffi_install_dir "${HAXEON_ROOT}/.tools/libffi-static/msvc-${libffi_config_lower}")
    run_checked("Configure pinned libffi ${libffi_config}"
      "${CMAKE_COMMAND}" -S "${HAXEON_ROOT}/cmake/libffi" -B "${libffi_build_dir}"
      -G Ninja
      "-DCMAKE_BUILD_TYPE=${libffi_config}"
      "-DCMAKE_INSTALL_PREFIX=${libffi_install_dir}")
    run_checked("Build pinned libffi ${libffi_config}"
      "${CMAKE_COMMAND}" --build "${libffi_build_dir}" --parallel)
    run_checked("Test pinned libffi ${libffi_config}"
      "${CTEST_EXECUTABLE}" --test-dir "${libffi_build_dir}" --output-on-failure -C "${libffi_config}")
    run_checked("Install pinned libffi ${libffi_config}"
      "${CMAKE_COMMAND}" --install "${libffi_build_dir}")
  endforeach()
else()
  find_program(BASH_EXECUTABLE bash REQUIRED)
  run_checked("Build pinned libffi"
    "${BASH_EXECUTABLE}" "${HAXEON_ROOT}/scripts/build-libffi.sh")
endif()

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
  set(haxe_archive "${TOOLS_DIR}/haxe-${HAXE_VERSION}-win64.zip")
  set(haxe_url "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-win64.zip")
  set(haxe_sha256 "29f7acb0fb9fc66a2b9f6bd9453af3474ccb14ebd9fd0142f351d7311c4010c9")
  set(haxe_executable "${TOOLS_DIR}/haxe/haxe.exe")
  set(hashlink_executable "${TOOLS_DIR}/hashlink/hl.exe")
  set(native_preset "windows-msvc")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  execute_process(
    COMMAND uname -m
    OUTPUT_VARIABLE linux_host_arch
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  if(linux_host_arch MATCHES "^(aarch64|arm64)$")
    set(haxe_archive "${TOOLS_DIR}/haxe-${HAXE_VERSION}-linux-arm64.tar.gz")
    set(haxe_url "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-linux-arm64.tar.gz")
    set(haxe_sha256 "003f6bdbbd1e028b81123d3d5efe4ea7bd20d9afcbd54206606a33b5f165724a")
  elseif(linux_host_arch MATCHES "^(x86_64|amd64)$")
    set(haxe_archive "${TOOLS_DIR}/haxe-${HAXE_VERSION}-linux64.tar.gz")
    set(haxe_url "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-linux64.tar.gz")
    set(haxe_sha256 "a156b3d039daa572f1f9329870ee753e3c39b7514fe8c818069323579659acca")
  else()
    message(FATAL_ERROR "Bootstrap does not yet have a pinned Haxe archive for Linux ${linux_host_arch}")
  endif()
  set(haxe_executable "${TOOLS_DIR}/haxe/haxe")
  set(hashlink_executable "${TOOLS_DIR}/hashlink/hl")
  set(native_preset "release")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
  set(haxe_archive "${TOOLS_DIR}/haxe-${HAXE_VERSION}-osx.tar.gz")
  set(haxe_url "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-osx.tar.gz")
  set(haxe_sha256 "1d355cb28bc25784b33acce023caeb28d50ccb14e953134a62b889697947efdc")
  set(haxe_executable "${TOOLS_DIR}/haxe/haxe")
  set(hashlink_executable "${TOOLS_DIR}/hashlink/hl")
  set(native_preset "release")
else()
  message(FATAL_ERROR "Bootstrap does not yet have a pinned Haxe archive for ${CMAKE_HOST_SYSTEM_NAME}")
endif()

download_checked("${haxe_url}" "${haxe_archive}" "${haxe_sha256}")
extract_single_directory("${haxe_archive}" "${TOOLS_DIR}/haxe")

set(formatter_archive "${TOOLS_DIR}/formatter-${FORMATTER_VERSION}.zip")
download_checked(
  "https://lib.haxe.org/p/formatter/${FORMATTER_VERSION}/download/"
  "${formatter_archive}"
  "${FORMATTER_SHA256}"
)
if(NOT EXISTS "${TOOLS_DIR}/formatter/run.js")
  file(MAKE_DIRECTORY "${TOOLS_DIR}/formatter")
  file(ARCHIVE_EXTRACT INPUT "${formatter_archive}" DESTINATION "${TOOLS_DIR}/formatter")
endif()

# Ninja 1.13 can join Haxeon's job server, so native builds share one job limit with Haxeon's own
# actions; older system copies cannot. Windows uses the Ninja that ships with Visual Studio (see
# src/build/native/MsvcEnvironment.hx).
if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux" OR CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
  set(NINJA_VERSION "1.13.2")
  if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(ninja_asset "ninja-mac.zip")
    set(ninja_sha256 "c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b")
  elseif(linux_host_arch MATCHES "^(aarch64|arm64)$")
    set(ninja_asset "ninja-linux-aarch64.zip")
    set(ninja_sha256 "fd2cacc8050a7f12a16a2e48f9e06fca5c14fc4c2bee2babb67b58be17a607fc")
  else()
    set(ninja_asset "ninja-linux.zip")
    set(ninja_sha256 "5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6")
  endif()
  set(ninja_archive "${TOOLS_DIR}/ninja-${NINJA_VERSION}-${ninja_asset}")
  download_checked(
    "https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/${ninja_asset}"
    "${ninja_archive}"
    "${ninja_sha256}"
  )
  if(NOT EXISTS "${TOOLS_DIR}/ninja/ninja")
    file(MAKE_DIRECTORY "${TOOLS_DIR}/ninja")
    file(ARCHIVE_EXTRACT INPUT "${ninja_archive}" DESTINATION "${TOOLS_DIR}/ninja")
    file(CHMOD "${TOOLS_DIR}/ninja/ninja"
      PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
  endif()
  run_checked("Ninja version check" "${TOOLS_DIR}/ninja/ninja" --version)
endif()

# ccache, rarely installed on Windows. Haxeon launches MSVC through it for the CMake packages it builds with Ninja
# (src/build/native/NativeCompilerCache.hx), so a build tree that is configured again or deleted and rebuilt reuses its
# objects from %LOCALAPPDATA%\ccache.
# It is optional: when it cannot be downloaded (offline, say) the bootstrap warns and the builds compile without it.
# Script mode leaves CMAKE_HOST_SYSTEM_PROCESSOR unset.
if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows" AND "$ENV{PROCESSOR_ARCHITECTURE}" STREQUAL "AMD64")
  set(CCACHE_VERSION "4.14.1")
  set(ccache_name "ccache-${CCACHE_VERSION}-windows-x86_64")
  set(ccache_archive "${TOOLS_DIR}/${ccache_name}.zip")
  if(EXISTS "${TOOLS_DIR}/ccache" AND NOT EXISTS "${TOOLS_DIR}/ccache/ccache-${CCACHE_VERSION}")
    file(REMOVE_RECURSE "${TOOLS_DIR}/ccache")
  endif()
  if(NOT EXISTS "${TOOLS_DIR}/ccache" AND NOT EXISTS "${ccache_archive}")
    message(STATUS "Downloading ${ccache_name}.zip")
    # EXPECTED_HASH would make any failed download fatal, so the hash is checked after it.
    file(DOWNLOAD "https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/${ccache_name}.zip"
      "${ccache_archive}.part"
      TLS_VERIFY ON
      STATUS ccache_download)
    list(GET ccache_download 0 ccache_status)
    list(GET ccache_download 1 ccache_detail)
    if(ccache_status EQUAL 0)
      file(SHA256 "${ccache_archive}.part" ccache_sha256)
      if(ccache_sha256 STREQUAL "6219f3865ca59aec41ee4b678df171d5d35855ecb2b6dbbbd20690b3a68af7b4")
        file(RENAME "${ccache_archive}.part" "${ccache_archive}")
      else()
        set(ccache_detail "SHA-256 ${ccache_sha256} is not the pinned one")
      endif()
    endif()
    file(REMOVE "${ccache_archive}.part")
    if(NOT EXISTS "${ccache_archive}")
      message(WARNING "Could not download ccache (${ccache_detail}); native packages build without it")
    endif()
  endif()
  if(NOT EXISTS "${TOOLS_DIR}/ccache" AND EXISTS "${ccache_archive}")
    extract_single_directory("${ccache_archive}" "${TOOLS_DIR}/ccache.unpacked")
    file(MAKE_DIRECTORY "${TOOLS_DIR}/ccache")
    file(RENAME "${TOOLS_DIR}/ccache.unpacked" "${TOOLS_DIR}/ccache/ccache-${CCACHE_VERSION}")
    file(COPY_FILE "${TOOLS_DIR}/ccache/ccache-${CCACHE_VERSION}/ccache.exe" "${TOOLS_DIR}/ccache/ccache.exe")
  endif()
  if(EXISTS "${TOOLS_DIR}/ccache/ccache.exe")
    execute_process(COMMAND "${TOOLS_DIR}/ccache/ccache.exe" --version RESULT_VARIABLE ccache_check OUTPUT_QUIET ERROR_QUIET)
    if(NOT ccache_check EQUAL 0)
      file(REMOVE_RECURSE "${TOOLS_DIR}/ccache")
      message(WARNING "ccache ${CCACHE_VERSION} does not run (${ccache_check}); native packages build without it")
    endif()
  endif()
endif()

run_checked("Native CMake configuration"
  "${CMAKE_COMMAND}" --preset "${native_preset}" -S "${HAXEON_ROOT}")
run_checked("Native build"
  "${CMAKE_COMMAND}" --build --preset "${native_preset}")
run_checked("Haxe version check" "${haxe_executable}" --version)
run_checked("HashLink version check" "${hashlink_executable}" --version)
run_checked("Formatter check" "${NODE_EXECUTABLE}" "${TOOLS_DIR}/formatter/run.js" --help)

message(STATUS "Haxeon toolchain is ready")
