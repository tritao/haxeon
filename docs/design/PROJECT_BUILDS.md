# Project builds: runner projects and one native graph per app

Status: agreed direction (2026-11-22); nothing built yet. How an app is built for each platform: by platform projects the
app owns, which `haxeon` generates once and then drives, as Flutter does, instead of builds Haxeon runs out of sight.

## Problem

`haxeon build` does everything itself, and none of it is a project a user can open, change or build without it:

| Target | Today |
|---|---|
| Desktop, development | The compiler writes `build/host/main.hl`; each native package's CMake project is configured and built by Haxeon in a shared cache (`build.native.NativeCMakeProvider`, `NativeCache`) and its libraries copied to `build/host/native/<package>/`; `haxeon run` starts Haxeon's own VM on the module with the library path set. There is no app executable, icon or package to ship. |
| Desktop, ahead of time (`--target hlc`) | The compiler writes C, and a driver of Haxeon's own calls `cc`, `clang-cl` or `cl` per file and links the SDK's `libhl` (`AOT_BACKEND.md`). No project for an IDE or a debugger. |
| Android | Haxeon builds the module and native libraries, then the Gradle project inside the Haxeon checkout (`android/`) packages them, pointed at the app by a property (`reference/ANDROID.md`). The Android project is not the app's. |
| Web | The compiler writes a `.wasm`; the page that hosts it, and native code built with Emscripten, come from each package's own scripts (`packages/ui/tools/build-web.sh`, `web_shell.html`). |

Changing an app's icon, its Android manifest, a link flag or its web page means changing Haxeon. Native packages build in a
hidden cache, one CMake project at a time, so a package cannot use another's targets.

## Model

An app has one **runner project** per platform, which `haxeon init --template app` writes and the app owns and commits:

```
app/
  haxeon.toml
  src/Main.hx
  linux/  windows/  macos/      CMake: a small C main, the app's name, icon, version and packaging
  android/                      Gradle: the app's manifest and resources; Haxeon's Android host as a library
  web/                          index.html and the loader
  ios/                          later (iOS is planned)
```

`haxeon build` compiles the Haxe code and writes a **generated fragment** that the runner includes, then runs the
platform's own build:

```
build/generated/<platform>/
  haxeon.cmake        the module (or the AOT C sources), the runtime, and every native package, in dependency order
  haxeon-runner.txt   the runner version this fragment is for
```

So `cmake -S linux -B build/linux && cmake --build build/linux` builds the app without `haxeon`, an IDE opens `linux/`
(or `android/` in Android Studio) as an ordinary project, and `haxeon build` is a convenience over the same steps.

## Desktop runner

`linux/`, `windows/` and `macos/` are CMake projects of a few dozen lines: `project(...)`, `include(haxeon.cmake)` from
the generated directory, one `add_executable` for the runner's `main.c`, and the platform's packaging (an icon resource on
Windows, an `.app` bundle on macOS, a desktop file on Linux). The runner's `main` is Haxeon's, kept in the SDK; the runner
project only names it.

- **Development builds** link the VM and load the module (`main.hl`) beside the executable. The live host is the same
  executable, so `haxeon run --watch --live` patches the running app as today.
- **Release builds** compile the generated C of `--target hlc` with the VM library, through CMake and the user's toolchain.
  That replaces the private driver's per-file compile and link for apps; the driver stays for `haxeon` itself and scripts.

## One native graph per app

`haxeon.cmake` adds each native package's CMake project with `add_subdirectory`, dependencies first, in one build. A
package uses the targets of the packages it depends on directly: the UI package's CMake links `NativeKit::nativekit`,
which the `nativekit` package's project defined earlier in the same graph. Each library is built once and linked once,
and CMake, not Haxeon, decides what to rebuild.

- A package's `[native.cmake]` keeps its meaning: its CMake source and the targets the app's runtime loads.
- Packages come from wherever resolution put them (a path in this repository, the registry cache, a Git checkout); the
  fragment names their directories.
- Rebuilding NativeKit for each app costs about a minute the first time; `ccache`, which builds already use, takes most of
  it away afterwards.

Programs that are not apps (scripts, package tests, `haxeon run` of a plain program) have no runner and keep today's path:
the shared native cache and the VM in Haxeon's home.

## Android runner

`android/` is a Gradle project of the app: its `AndroidManifest.xml`, resources and `build.gradle`, depending on
Haxeon's Android host as a library (an AAR in the SDK). Native code builds through `externalNativeBuild` with the same
generated `haxeon.cmake`, once per ABI, with the NDK's CMake toolchain. The module and its live-editing files
(`app.hl`, `.hli`, `.entry`, `.hcs`) are generated assets. The Gradle project inside the Haxeon checkout becomes the
template for this one, and `-PhaxeonProject` goes.

## Web runner

`web/` holds `index.html` and the loader script: the page, its canvas and its fonts are the app's. The fragment for the web
builds native packages with Emscripten's CMake toolchain (`emcmake`), and the loader instantiates the module with them.

## Runner versions

A runner is written once and then the app's, so a later Haxeon must not silently need a different one. The runner keeps
as little as it can: the main, the build logic and the platform glue live in the SDK and the generated fragment. It
records the runner version it was written from, and `haxeon build` checks the fragment's against it: a runner that is
too old is an error that names what to change, and `haxeon init --runner PLATFORM` writes a fresh one beside the old for
the user to merge.

## What this replaces and what stays

- Replaced for apps: the hidden per-package native builds, the AOT driver's compile and link, the shared Android Gradle
  project, and the packages' own web scripts.
- Not needed: a build-system feature for native packages to find each other through install prefixes; one CMake graph
  gives it.
- Stays: the compiler, the compile server and live editing; the shared native cache for programs that are not apps;
  package publishing and the `haxeon` registry, which supply the sources the fragment names; NativeKit's changes to build
  the same core whatever is enabled (one graph needs that as well).

## Order

1. The Linux runner and the generated fragment, with native packages in one graph; `haxeon init --template app` writes
   `linux/`, and the counter app builds with `cmake` alone and with `haxeon build`, and edits live.
2. Release builds through the runner (`--target hlc` sources in CMake).
3. The Windows and macOS runners, checked by CI.
4. The Android runner per app, replacing the shared Gradle project.
5. The web runner.
6. Runner versions and `haxeon init --runner`.

## Open

- Where the runner's `main` lives in the SDK, and whether development and release use one `main` with a define.
- Whether the Android host ships as an AAR in the release archive or is built from sources in the SDK on first use.
- The web loader: one for `wasm32` and `wasm-gc`, or one per target.
