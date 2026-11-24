# Installs the Android toolchain pinned in native/android/versions.txt (platform, build tools, NDK, CMake) with the
# SDK's sdkmanager, for building the Android host library and Android apps:
#
#   cmake -P cmake/haxeon-android-toolchain.cmake
#
# from a checkout or an installed Haxeon (the SDK ships it in cmake/), into ANDROID_HOME (or ANDROID_SDK_ROOT), else
# .tools/android-sdk beside it, where scripts/android-env.sh and `haxeon` look.
# The SDK needs its command-line tools (cmdline-tools/latest, from Android Studio's SDK Manager or developer.android.com).
cmake_minimum_required(VERSION 3.24)

get_filename_component(root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
# The pins: native/android in a checkout, platforms/android in an SDK.
set(versions "${root}/native/android/versions.txt")
if(NOT EXISTS "${versions}")
  set(versions "${root}/platforms/android/versions.txt")
endif()
file(STRINGS "${versions}" pins)
foreach(pin IN LISTS pins)
  if(pin MATCHES "^([a-z-]+)=(.+)$")
    string(REPLACE "-" "_" key "${CMAKE_MATCH_1}")
    set(pinned_${key} "${CMAKE_MATCH_2}")
  endif()
endforeach()

set(sdk "$ENV{ANDROID_HOME}")
if(NOT sdk)
  set(sdk "$ENV{ANDROID_SDK_ROOT}")
endif()
if(NOT sdk)
  set(sdk "${root}/.tools/android-sdk")
endif()

if(CMAKE_HOST_WIN32)
  set(sdkmanager "${sdk}/cmdline-tools/latest/bin/sdkmanager.bat")
else()
  set(sdkmanager "${sdk}/cmdline-tools/latest/bin/sdkmanager")
endif()
if(NOT EXISTS "${sdkmanager}")
  message(FATAL_ERROR "No sdkmanager at ${sdkmanager}: install the Android command-line tools into ${sdk} "
    "(Android Studio's SDK Manager, or https://developer.android.com/studio#command-line-tools-only), "
    "or set ANDROID_HOME to an SDK that has them.")
endif()

message(STATUS "Installing the pinned Android toolchain into ${sdk}")
# sdkmanager asks to accept each licence; the toolchain cannot install without them.
string(REPEAT "y\n" 20 accept)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/android-licences.txt" "${accept}")
execute_process(COMMAND "${sdkmanager}" "--sdk_root=${sdk}" --licenses
  INPUT_FILE "${CMAKE_CURRENT_BINARY_DIR}/android-licences.txt" OUTPUT_QUIET RESULT_VARIABLE result)
file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/android-licences.txt")
if(NOT result EQUAL 0)
  message(FATAL_ERROR "sdkmanager --licenses failed (${result})")
endif()
execute_process(COMMAND "${sdkmanager}" "--sdk_root=${sdk}" --install platform-tools
    "platforms;android-${pinned_platform}" "build-tools;${pinned_build_tools}" "ndk;${pinned_ndk}"
    "cmake;${pinned_cmake}"
  RESULT_VARIABLE result)
if(NOT result EQUAL 0)
  message(FATAL_ERROR "sdkmanager --install failed (${result})")
endif()
