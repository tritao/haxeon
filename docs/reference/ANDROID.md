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

The host keeps one Haxeon runtime module alive and serves a loopback patch
port. `run --watch` installs and launches the app as `run` does, forwards that
port through `adb`, then sends each saved edit to the running app without
rebuilding the APK:

```sh
./scripts/haxeon run --target android --watch [--device SERIAL]
```

Each edit is compiled against the compiler baseline the device's module was
built from (`android/app/src/main/assets/app.hcs`). A body edit becomes a patch
the running module applies; a structural edit (a new function, a changed
signature or layout) becomes a domain reload bundle, which replaces the loaded
HLB module and HLI manifest only after the new module initializes and its
`main` call succeeds. The host runs `main` again after either. The new baseline
is kept only when the device acknowledges the edit, so after a compile error or
a rejected edit the next one is still compiled against what the device runs.
`tools.AndroidBuild edit` is the compile step on its own (see its header).

The local Android SDK, NDK, CMake, Gradle, and emulator are kept under
`.tools/`. The CLI configures these paths automatically. Source
`scripts/android-env.sh` when using `adb`, `emulator`, or Gradle directly. The
disposable API 36 emulator used for the smoke test is named
`haxeon-api36-x86_64`.

