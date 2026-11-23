# Android host

The first Android host embeds the HashLink runtime and the existing JIT
backends directly in `libhaxeon.so`; it does not translate Haxeon to JVM or
Android VM bytecode. `haxeon build --target android` compiles the project like
any other target, through the structured build and its compile server: the
module `build/android-arm64/app.hl`, with `app.hl.hli` (its runtime identity),
`app.hl.entry` (the stable ID of `main`) and `app.hl.hcs` (the compiler baseline
edits are compiled against), and the project's native libraries under
`build/android-arm64/jniLibs`. Gradle then only packages them, with the host,
for `arm64-v8a` and `x86_64`, and the CLI copies the APK to
`build/android/app-debug.apk`. `--plan`, `--explain`, `--timings` and
`--self-hosted` work as for the host; `--plan` and `--compiler-only` stop
before Gradle.

```sh
./scripts/haxeon init --target android
./scripts/haxeon build --target android
./scripts/haxeon run --target android [--device SERIAL]
```

Set `applicationId` and `label` in the manifest's `[android]` section to customize
the installed package name and launcher label. `run` installs the APK and
launches it on the selected device or the only online device. `haxeon devices`
lists connected devices.

Gradle can also run on its own, as Android Studio does. It then runs
`scripts/haxeon build --target android --gradle-inputs FILE` (`haxeon.cmd` on
Windows) for the project the `haxeonProject` Gradle property names, by default
the bundled demo (`android/demo/haxeon.toml`), and packages what that build
describes in `FILE`:

```sh
source scripts/android-env.sh
android/gradlew -p android assembleDebug [-PhaxeonProject=/path/to/haxeon.toml]
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The host keeps one Haxeon runtime module alive and serves a loopback patch
port. `run --watch` installs and launches the app as `run` does, forwards that
port through `adb`, then sends each saved edit to the running app without
rebuilding the APK:

```sh
./scripts/haxeon run --target android --watch [--device SERIAL]
```

Each edit is compiled by the structured build, in the compile server that
built the module, against the compiler baseline the device's module was built
from (`build/android-arm64/app.hl.hcs`), into `build/android-arm64/edit/`. A
body edit becomes a patch the running module applies; a structural edit (a new
function, a changed signature or layout) becomes a domain reload bundle, which
replaces the loaded HLB module and HLI manifest only after the new module
initializes and its `main` call succeeds. The host runs `main` again after
either. The new baseline is kept only when the device acknowledges the edit, so
after a compile error or a rejected edit the next one is still compiled against
what the device runs.

The local Android SDK, NDK, CMake, Gradle, and emulator are kept under
`.tools/`. The CLI configures these paths automatically. Source
`scripts/android-env.sh` when using `adb`, `emulator`, or Gradle directly. The
disposable API 36 emulator used for the smoke test is named
`haxeon-api36-x86_64`.

