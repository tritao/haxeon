#!/usr/bin/env bash

# Source this file before Android builds:
#   source scripts/android-env.sh

android_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The tool versions, shared with `haxeon` (HaxeonCli.androidVersion) and android/app/build.gradle.
while IFS='=' read -r android_key android_value; do
	case "$android_key" in
		ndk) android_ndk="$android_value" ;;
		build-tools) android_build_tools="$android_value" ;;
		cmake) android_cmake="$android_value" ;;
		gradle) android_gradle="$android_value" ;;
	esac
done < "$android_root/native/android/versions.txt"

export ANDROID_SDK_ROOT="$android_root/.tools/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$android_ndk"
export ANDROID_AVD_HOME="$android_root/.tools/android-avd"

export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/build-tools/$android_build_tools:$ANDROID_SDK_ROOT/cmake/$android_cmake/bin:$android_root/.tools/gradle/gradle-$android_gradle/bin:$PATH"
