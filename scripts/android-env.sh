#!/usr/bin/env bash

# Source this file before Android builds:
#   source scripts/android-env.sh

android_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export ANDROID_SDK_ROOT="$android_root/.tools/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/30.0.16248370"
export ANDROID_AVD_HOME="$android_root/.tools/android-avd"

export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/build-tools/36.0.0:$ANDROID_SDK_ROOT/cmake/3.30.5/bin:$android_root/.tools/gradle/gradle-9.5.0/bin:$PATH"
