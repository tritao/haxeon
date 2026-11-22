# Android build: haxeon compiles, Gradle packages

Status: implemented. Follows step 3.2 (`f2e1ac92`), which gave Android the project's `CompilerInputs`.

## Problem

Android was the last target with its own compile. Gradle's `generateHaxeonAsset` task ran `tools.AndroidBuild` under the
pinned Haxe interpreter, which compiled `app.hl` in-process. It read the same `CompilerInputs` as every other build, but it
bypassed the compile server, warm reuse, the action fingerprints and `--plan`/`--explain`/`--timings`/`--self-hosted`. Its
reason to exist was the compiler baseline (`.hcs`) live patching needs, which is just one more output of a HashLink compile.

## Design

The call is inverted. `haxeon build --target android` runs the structured build (`HaxeonProjectBuild`) for the Android target
like any other: the planner plans the project's native libraries and its HashLink module, and `CompilerProvider` compiles the
module through the project's compile server. Gradle then only packages what that build produced.

An Android module is always compiled live (`--live`, development metadata), because the debug host patches it, and it
declares two outputs beyond a host module's:

| Output | Written by | Read by |
|---|---|---|
| `build/android-arm64/app.hl` | the compiler | Gradle (asset `app.hl`) |
| `app.hl.hli` | the compiler (as for every HashLink module) | Gradle (asset `app.hli`) |
| `app.hl.entry` | `--entry-id-output`: the stable ID of `main():Void`, checked before anything is written | Gradle (asset `app.entry`) |
| `app.hl.hcs` | `--baseline-output`: the identity state after the module is published | `haxeon run --watch` |
| `jniLibs/<abi>/lib*.so` | the native providers (NDK) | Gradle (jniLibs) |

`.hcs` stays on the host: the device never reads it, so it is no longer packaged. Every Android output lives under the
target's directory (`<outputDir>/android-arm64/`, `TargetLayout`); the APK is still copied to `build/android/app-debug.apk`.

The cold bytes are the old path's: `app.hl` and `.entry` are byte-identical, and `.hcs` and `.hli` differ only in the random
module identity (`.hcs` bytes 5-8 and 13-16). A warm server builds on its live history instead, so a later `app.hl` can differ
from a cold one; the `.hcs` written beside it always describes that `app.hl`.

### What Gradle reads

The build describes the outputs to Gradle in a Java properties file (`module`, `identity`, `entry`, `nativeRoot`; absolute
paths). The `packageHaxeon` task copies them into `app/build/generated/haxeon/{assets,jniLibs}` under the names the host
loads, and registers both directories as generated sources of every variant, so AGP's merge tasks depend on it.

- **Run by the CLI.** `haxeon build --target android` builds, writes `build/android-arm64/app.hl.gradle.properties`, and runs
  `assembleDebug` with `-PhaxeonInputs=<that file>` (and the application ID and label). Gradle's `buildHaxeon` task is skipped.
- **Run on its own** (Android Studio, `./gradlew` in `android/`). Without `haxeonInputs`, the
  `buildHaxeon` task runs `haxeon build --target android --project <haxeonProject> --gradle-inputs
  app/build/haxeon/inputs.properties`, which builds and describes but never starts Gradle, so the two cannot recurse. The task
  always runs; haxeon's own fingerprints make a build with nothing changed cheap.

### How Gradle finds haxeon

Gradle's `android/` project lives inside the Haxeon checkout, so `haxeonRoot` is its parent directory. The command is
`<haxeonRoot>/scripts/haxeon` (`haxeon.cmd` on Windows), which brings the CLI up to date and runs it; the `haxeonCommand`
Gradle property replaces it, for instance with an installed `haxeon`. The project is the `haxeonProject` property (in
`gradle.properties`, `~/.gradle/gradle.properties` or `-P`), by default the bundled demo, which is now a project of its own
(`android/demo/haxeon.toml`; its outputs go to `android/demo/build/`, which is ignored).

Android Studio's sync only configures the project, which needs neither haxeon nor its outputs; haxeon runs when a build runs.
`haxeonApplicationId` and `haxeonAppLabel` are configuration-time properties as before: standalone Gradle uses the defaults
unless they are set, since the manifest is read only by haxeon.

### Patch baseline

`haxeon run --target android --watch` builds (writing `app.hl.hcs`), installs and launches, then compiles each edit through
the same structured build with `LoweringContext.baseline` set: `CompilerProvider` adds `--baseline=app.hl.hcs` and the
baseline becomes an action input. The edit's outputs go to `build/android-arm64/edit/app.hl`; `AndroidWatch` reads its
`.live.json` and sends `.hlp` (a patch) or an HXR bundle of the module, `.hli` and `.entry` (a reload). When the device
acknowledges it, `edit/app.hl.hcs` replaces `app.hl.hcs`; otherwise it is dropped, so the next edit is compiled against what
the device runs.

The compiler session (`CompilerSession`) remembers the digest of the last baseline it wrote. A request whose baseline is that
one builds on the session, which already holds that state, so edits are warm, starting with the first one after the build.
Any other baseline (the device rejected an edit, the worker restarted, another compiler wrote it) resets the session and loads
the file, which is what the old tool did for every edit. Both produce the same patch. A baseline request records no live
history (`.live.state`): it resumes from its baseline.

### Offline and without an SDK

The compile needs no Android SDK: a project without native code builds its module, sidecars and Gradle inputs anywhere
(`test-haxeon-cli.sh` does this on every CI host). Native packages need the NDK, which the CLI points at
`.tools/android-sdk` (`configureAndroidEnvironment`) as before. Packaging needs the SDK and Gradle; the CLI refuses to start
Gradle when `.tools/android-sdk` or the wrapper is missing. Dependency resolution is the project's, as for any target: with a
lockfile and a populated source cache it needs no network. Gradle itself needs its plugins and dependencies in its cache, or
the network, as before; nothing here adds a download.

## Migration

`haxeon init --target android` writes only `haxeon.json` (with its `android` section) and `src/`; Android projects have no
generated Gradle files of their own. The Gradle project is Haxeon's `android/`, so updating the checkout updates it, and
existing projects need no change. What changes for someone who drove the pieces by hand:

- `tools.AndroidBuild` is gone. `haxeon build --target android --gradle-inputs FILE` builds what it built; the edit step is
  part of `haxeon run --target android --watch`.
- Gradle's `generateHaxeonAsset` task is now `buildHaxeon` + `packageHaxeon`. `-PhaxeonProject` still selects the project;
  `-PhaxeonNativeRoot` is replaced by the `nativeRoot` entry of the inputs file.
- The baseline moved from `android/app/src/main/assets/app.hcs` to the project's `build/android-arm64/app.hl.hcs`. Files the
  old task left in `android/app/src/main/assets/` would be packaged twice, so `packageHaxeon` deletes them. A device running a
  module from the old path is reinstalled by the next `haxeon run`, which writes the new baseline.
- The demo builds into `android/demo/build/`.

## Not done

- `haxeon build --target android` builds the native libraries for `android-arm64` only, as before; the APK's `x86_64` host has
  no project natives.
- The pending baseline is promoted by `AndroidWatch`, outside the compiler; a rejected edit leaves the server session at a
  revision the device does not run until the next edit reloads the baseline. A protocol in which the compiler learns the
  device's revision (as `LiveRefusal` does for the desktop live host) would let the session take the edit back instead.
