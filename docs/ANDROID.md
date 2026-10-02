# Android host

The first Android host embeds the HashLink runtime and the existing JIT
backends directly in `libhaxeon.so`; it does not translate Haxeon to JVM or
Android VM bytecode. Gradle generates a small `.hl` asset and packages the
host for `arm64-v8a` and `x86_64`. The project CLI sends its manifest to Gradle
and copies the resulting APK to `build/android/app-debug.apk`:

```sh
./scripts/haxeon init --target android
./scripts/haxeon build --target android
./scripts/haxeon run --target android [--device SERIAL]
```

Set `android.applicationId` and `android.label` in `haxeon.json` to customize
the installed package name and launcher label. `run` installs the APK and
launches it on the selected device or the only online device. `haxeon devices`
lists connected devices.

For the bundled demo, Gradle can still be called directly:

```sh
source scripts/android-env.sh
./scripts/build-android.sh assembleDebug
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The host keeps one Haxeon runtime module alive and exposes a loopback patch
port forwarded through `adb`. After changing `android/demo/Main.hx`, compile
and send a compatible body patch without rebuilding the APK:

```sh
./scripts/build-android-patch.sh
./scripts/android-send-patch.sh
```

The patch compiler stages a new baseline beside `android/app/src/main/assets/app.hcs`;
the send command promotes it only after the device acknowledges the patch.
Structural edits are sent as a full domain reload, still without rebuilding the
APK:

```sh
./scripts/build-android-reload.sh
./scripts/android-send-reload.sh
```

The reload bundle replaces the loaded HLB module and HLI manifest only after
the new module initializes and its `main` call succeeds. Its staged compiler
baseline is promoted only after the device acknowledges the replacement.

The local Android SDK, NDK, CMake, Gradle, and emulator are kept under
`.tools/`. The CLI configures these paths automatically. Source
`scripts/android-env.sh` when using `adb`, `emulator`, or Gradle directly. The
disposable API 36 emulator used for the smoke test is named
`haxeon-api36-x86_64`.

