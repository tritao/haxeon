set(_android_stage "${HAXEON_SDK_DIR}/platforms/android")
set(_web_stage "${HAXEON_SDK_DIR}/platforms/web")
add_custom_target(haxeon-platforms
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_android_stage}" "${_web_stage}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_SOURCE_DIR}/native/android/versions.txt" "${_android_stage}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_SOURCE_DIR}/stdlib/haxeon/wasm/haxeon-host.js" "${_web_stage}"
  VERBATIM)
add_dependencies(haxeon-sdk haxeon-platforms)

set(_android_sdk "$ENV{ANDROID_HOME}")
if(NOT _android_sdk)
  set(_android_sdk "$ENV{ANDROID_SDK_ROOT}")
endif()
if(NOT _android_sdk)
  set(_android_sdk "${CMAKE_SOURCE_DIR}/.tools/android-sdk")
endif()
# The Android host library needs the whole pinned toolchain (cmake/haxeon-android-toolchain.cmake installs it): an SDK
# with some other CMake or build tools, as CI runners have, would fail Gradle's checks. AUTO builds it when the toolchain
# is there and says what is missing otherwise; ON (release builds) makes a missing piece an error; OFF never builds it.
set(HAXEON_ANDROID AUTO CACHE STRING "Build the Android host library: AUTO, ON or OFF")
set_property(CACHE HAXEON_ANDROID PROPERTY STRINGS AUTO ON OFF)
file(STRINGS "${CMAKE_SOURCE_DIR}/native/android/versions.txt" _android_pins)
foreach(_pin IN LISTS _android_pins)
  if(_pin MATCHES "^([a-z-]+)=(.+)$")
    string(REPLACE "-" "_" _key "${CMAKE_MATCH_1}")
    set(_android_${_key} "${CMAKE_MATCH_2}")
  endif()
endforeach()
find_package(Java QUIET COMPONENTS Runtime)
set(_android_missing "")
if(NOT Java_FOUND)
  list(APPEND _android_missing "a Java runtime")
endif()
foreach(_path "ndk/${_android_ndk}/source.properties" "cmake/${_android_cmake}/bin/cmake"
    "build-tools/${_android_build_tools}" "platforms/android-${_android_platform}")
  if(NOT EXISTS "${_android_sdk}/${_path}")
    list(APPEND _android_missing "${_android_sdk}/${_path}")
  endif()
endforeach()
list(JOIN _android_missing ", " _android_missing_text)
if(HAXEON_ANDROID STREQUAL "OFF")
elseif(_android_missing AND HAXEON_ANDROID STREQUAL "ON")
  message(FATAL_ERROR "HAXEON_ANDROID=ON, but the pinned Android toolchain is incomplete: missing "
    "${_android_missing_text}. Install it with: cmake -P cmake/haxeon-android-toolchain.cmake")
elseif(_android_missing)
  message(STATUS "Android host library skipped: missing ${_android_missing_text} "
    "(cmake -P cmake/haxeon-android-toolchain.cmake installs it)")
else()
  add_custom_target(haxeon-android-sdk
    COMMAND "${CMAKE_COMMAND}" -E env "ANDROID_HOME=${_android_sdk}" "ANDROID_SDK_ROOT=${_android_sdk}"
      "${Java_JAVA_EXECUTABLE}" -classpath
      "${CMAKE_SOURCE_DIR}/templates/app/android/gradle/wrapper/gradle-wrapper.jar"
      org.gradle.wrapper.GradleWrapperMain -p "${CMAKE_SOURCE_DIR}/native/android"
      --max-workers=2 assembleRelease
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${CMAKE_SOURCE_DIR}/native/android/build/outputs/aar/haxeon-host-release.aar"
      "${_android_stage}/haxeon-host.aar"
    DEPENDS haxeon-platforms
    VERBATIM)
  add_dependencies(haxeon-sdk haxeon-android-sdk)
endif()
