# Project builds: runner projects and one native graph per app

Status: step 1 is built for Linux: `haxeon create` writes `linux/`, `haxeon build` generates the fragment and builds the runner
with every native package in one graph, and `haxeon run` (with `--watch` and `--live`) runs the app's executable. The SDK the
runner links is Haxeon's SDK ([SDK_LAYOUT.md](SDK_LAYOUT.md)), found with `find_package(Haxeon)`, and the app's packages come
from the SDK's `haxeon` registry, so a created app builds from a release as from a checkout. Steps 2 to 6 are open. How an app is built for each platform: by platform projects the
app owns, which `haxeon` generates once and then drives, as Flutter does, instead of builds Haxeon runs out of sight. How apps consume Haxeon (the SDK, `find_package(Haxeon)`, the `haxeon` registry) is
[SDK_LAYOUT.md](SDK_LAYOUT.md).

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

## Apps and programs

A project is an **app** when its manifest has an `[app]` section, and a **program** otherwise:

```toml
[app]
name = "Hello"
id = "com.example.hello"        # reverse-domain: Android's applicationId, the macOS bundle identifier
version = "1.0.0"
icon = "assets/icon.png"
platforms = ["linux", "android", "web"]
```

- An app builds only through its runner projects (below), one per platform in `platforms`. `[app]` is the one place for
  what an app is: name, identifier, version, icon and platforms reach every runner through the generated fragment, so a
  runner holds platform glue only. `[android]`'s `applicationId` and `label` move into `[app]`; `[android]` keeps what is
  Android's alone.
- A program (a script, a command-line tool, a server, a package's tests) has no runner and builds as today: the module, the
  native packages from the shared cache, and Haxeon's VM.
- Building an app for a platform that is not in `platforms`, or whose runner directory is missing, is an error that names
  `haxeon create . --platforms PLATFORM`. A build never writes a runner.

## Creating projects

`haxeon create` makes projects and fills in what an existing one lacks; it replaces `haxeon init`, which stays one release
as an alias that names the new spelling.

```sh
haxeon create my_app                                  # a new directory, template app, the host's platform
haxeon create my_app --platforms linux,android,web --org com.example
haxeon create my_tool --template program
haxeon create . --platforms android                   # add a platform's runner to the project here
haxeon create .                                       # restore what is missing; never overwrite
```

- Templates: `app` (the default: a window with a counter, `[app]`, the runners, a test), `program` (a console program,
  today's `init`), `package` (a library with a `tests/` project), and `native-package` (a package wrapping a C library: a
  CMake project, a header, bindings made by `haxeon ffi import`, and a test that calls into C).
- `--org` gives the identifier's prefix (`com.example` and the name make `com.example.my_app`); `--platforms` lists the
  runners to write, by default the host's.
- In an existing project `create` adds the files and the `platforms` entries that are missing and leaves every existing
  file as it is; a runner that differs from its template is reported, not replaced.
- It prints the next commands (`cd my_app`, `haxeon run`, `haxeon run --watch --live`).
- Every template is created, built and run in CI, on each platform CI has.

## Runner projects

An app has one **runner project** per platform in `[app].platforms`, which `haxeon create` writes and the app owns and
commits:

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
- **Release builds** (`haxeon build --build-mode=release`) compile the program ahead of time: the compiler writes its C at
  `build/host/main.c/` (the build's `CModule` artifact), the fragment names that directory as `HAXEON_MODULE_C` instead of
  `HAXEON_MODULE`, and `haxeon_add_app` compiles it with the SDK's `haxeon_add_c_executable`, which adds the SDK's
  `hlc_main.c` and links the VM without the JIT (`Haxeon::aot`), through CMake and the user's toolchain, with the generated
  code's flags. The compiler rewrites only the C files whose text changed, so the runner recompiles only those. A release
  build cannot be watched or patched live. That function is the only build of generated C: `haxeon dev aot` and the AOT
  tests call it too, through `cmake/aot` ([AOT_BACKEND.md](AOT_BACKEND.md), Building the C).

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
too old is an error that names what to change. `haxeon create . --platforms PLATFORM --fresh-runner` writes the current
runner beside the old one (`linux.new/`) for the user to merge.

## What this replaces and what stays

- Replaced for apps: the hidden per-package native builds, the AOT driver's compile and link, the shared Android Gradle
  project, and the packages' own web scripts. Replaced for everyone: `haxeon init`, by `haxeon create`.
- Not needed: a build-system feature for native packages to find each other through install prefixes; one CMake graph
  gives it.
- Stays: the compiler, the compile server and live editing; the shared native cache for programs that are not apps;
  package publishing and the `haxeon` registry, which supply the sources the fragment names; NativeKit's changes to build
  the same core whatever is enabled (one graph needs that as well).

## Order

1. `haxeon create` with the `app` and `program` templates, the `[app]` section, the Linux runner and the generated
   fragment with native packages in one graph: `haxeon create hello` makes the counter app, which builds with `cmake` alone
   and with `haxeon build`, runs, and edits live.
2. Release builds through the runner (`--target hlc` sources in CMake). Done.
3. The Windows and macOS runners, checked by CI.
4. The Android runner per app, replacing the shared Gradle project.
5. The web runner.
6. Runner versions and `--fresh-runner`; the `package` and `native-package` templates; `[android]`'s app fields moved to
   `[app]`.

## Open

- Whether the Android host ships as an AAR in the release archive or is built from sources in the SDK on first use.
- The web loader: one for `wasm32` and `wasm-gc`, or one per target.
