# Android app builds

An Android app owns the Gradle runner written by `haxeon create`. The runner
depends on `platforms/android/haxeon-host.aar` in the Haxeon SDK. The AAR
contains the host activity and the HashLink VM with libffi for `arm64-v8a` and
`x86_64`. Its JNI entry calls the SDK's Android implementation of
`haxeon_app_run`.

## Staging the host

A toolchain-equipped SDK build stages the host AAR with `haxeon-sdk`. The build
uses the Android SDK in `ANDROID_HOME`, `ANDROID_SDK_ROOT` or the checkout's
`.tools/android-sdk`. `cmake -P cmake/haxeon-android-toolchain.cmake` installs
the toolchain pinned in [versions.txt](../../native/android/versions.txt) (the
platform, platform tools, build tools, NDK and CMake) into that SDK with its
`sdkmanager`; CI and the release workflow run the same script. The build also
needs a JDK supported by the pinned Gradle and Android Gradle plugin.
`scripts/android-env.sh` configures shell paths for a checkout-local
installation.

`HAXEON_ANDROID` decides whether the SDK build includes the host library:
`AUTO` (the default) builds it when the whole pinned toolchain and Java are
present and otherwise says what is missing, `ON` (release builds) makes a
missing piece a configure error, and `OFF` leaves it out.
`cmake --build --preset release --target haxeon-android-sdk` builds just the
Android part of the SDK. `haxeon dev package` copies the staged
`platforms/` tree into the release archive.

## Building the app

The CLI builds `build/android-arm64/app.hl` and its live sidecars, writes the
data-only native package fragment at `build/generated/android/haxeon.cmake`,
and copies `app.hl`, `app.hli`, `app.entry` and `app.hcs` into the generated
asset directory. It also writes `inputs.properties` in that directory's parent
for Gradle's configuration, with the asset and AAR paths and the `[app]`
metadata.

Gradle merges the app's manifest and resources, the generated assets and the
AAR. If the app has native packages, Gradle configures the runner's single
CMake graph with the NDK toolchain once per ABI. The graph adds the packages
in dependency order through the SDK's CMake package. Gradle packages the
resulting shared libraries with the app.

`haxeon build --target android --gradle-inputs build/generated/android/inputs.properties` prepares the inputs for
standalone Gradle or Android Studio builds. If you customize `outputDir`,
pass the path to the generated `inputs.properties` as Gradle's
`-PhaxeonInputs` property.

The watch loop compiles against the installed module's `.hcs` baseline and
forwards patches and reloads through adb. Gradle stays out of this edit loop.
