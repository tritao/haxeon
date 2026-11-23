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
# The host library builds only with the whole pinned toolchain: an SDK with some
# other CMake or build tools (a CI runner's, say) would fail Gradle's checks.
foreach(_part ndk cmake build-tools)
  file(STRINGS "${CMAKE_SOURCE_DIR}/native/android/versions.txt" _version REGEX "^${_part}=")
  string(REGEX REPLACE "^${_part}=" "" _android_${_part} "${_version}")
endforeach()
find_package(Java QUIET COMPONENTS Runtime)
set(_android_missing "")
if(NOT Java_FOUND)
  list(APPEND _android_missing "a Java runtime")
endif()
foreach(_path "ndk/${_android_ndk}/source.properties" "cmake/${_android_cmake}/bin/cmake"
    "build-tools/${_android_build-tools}")
  if(NOT EXISTS "${_android_sdk}/${_path}")
    list(APPEND _android_missing "${_android_sdk}/${_path}")
  endif()
endforeach()
if(_android_missing)
  list(JOIN _android_missing ", " _android_missing)
  message(STATUS "Android host library skipped: missing ${_android_missing} (pins in native/android/versions.txt)")
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
