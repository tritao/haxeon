# Project builds: runner projects and one native graph per app

Status: steps 1 to 3 are built: `haxeon create` writes `linux/`, `macos/` or `windows/`, `haxeon build` generates the fragment
and builds the runner with every native package in one graph, in development or release mode, and `haxeon run` (with `--watch`,
patching or restarting) runs the app's executable; CI creates, builds and runs the app on Linux, macOS and Windows. The SDK the
runner links is Haxeon's SDK ([SDK_LAYOUT.md](SDK_LAYOUT.md)), found with `find_package(Haxeon)`, and the app's packages come
from the SDK's `haxeon` registry, so a created app builds from a release as from a checkout. Steps 4 and 5 have runners. Android packaging and device checks need a toolchain-equipped build. Web native packages and step 6 are open. How an app is built for each platform: by platform projects the
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

A project is an **app** when its manifest has an `[app]` section, and a **console program** (a program, for short) otherwise:

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

`haxeon create` makes projects and fills in missing files.

```sh
haxeon create my_app                                  # a new directory, template app, every platform with a runner
haxeon create my_app --platforms linux,android,web --org com.example
haxeon create my_tool --template console
haxeon create android_app --platforms android         # create only the Android runner
haxeon create .                                       # restore what is missing; never overwrite
```

- Templates: `app` (the default: a window with a counter, `[app]`, the runners, a test), `console` (a console program,
  a managed entry point), `package` (a library with a `tests/` project), and `native-package` (a package wrapping a C library: a
  CMake project, a header, bindings made by `haxeon ffi import`, and a test that calls into C).
- `--org` gives the identifier's prefix (`com.example` and the name make `com.example.my_app`); `--platforms` lists the
  runners to write, by default every one the template has (a project made on one machine builds on the others as it
  is, as Flutter's create does; Android and web are included).
- In an existing project `create` adds the files and the `platforms` entries that are missing and leaves every existing
  file as it is; a runner that differs from its template is reported, not replaced.
- It prints the next commands (`cd my_app`, `haxeon run`, `haxeon run --watch`).
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
the generated directory, `find_package(Haxeon)`, one `haxeon_add_app`, and the platform's packaging (version and icon
resources on Windows, the `.app` bundle's Info.plist on macOS, a desktop file on Linux).

**Entry points belong to the SDK, never the runner.** The SDK's `src/haxeon_app.c` has the platform's entries: `main` on
Linux and macOS; on Windows both `wmain` and `wWinMain`, of which the linker starts the one of the executable's subsystem.
Each calls one function, `haxeon_app_run(argc, argv)`, defined once per flavour of the program: the JIT VM loading the
app's module (`libhaxeon-app`, a development build) or the program compiled ahead of time (`hlc_main.c`, a release build),
which `haxeon_add_app` picks from the fragment. Android's JNI start and the web loader's export will be further entries
calling the same function, so a runner never carries start-up code an SDK update would have to reach.

- **Development builds** link the VM and load the module (`main.hl`) beside the executable. The live host is the same
  executable, so `haxeon run --watch` patches the running app as today.
- **Release builds** (`haxeon build --build-mode=release`) compile the program ahead of time: the compiler writes its C at
  `build/host/main.c/` (the build's `CModule` artifact), the fragment names that directory as `HAXEON_MODULE_C` instead of
  `HAXEON_MODULE`, and `haxeon_add_app` compiles it with the SDK's `haxeon_add_c_executable`, which adds the SDK's
  `hlc_main.c` and links the VM without the JIT (`Haxeon::aot`), through CMake and the user's toolchain, with the generated
  code's flags. The compiler rewrites only the C files whose text changed, so the runner recompiles only those. A release
  build cannot be watched or patched live. That function is the only build of generated C: `haxeon dev aot`, the AOT
  tests and a console program's release build call it too, through `cmake/aot` ([AOT_BACKEND.md](AOT_BACKEND.md),
  Building the C).
- **A console program's release build** has no runner, so the build graph itself configures the SDK's `cmake/aot` in
  `build/<platform>/` and builds the executable into `build/<platform>/bin/`, the directory to ship (`ConsoleProgram`).
  Its native packages are the ones the graph already built for the program; they are not built again in a second CMake
  graph, as an app's runner must so that it builds with `cmake` alone. One publish step copies their libraries beside the
  executable, which finds them through `$ORIGIN` (`@executable_path` on macOS, the executable's directory on Windows).

Where each platform puts the app (`haxeon_add_app`, `cmake/sdk/HaxeonApp.cmake`), all in `build/<platform>/app/`:

- **Linux:** the executable, its module (`<name>.hl`) and the native packages' libraries together, found through `$ORIGIN`.
- **macOS: an `.app` bundle from the start**, `<name>.app`, not a plain executable first. A macOS app is a bundle: the Dock,
  the menu bar's name and anything that reads the main bundle's identifier need one (NativeKit's notifications refuse to run
  without it), and moving from a plain executable later would change the paths `haxeon run`, the tests and users rely on.
  The executable is in `Contents/MacOS`, the module in `Contents/Resources` (code signing wants only code in `MacOS`; the
  app's entry looks there when it runs from a bundle), the libraries in `Contents/Frameworks`, found through
  `@executable_path/../Frameworks`. The runner's `Info.plist.in` is the bundle's Info.plist, filled from `[app]`'s name,
  identifier and version. The build signs nothing: the linker's ad-hoc signature runs it on this machine, JIT included, as
  the hardened runtime is off; signing for others and notarizing belong to packaging.
- **Windows:** the native packages' DLLs beside the `.exe`, where the loader looks first (the `nativekit` package sends
  NativeKit's DLLs there too, which NativeKit itself puts in a `bin/` of its own). **A Windows program (the `WIN32`
  subsystem), in development and release builds alike,** as Flutter's runner is: an app started from Explorer or Start opens
  no console window, which a console program would, and the subsystem is the SDK's (`haxeon_add_app` sets
  `WIN32_EXECUTABLE`), so a runner written before a change gets it. No manifest field or `create` option chooses: an `[app]`
  is a GUI app on every platform, and a console program is the `console` template; an app that wants a console window of
  its own (a log window, a server) sets `WIN32_EXECUTABLE` off in its runner, after `haxeon_add_app`, as the runner's
  comment shows. A Windows program has no standard output of its own, so `wWinMain` keeps the handles it inherited (the pipes
  `haxeon run` and the tests give it, which carry its output, while its exit status is waited for as any process's), and
  otherwise attaches the console of the terminal that started it, or under a debugger a console of its own, and reopens
  `stdout` and `stderr` there. `cmd.exe` does not wait for a Windows program, so its prompt returns while the app runs;
  PowerShell and other shells that wait for their children are unaffected. MSVC, not MinGW: the SDK's Windows libraries are MSVC's (`HaxeonConfig.cmake` selects
  `lib/windows-<arch>-msvc` for MSVC, `-gnu` for a GNU compiler, which an SDK built with MinGW would provide), so
  `haxeon build` loads MSVC's developer environment and names `cl`, whatever compiler comes first on `PATH`; plain CMake
  builds it from a developer prompt. The runner's `app.rc.in` (version information from `[app]`, and the icon) and
  `app.manifest` (supported Windows versions, per-monitor DPI awareness, the current common controls) are compiled in.

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
Haxeon's Android host as a library: a prebuilt AAR in the SDK (`platforms/android/`), with the VM for each ABI, as the
desktop runners link the SDK's prebuilt `libhaxeon-app`. An AAR is how Android libraries are distributed, and building the
host from sources on first use would ship its sources and make the first build need the NDK and take minutes. Native code builds through `externalNativeBuild` with the same
generated `haxeon.cmake`, once per ABI, with the NDK's CMake toolchain. The module and its live-editing files
(`app.hl`, `.hli`, `.hcs`) are generated assets; the host finds `main` by name. The Gradle project inside the Haxeon checkout becomes the
app template. The SDK builds the host AAR from `native/android` when the Android toolchain is available.

## Web runner

`web/` owns the page, canvas and fonts. Its build stages the page, module and the SDK's `platforms/web/haxeon-host.js`
under `build/web/<target>/`. Both Wasm targets use the same host. Apps with native packages still need an Emscripten
graph and host integration, tracked in [TODO.md](../../TODO.md).

## Runner versions

A runner is written once and then the app's, so a later Haxeon must not silently need a different one. The runner keeps
as little as it can: the main, the build logic and the platform glue live in the SDK and the generated fragment. It
records the runner version it was written from, and `haxeon build` checks the fragment's against it: a runner that is
too old is an error that names what to change. `haxeon create . --platforms PLATFORM --fresh-runner` writes the current
runner beside the old one (`linux.new/`) for the user to merge.

## What this replaces and what stays

- Replaced for apps: the hidden per-package native builds, the AOT driver's compile and link, the shared Android Gradle
  project, and the packages' own web scripts. Project creation uses `haxeon create`.
- Not needed: a build-system feature for native packages to find each other through install prefixes; one CMake graph
  gives it.
- Stays: the compiler, the compile server and live editing; the shared native cache for programs that are not apps;
  package publishing and the `haxeon` registry, which supply the sources the fragment names; NativeKit's changes to build
  the same core whatever is enabled (one graph needs that as well).

## Order

1. `haxeon create` with the `app` and `console` templates, the `[app]` section, the Linux runner and the generated
   fragment with native packages in one graph: `haxeon create hello` makes the counter app, which builds with `cmake` alone
   and with `haxeon build`, runs, and edits live.
2. Release builds through the runner (`--target hlc` sources in CMake). Done.
3. The Windows and macOS runners, checked by CI. Done.
4. The Android runner per app, replacing the shared Gradle project. Implemented.
5. The web runner for managed apps. Implemented.
6. Runner versions and `--fresh-runner`; the `package` and `native-package` templates.
