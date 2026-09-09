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

# Initialize exact gitlinks first. The fallback is temporary support for the
# currently unreachable HashLink gitlink and can be removed once it is updated.
run_checked("Support submodule initialization"
  "${GIT_EXECUTABLE}" submodule update --init vendor/hashlink-debugger vendor/utest)
if(NOT EXISTS "${HAXEON_ROOT}/vendor/hashlink/.git")
  execute_process(
    COMMAND "${GIT_EXECUTABLE}" submodule update --init vendor/hashlink
    WORKING_DIRECTORY "${HAXEON_ROOT}"
    RESULT_VARIABLE submodule_status
  )
  if(NOT submodule_status EQUAL 0)
    message(WARNING "Recorded HashLink commit is unavailable; using haxeon/integrated-runtime")
    run_checked("HashLink integration-branch fetch"
      "${GIT_EXECUTABLE}" -C "${HAXEON_ROOT}/vendor/hashlink" fetch origin haxeon/integrated-runtime)
    run_checked("HashLink integration-branch checkout"
      "${GIT_EXECUTABLE}" -C "${HAXEON_ROOT}/vendor/hashlink" checkout FETCH_HEAD)
  endif()
endif()

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
  set(haxe_archive "${TOOLS_DIR}/haxe-${HAXE_VERSION}-win64.zip")
  set(haxe_url "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-win64.zip")
  set(haxe_sha256 "29f7acb0fb9fc66a2b9f6bd9453af3474ccb14ebd9fd0142f351d7311c4010c9")
  set(haxe_executable "${TOOLS_DIR}/haxe/haxe.exe")
  set(hashlink_executable "${TOOLS_DIR}/hashlink/hl.exe")
  set(native_preset "windows-msvc")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  set(haxe_archive "${TOOLS_DIR}/haxe-${HAXE_VERSION}-linux64.tar.gz")
  set(haxe_url "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-linux64.tar.gz")
  set(haxe_sha256 "a156b3d039daa572f1f9329870ee753e3c39b7514fe8c818069323579659acca")
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

run_checked("Native CMake configuration"
  "${CMAKE_COMMAND}" --preset "${native_preset}" -S "${HAXEON_ROOT}")
run_checked("Native build"
  "${CMAKE_COMMAND}" --build --preset "${native_preset}")
run_checked("Haxe version check" "${haxe_executable}" --version)
run_checked("HashLink version check" "${hashlink_executable}" --version)
run_checked("Formatter check" "${NODE_EXECUTABLE}" "${TOOLS_DIR}/formatter/run.js" --help)

message(STATUS "Haxeon toolchain is ready")
