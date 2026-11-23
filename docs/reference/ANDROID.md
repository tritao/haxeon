# Android apps

Create an app with an Android runner and build or run it from its directory.

```sh
haxeon create my_app --platforms android
cd my_app
haxeon build --target android
haxeon devices
haxeon run --target android --device SERIAL
```

Set `ANDROID_HOME` to the Android SDK. In a checkout, Haxeon also looks in
`.tools/android-sdk`. Run `haxeon doctor` to check the SDK, NDK, adb, and
Haxeon host AAR. For a checkout, see `docs/design/ANDROID_BUILD.md` for the Android toolchain and host build.

The app owns `android/`, including the Gradle project, manifest and resources.
Set the application ID, launcher label and version using `id`, `name` and
`version` in `[app]`. Use a `main():Void` entry point on Android.

The CLI builds a debug APK at `build/android/app-debug.apk`, with support for
`arm64-v8a` and `x86_64`. To assemble it in Android Studio or directly with
Gradle, prepare the inputs after editing the Haxe sources or manifest.

```sh
haxeon build --target android --gradle-inputs build/generated/android/inputs.properties
sh android/gradlew -p android assembleDebug
```

The Gradle output is `android/app/build/outputs/apk/debug/app-debug.apk`. The
app's Gradle project is where signing and release packaging belong.

## Live editing

`haxeon run --target android --watch` installs and launches the APK once, then
forwards edits over adb to the device's patch listener. The Android host keeps
the runtime and applies compatible edits to it. An edit requiring a reload sends
a replacement module. Use `--device SERIAL` to choose among connected devices.
Rebuild the APK after changes to the Android runner or its native packages.

`haxeon build --target android --plan` prints the module build and its live
metadata without invoking Gradle. `--compiler-only` builds just the module and
its sidecars. See [Live patching](LIVE_PATCHING.md) for the runtime model.

## Checking on CI

The **Android app on emulator** job creates an app with the Android runner,
builds its debug APK, and checks that the Android host draws a frame. It then
checks that the device applies a body patch and a structural reload in the same
app process. The job runs the check outside the standard test suites because it
needs a booted Android device.

To run the same check from a checkout, set `ANDROID_HOME` to the toolchain SDK
or source `scripts/android-env.sh` for a checkout-local SDK, and install the
pinned toolchain into it with `cmake -P cmake/haxeon-android-toolchain.cmake`. Build and stage
Haxeon, then run the check with a booted, unlocked device or emulator visible
in `adb devices`.

```sh
scripts/build-native.sh
tests/integration/test-android-app.sh
```

Set `ANDROID_SERIAL` if more than one device is online. The script removes
its temporary app and stops its watch session when it exits.
