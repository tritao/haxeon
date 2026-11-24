# Android apps

Create an app with an Android runner and build or run it from its directory.

```sh
haxeon create my_app --platforms android
cd my_app
haxeon build --target android
haxeon devices
haxeon run --target android --device SERIAL
```

Set `ANDROID_HOME` to the Android SDK. Run `haxeon doctor` to check the SDK, NDK, adb and Haxeon host AAR.

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
