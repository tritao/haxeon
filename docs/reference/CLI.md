# Project CLI and builds

The project CLI creates projects with a `haxeon.toml` manifest
([MANIFEST.md](MANIFEST.md)), builds desktop HashLink programs, Android APKs and
experimental web bundles, and launches desktop and Android apps. It runs on
Unix-like systems and Windows.

Desktop and Wasm builds default to `development`, retaining metadata for
debuggers and other development tools. Use `--build-mode release` when building
artifacts for packaging or distribution; `run --watch` of an app it patches live always selects development. An
explicit release mode cannot be patched live: `run --watch --build-mode=release` of such an app asks for `--restart`. The
Android debug host
uses development metadata for live patching. Release HashLink
modules retain function names and line tables for profiler output and stack
traces, and omit opcode spans and embedded source snapshots. The compiler CLI
accepts the equivalent `--build-mode=release` or `--build-mode=development`.

Module metadata mode is independent of native optimization. Host project builds
keep optimized `Release` native libraries in both modes, including the default
development mode and live rebuilds.

The examples assume `haxeon` is on PATH from an installed [release](RELEASES.md).

```sh
haxeon create my_app
haxeon create my_tool --template console
haxeon create .
haxeon migrate --dry-run
haxeon migrate
haxeon doctor
haxeon platforms
haxeon build
haxeon build --plan
haxeon build --jobs 8
haxeon build --build-mode release
haxeon run
haxeon run --quiet -- arguments
haxeon check
haxeon test
haxeon clean
haxeon tool.hx arguments
haxeon build.hxml
haxeon -cp src -main Main --hl bin/main.hl
haxeon build --target wasm32
haxeon create mobile_app --platforms android
haxeon build --target android
haxeon run --target android
haxeon devices
haxeon fmt src/Main.hx
haxeon fmt --check src/Main.hx
cat src/Main.hx | haxeon fmt --stdin
haxeon lint --manifest haxeon.toml src/Main.hx
haxeon lint --fix --manifest haxeon.toml src/Main.hx
```

`haxeon --help` lists the commands by task; `haxeon help build`, `haxeon build --help`
and `haxeon build -h` print one command's options. `haxeon --version` (or `haxeon
version`) prints the CLI's version, the checkout commit its compiler is built from and
the HashLink version, as `haxeon 0.3.0 (compiler 7970f0eaaa86, HashLink 2.0.0)`. A
mistyped command gets one line naming the closest command, and exits with status 2. A
command line that starts with an `.hxml` file or one of Haxe's options (`-cp`, `-main`,
`--hl`, `-D`, ...) is built as Haxe would build it: see [Haxe command lines](#haxe-command-lines).

A value the CLI does not take is reported with the values it does, as in `Unknown
target "solaris". Valid: host, android, wasm32, ...`. Every command exits with 0 when it
succeeds, 1 when a build, a test or another step fails, 2 for a usage error (an unknown
command or option, a missing or invalid value) and 70 for an internal error, which is a
bug in Haxeon. The compiler run directly takes each valued option as `--name=value` or
`--name value`, and exits with 2 for a usage error too.

`haxeon create DIRECTORY` makes a project from a template in the installation's `templates/`: `--template app` (the default) is a window with a counter and an
`[app]` section ([MANIFEST.md](MANIFEST.md)) that uses the UI package from the `haxeon` registry (`ui = "^0.3"`, with
`compatibility.haxeon`). Use `--template console` (or `-t console`) for a console program without an `[app]` section.
`--platforms` lists an app's
platforms (by default every platform the template has a runner for: android, linux, macos, web and windows) and `--org` the prefix of its identifier (`com.example`). `haxeon create .` adds the
template's files a project lacks and never overwrites one. Use `create . -t console` for a console program in the current directory.

An app builds through its runner project, the CMake project for each platform that `haxeon create` writes beside the
sources (`linux/`, `macos/`, `windows/`), which is the app's to change (the executable's name, the bundle's Info.plist, the
version resources, packaging): `haxeon build` compiles the module,
writes `build/generated/PLATFORM/haxeon.cmake` and builds this machine's runner with CMake into `build/PLATFORM/app/`,
where the executable (named after the package), its module and its native packages' libraries sit together, or on macOS
make the bundle `NAME.app`; on Windows it builds with MSVC, as a Windows program (no console window from Explorer).
`haxeon run` runs that executable, and `--watch` runs the module it rebuilds in it. `cmake -S linux -B DIR &&
cmake --build DIR` (or `macos`, `windows`) builds the same app once a build has written the fragment. Building for a
platform the app does not list, or without its
runner, is a usage error that names `haxeon create .`.

An app's window takes the host's standard flags after `--`, so a test or a script can run any app without code of its
own: `--frames=N` stops after N rendered frames, requesting redraws while idle. `--capture=DIR` writes diagnostics to DIR
and on X11 saves an image of the app window as `frame.png`.
`--capture-seconds=S` captures after S seconds instead, and `--input-script=PATH` plays timed input
(`haxeon.ui.host.DesktopUiHostOptions.withArguments`):

```sh
haxeon run -- --frames=10 --capture=out/capture
```

`haxeon fmt` uses Haxeon's built-in lossless formatter. It rewrites files by
default, while `--check` reports files that would change; a directory stands for
the `.hx` files under it. Use `--stdin` for editor or pipeline integration.

The style comes from the project: the `format` section of the nearest
manifest (`haxeon.toml` or `haxeon.json`) above a file that has one, else tabs and
120 columns. `haxeon fmt`, `haxeon lint --fix` and the language server all read it
(the language server ignores an editor's tab settings), so a file formats the same
everywhere. A package's tests manifest without a `format` section takes the package's.

```toml
[format]
indent = "spaces"
indentWidth = 2
lineWidth = 100
```

(`"format": {"indent": "spaces", "indentWidth": 2, "lineWidth": 100}` in a `haxeon.json`.)

`indent` is `tabs` or `spaces`, `indentWidth` the width of one level (the columns
a tab counts for), `lineWidth` the column limit; every key is optional and an
unknown key or bad value is an error. The formatter accepts any source that lexes
and whose brackets balance, including Haxe that Haxeon's compiler does not support
yet, and refuses output that changes a token or a comment's text. A file that must
keep its layout says `@formatter:off` in a comment; without `@formatter:on` the
rest of the file is kept as written.

`haxeon lint` reports imports a file never uses and exits with 1 when it finds any;
`--fix` removes them and reformats a file that was formatted before. Imports resolve
against the `sourceRoots` of each `--manifest`. A wildcard, a module that does not
resolve, an alias of another type and an abstract with implicit conversions are
never reported, since removing them could change what the file means. Enum imports
are used through their constructors.

It also reports runs of imports that are not in order, and `--fix` sorts them by path
(ASCII, so `compiler.Compiler` sorts before `compiler.ffi.HxiAbi`). A run is
consecutive import lines; a blank line, a comment, a `#if` line, a `using` or an
import sharing its line with other code ends it, so groups stay where they are. A
later import of a name wins, so a run where two imports make the same short name
visible (module imports count every type the module declares), or with a package
wildcard, keeps its order and is not reported. `--only unused-imports` or
`--only import-order` checks one rule.

Those two rules read syntax only and run by default. The rule `unbound-local` needs
types, so it is opt-in and runs only when `--only unbound-local` names it:

```bash
haxeon lint --only unbound-local src
```

It names each local whose type nothing fixes, which therefore is `Dynamic`: a
`var x;` never assigned, a `var x = null` never given a value, or a `var list = []`
never used in a way that fixes its element type.

```text
src/Main.hx:4: local "x" is Dynamic: nothing fixes the type of local "x"
src/Main.hx:5: local "list" is Dynamic: nothing fixes the element type of this empty array
```

Haxe accepts such a local and gives it the type `Dynamic` without a warning, and so
does Haxeon's compiler; the rule is there to audit code for them. A local that a
later assignment, a `push` or a typed use (a return, a typed argument) fixes is not
named. Each file is typed as the editor types it: its project is the nearest
`haxeon.toml`, `haxeon.json` or `.hxml` above it (`--manifest` is not used), and the file's module
is the entry. If a file's program has type errors, they go to standard error, the
bodies that typed are still checked, and a body that failed is not. The command exits
with 1 when it names a local or a program does not type. The rule has no `--fix`:
give each local it names a type. It runs in a program that links the compiler, like the
language server: the compiler's own (its `lint` role) when it is current, as in a release, else a tool of its own
(`LintMain`) built on first use.

The opt-in rule `module-namespace` names each module-level variable or function
reached through its module's name, a Haxeon extension stock Haxe rejects (see
[Language support](LANGUAGE_SUPPORT.md)):

```bash
haxeon lint --only module-namespace src
```

```text
src/Main.hx:8: "Settings.hits" names app.Settings.hits through its module's name, which Haxe rejects: import app.Settings.hits or write it in full
```

Haxe's forms are an import of the member (`import app.Settings.hits;`) or its full
path; a class's own static named through the imported class (`Store.count`) is
Haxe's too and is not named. It reads each file's project as `unbound-local` does,
exits with 1 when it names a use or a program does not compile, and has no `--fix`.

The opt-in rule `throw-non-exception` names each `throw` whose value's static type
is not `haxe.Exception` or a subclass of it: a `String`, an enum, `Dynamic`, or a
type variable nothing has fixed when the `throw` is typed:

```bash
haxeon lint --only throw-non-exception src
```

```text
src/Main.hx:12: throw of String, not a haxe.Exception: throw an Exception subclass
```

Haxe accepts any thrown value, and so does Haxeon; a `catch (e:haxe.Exception)`
sees such a value wrapped in a `haxe.ValueException`. Code that throws only
exceptions never needs that wrap, and this rule checks that it does. Only the
`throw`s written in source are named, not those the compiler generates, and only
in code the project's configuration compiles: a branch of `#if` it does not take
is not typed, so not checked. It reads each file's project as `unbound-local`
does, skips a body that does not type, exits with 1 when it names a `throw` or a
program does not type, and has no `--fix`. Haxeon's own sources keep to the
subset: the compiler and its tools throw `CompileError` for a located compile
error and `compiler.core.InternalError` for any other failure.

Create a program with `haxeon create my_tool --template console`, or an Android app with
`haxeon create my_app --platforms android`.

A project may keep a `haxeon.json` instead, with the same keys ([MANIFEST.md](MANIFEST.md) lists them and shows both
forms); every command reads either, and a directory with both is a usage error that names both. `haxeon migrate`
rewrites a project's `haxeon.json` as `haxeon.toml`: it checks that the TOML reads back to the same settings, then
removes the JSON file. `haxeon migrate --dry-run` prints the TOML instead and changes nothing; `--project PATH` names
another project.

Paths in the project file are relative to that file. Console host builds go to
`build/host/main.hl`. Web app bundles go to `build/web/wasm32/` or
`build/web/wasm-gc/`, ready to serve over HTTP. Console Wasm builds write just
the module in `build/wasm32/` or `build/wasm-gc/`.
Android builds package `build/android/app-debug.apk` through the app's Gradle
runner. Use `--gradle-inputs FILE` to prepare a standalone Gradle build and
`--device SERIAL` when running on one of several connected devices. See
[Android](ANDROID.md) for prerequisites and live editing. Use
`--project path/to/haxeon.toml` (or the project's directory) to select another project, repeat
`--define NAME[=VALUE]` to add conditional defines, and pass arguments to a
running program after `--`:

```sh
haxeon run -- --verbose
```

A program's standard output flushes at once on a terminal and is buffered into a pipe
or a file. It is flushed before a read from standard input, a subprocess, a sleep and
exit, and a fatal signal attempts a last flush; SIGKILL can lose the buffered tail.
`Sys.stdout().flush()` flushes explicitly, and `HL_STDOUT_FLUSH=1` flushes after every
print (`haxeon script.hx` sets it, so a script's lines appear as they are printed).

`run --debug-port PORT` builds a host development project and waits for a debugger on a loopback port
before entering the program. The VS Code extension provides F5 launch and a local attach configuration.
See [Debug in VS Code](../guides/00-get-started.md#debug-in-vs-code).

For function breakpoints during debugging, set `inline = false` in `haxeon.toml`; inlining is on otherwise. The
choice applies to the root project's compilation, including dependencies, and participates in action and compiler memo
fingerprints. It does not disable the other IR passes. Direct compiler calls turn it off with `--no-inline`.

A compile states its passes and self-checks as flags, never through the environment, so one compile server serves any
mix of them: `--no-inline`, `--no-load-store-forwarding`, `--no-strength-reduction`, `--no-early-prune` (a migration
reference for the reachability walk), `--check-reuse` (compare everything a compile reuses with a fresh build; slow, for
the test suites), `--no-verify-ir` and `--verify-ir`, and `--wasm-legacy-exceptions` (below). The IR verifiers check each
function's CFG and the final HashLink IR before lowering; a release build (`--build-mode=release`) skips them unless
`--verify-ir` is given, and the test driver always gives it.

A compile server keeps a session between requests and builds on it (`--session=reuse`, the default); a request with
other settings starts it over anyway. `--session=fresh` starts it over before compiling, so the result depends on the
request alone, never on what the server compiled before.

`--null-safety=MODE[:PATH[:shallow]]` gives the classes and abstracts at the dot path `PATH` (every one when it is left out) the
null-safety mode `MODE` (`off`, `loose`, `strict`, `strict-threaded` or `warn`), as Haxe's `nullSafety(PATH, MODE)` does;
`:shallow` keeps a package's rule out of its subpackages. The flag may repeat. A build passes one per package path from each
package's `nullSafety` setting ([MANIFEST.md](MANIFEST.md#null-safety)) and one per `--macro nullSafety(...)` of a Haxe command
line.

`run --profile[=SOURCES]` launches the program under `hl --diagnostics`, records it with `hlprof-live` into an HLPC
capture directory (`profile.hlpc`, `profile.pftrace`, `capture.json`, the bytecode) and prints a report when it ends.
`SOURCES` is a comma list of `instrument`, `sampling` and `alloc`; without a list the default is `instrument`, which
runs the instrumented build. `--profile-output PATH` names the `.hlpc` file (with `--watch`, the directory that holds one
capture per launch) and implies `--profile`. `--profile-start`, `--profile-duration`, `--profile-max-size`,
`--profile-window` and `--profile-min-call` control what is recorded and exported; [PROFILING.md](PROFILING.md) lists
them.

```sh
haxeon run --profile=sampling -- --verbose
```

On Linux, macOS and Windows, `run --watch` rebuilds after edits to resolved package
sources. Haxe source edits use the compiler-only build path; FFI, manifest, and
native source edits use the full project build. A failed build leaves the
running app open. Runtime output is forwarded from `<output>.watch.log`. What a
successful build does depends on the project's entry class, which the watch reads
from its source before the first build and names in one line as it starts:

- **Patch.** When the entry class declares the static functions the live host
  calls, `start(arguments:String):Void`, `tick():Int` (nonzero while running),
  `close():Int`, `saveState():String` and `restoreState(state:String):Void`
  (`tools.LiveEntryPoints`), the app runs in a stable host process that applies
  compatible HLP patches between application pump steps. The host calls `start`
  once, then `tick` repeatedly; it never calls `main`, which the entry class
  still has. A structural change reloads the module through the state methods.
  Non-Haxe changes restart the process. The app templates' `Main` has them all.
- **Restart.** Otherwise, or with `--restart`, the watch relaunches the app
  after each successful build.

`--strict-live` makes a patching watch refuse an edit that cannot patch instead
of reloading ([LIVE_PATCHING.md](LIVE_PATCHING.md#strict-mode)); it is an error
with `--restart` or for an app the watch would restart.

```sh
haxeon run --watch --project path/to/haxeon.toml -- --verbose
haxeon run --watch --restart --project path/to/haxeon.toml
```

`build --compiler-only --patchable` builds the module as a patching watch does,
for a host that applies the patches itself (a phone's, say): the compiler worker
keeps the module's history, so each later `build --compiler-only --patchable`
publishes an `.hlp` patch and its `.live.*` descriptions beside the module.

Besides the console, `run --watch` appends what it does with each edit to `<output>.watch-events.jsonl`, one JSON
object per line, and passes that path to the app in `HAXEON_WATCH_EVENTS`: `rebuild-started` (with `changedFiles`),
one `output-line` per line the build printed, `build-failed` or `build-ok`, and when it patches `patch-published`
(`revision`, `reloadReasons`). The live host adds `patch-applied`, `patch-rejected` (a refused patch or a failed
reload, with `message`) and `reload`. The file starts empty with each watch and moves to `<file>.1` past 4 MiB.

> A watch session keeps the compiler it started with. Restart the session after changing the compiler.
> See [Live patching](LIVE_PATCHING.md#artifact-builds-and-live-sessions).

Host builds resolve local path dependencies declared by package name. A
dependency can provide Haxe sources and optional C sources; C sources are
compiled into the HashLink native library requested by the build:

```toml
version = 1
entry = "Main"
sourceRoots = ["src"]
target = "host"
outputDir = "build"

[package]
name = "my-app"

[dependencies]
foo = { path = "../foo" }
```

The `foo` package can list native inputs in its own manifest:

```toml
version = 1
sourceRoots = ["src"]

[package]
name = "foo"

[native]
sources = ["native/foo.c"]
includeDirs = ["native/include"]
std = "c++20"
```

The optional native `std` value controls compilation of package-owned C and
C++ sources. It is separate from the `std` value in an FFI recipe, which
controls Clang's header import and generated thunk compilation. CMake-backed
packages continue to declare their language standard in `CMakeLists.txt`.

A build says little by default: a line when it starts, its diagnostics, and a line
when it ends.

```text
Building my-app (host, development)…
✔ build/host/main.hl (0.4 s)
```

`-v LEVEL` (`--verbosity LEVEL`) chooses how much `build` and `run` print. Each level
prints what the ones before it print, and more:

| Level | Prints |
|---|---|
| `quiet` (`q`) | diagnostics only |
| `minimal` (`m`) | the default: the first and last line above |
| `normal` (`n`) | each action as it starts or is found up to date (`[id] clean (fingerprint match)`), and the compiler's progress (`reusing compiler session`, `compiled N source files -> PATH`) |
| `detailed` (`d`) | the compiler worker's costs (`compiler: 12 ms, 3 functions retyped`, `worker allocations: ...`) and the FFI files it loads |
| `diagnostic` (`diag`) | the compiler's phase, IR pass and allocation reports |

The compiler takes the same levels as `--verbosity=LEVEL` (default `normal`); scripts that
read its reports pass `--verbosity=diagnostic`. A self-hosted build (`--self-hosted`)
runs the committed bootstrap compiler, which prints what it always printed.

Diagnostics go to standard error, each with its file relative to the directory the
command was run from, the line it concerns and a caret under the code, and end with
how many errors there were:

```text
src/Main.hx:2:14: error[E1002]: Type mismatch for local "x": expected Int, got String
 2 |     var x:Int = "a";
   |                 ^^^

1 error
```

They are coloured on a terminal: `--color=auto|always|never` (default `auto`, which
also honours `NO_COLOR` and `TERM=dumb`). `--diagnostic-format=short` prints the one
line each that tools and tests read instead, `Main.hx:2:14: E1002: ...`, with the path
under its source root. That is the compiler's own default (`--diagnostic-format=`,
`--color=` and `--diagnostic-directory=` select the full format there); the language
server reports diagnostics through the protocol, unchanged.

`haxeon build --plan` prints the deterministic artifact and action plans.
Add `--explain` to show why each artifact is present, and `--timings` to print
resolution, planning/lowering, and execution wall-clock measurements, and the
compiler's `diagnostic` reports whatever the verbosity.
`--jobs COUNT` controls the number of independent ready actions the executor
may run at once. Native outputs and action fingerprints live below the
application's `outputDir`; unchanged native source actions are skipped on later builds.
CMake package builds are delegated on every invocation, allowing CMake to check
its own source, header, generated-file, and library dependencies. Configure
fingerprints cover `CMakeLists.txt` and explicit `native.cmake.inputs`; use those
inputs for additional configuration files, rather than entire source trees.
CMake package stamps are never shared as if they were complete library artifacts.

Set `native.cmake.library` to the name of an ordinary shared-library CMake
target when the package's HXI interface loads that library directly. Haxeon
places the library in the package's native runtime directory and includes that
directory when running dependents. For an aggregate target, use
`"libraries": ["foo_core", "foo_io"]` instead of `library`. Every listed name is
a required shared-library output; Haxeon supplies the target platform's prefix
and suffix and verifies that all outputs exist after CMake succeeds. Do not
declare optional libraries unless that package's CMake configuration enables them.
The aggregate target can depend directly on its library targets without creating
a stamp file. CMake still runs on every build to check its own dependency graph,
so deleting any listed library causes CMake to rebuild it.
Omit both `library` and `libraries` for CMake targets that produce
the package's `<package>.hdll` output themselves.
Native implementation changes do not invalidate independently compiled bytecode;
Haxe sources, FFI interfaces/projections, compiler sources, and the standard
library still do. Failed native builds still block the project build and launch.

On Linux, macOS and Windows, host and `wasm32` builds reuse a private compiler worker between
CLI invocations. Small source edits retain semantic compiler state; changes to the
source manifest, roots, defines, or FFI configuration reset it. Workers are keyed by the compiler build,
project root, build root, output path, and backend target. Workers exit after
`HAXEON_COMPILER_IDLE_SECONDS` (default 90) without a request. Every build root
shares one per-user session directory (`$XDG_CACHE_HOME/haxeon/compiler`,
`%LOCALAPPDATA%\haxeon\compiler` on Windows, or `HAXEON_COMPILER_SESSION_DIR`) holding worker programs, connection metadata, and
logs, so the resident limits below apply to the whole machine. Compiler activity removes dead connection
records and prunes unused worker programs, orphaned logs, and abandoned temporary files after a day. Set
`HAXEON_COMPILER_SERVER=0` to use one-shot compilation, which runs the compiler
as a HashLink program compiled once per compiler version (Windows interprets it). Explicit `--self-hosted` builds and unavailable workers
retain the one-shot path. The normal CLI's local fingerprint checks run before
contacting a worker, so unchanged bytecode is still skipped entirely.

Shared-cache hashing reuses content digests within one build invocation. Set
`HAXEON_DISABLE_ARTIFACT_CACHE=1` to disable the shared artifact cache while
retaining local fingerprint checks. It is no longer necessary to disable it to
avoid sharing a CMake package's stamp file.

The current executor is selected through a replaceable backend boundary; set
`HAXEON_EXECUTOR=native` explicitly to select it. Alternate schedulers can be
evaluated against the same lowered `ExecutionPlan` without changing package or
build semantics.
The normal host build requests the shared HashLink library; static archives are
available to other build consumers without being produced unnecessarily. Target
and toolchain selection is centralized: examples include
`windows-x86_64-msvc`, `linux-x86_64-gnu`, `macos-arm64`, `android-arm64`,
and `wasm32` (see [Targets and backends](#targets-and-backends)).

Dependencies can be added and installed reproducibly. `haxeon add NAME` adds the latest release of `NAME` that is not
yanked from the `haxeon` registry, written as its version range alone (`ui = "^0.3.1"`); `--version RANGE` picks the
range and `--registry NAME` another registry, written as `{ registry = NAME, version = RANGE }`:

```sh
haxeon add ui
haxeon add ui --version "^0.3"
haxeon add widgets --registry local
haxeon add --git https://github.com/example/foo.git --rev main foo
haxeon install
haxeon install --locked
haxeon update
haxeon tree
haxeon why foo
haxeon publish --registry local --version 1.0.0
haxeon package check
```

`install` records the requested source and resolved Git commit in
`haxeon.lock`; `install --locked` rejects manifest changes and checks out the
exact recorded revision.

Registry sources use the same lockfile path. A registry index records immutable
release checksums, SemVer versions, yanked status, compatibility metadata, and
native provider metadata. For local development, `publish` writes an immutable
release and index below `~/.haxeon/cache/sources/registry`; projects then use
`core = { registry = "local", version = "^1.0" }` and resolve through the normal
package graph. A dependency on the `haxeon` registry is written as its range alone,
`core = "^1.0"`; that registry is the SDK's first, then the cache's. See the [manifest reference](MANIFEST.md#the-haxeon-registry).
`publish` turns path dependencies on packages of the registry into version ranges and refuses others, and copies the
files Git tracks (submodules included) or, outside a repository, every file, less the manifest's
`publish.exclude`. `install --locked` is strict: a locked registry version that is gone is an
error, where a build or `install` picks again within the range.

Repositories can declare workspace members. A workspace member with the same
package name overrides an external dependency source while retaining the same
package identity:

```toml
workspace = ["packages/core", "packages/editor"]
```

Native packages may instead delegate an existing CMake project as one coarse
provider:

```toml
[native]
cmake = { source = "native", target = "foo" }
```

Native providers advertise their supported targets with `native.targets`; the
default source and CMake providers support `host` and `android`. If a package
has no provider for a requested target, planning stops with the package and
missing-provider chain—for example, `foo cannot be built for wasm32`—before
compilation or linking begins.

Packages can also gate resolution with compatibility metadata:

```toml
[compatibility]
haxeon = ">=0.3"
targets = ["host", "android"]
runtimeAbi = "2"
```

These requirements are checked while resolving the package graph, before any
compiler or native action is planned.

Haxelib is an adapter, not Haxeon's package model. A pure-Haxe Haxelib release
can be placed in the dedicated `~/.haxeon/cache/sources/haxelib/<name>/<version>`
cache (or supplied as an archive under its downloads cache); its `haxelib.json`
is translated to a normal Haxeon manifest. Haxeon does not read global
`haxelib dev` state or execute `extraParams`, macros, or HXML compiler settings;
unsupported settings fail with an explicit import diagnostic.

Android app runners build native CMake packages with Gradle's NDK toolchain once per ABI.
The APK contains the resulting libraries, the generated Haxe assets and the SDK host.

The `doctor` command checks Haxeon's own installation (the compiler, the HashLink runtime), the C and C++ toolchain
that an app, a package with C or C++ code and a build ahead of time need, and the Android SDK tools. It
prints one `ok:` or `missing:` line for each. The toolchain is looked up as the builds find it: on Linux and macOS the
C and C++ compilers (`CC` and `CXX`, else `cc` and `c++`, `gcc` and `g++` or `clang` and `clang++`), on macOS the Xcode
command line tools first, on Windows MSVC through `vswhere` (Visual Studio or its Build Tools with the C++ tools); then
CMake 3.24 or later, Ninja or Make (not on Windows), and on Linux `pkg-config` with the development files of GTK 3,
OpenGL and Fontconfig, which the UI package's window needs. When a tool is missing it prints the command that installs
the toolchain on this system (`apt-get` on Debian and Ubuntu, `dnf` on Fedora, `xcode-select --install` and Homebrew on
macOS, `winget` on Windows). It exits with 1 only when Haxeon's own installation is incomplete: a program builds without
the toolchain. `platforms` lists the targets with the backend each builds, and `devices` reports connected
Android devices. Serve web bundles over HTTP to run them in a browser. Host output runs through HashLink on the
current machine.

## Checking, testing and cleaning

`haxeon check` types the project's program as `haxeon build` would and reports the same diagnostics, but generates and
writes nothing: the compiler takes the request as `--no-output`, Haxe's name for it. It runs only the compile (and the FFI
imports the compile reads, never the native libraries), for the project's target or `--target`, and takes `--define`,
`--build-mode`, `-v`, `--color`, `--diagnostic-format` and `--timings` as `build` does. It shares the build's compiler
session, so a check after a build, or a build after a check, reuses what the other typed. It exits with 1 when the program
has an error.

```text
Checking my-app (host)…
✔ No errors (0.3 s)
```

`haxeon test` builds the project's tests and runs them: a package keeps them in a project of their own,
`tests/haxeon.toml` (or `tests/haxeon.json`) beside its manifest, whose entry runs the tests and exits
with a status other than 0 when one fails. Run in that `tests` directory, it runs the tests project itself. It takes the
options of `run`, `--watch` included (the tests run again after each edit), passes the arguments after `--` to the tests,
and exits with 0 when they pass and 1 when they fail. `haxeon workspace test` runs the tests of many projects at once,
caching passing runs.

`haxeon clean` removes what builds wrote for the project: its `outputDir` (and `outputDir-instrument`, the instrumented
build's) and its tests project's. What projects share stays: the compiler workers, the native CMake cache, the artifact
cache and the package source cache. An `outputDir` that would hold the project itself is refused, never removed.

## Haxe command lines

`haxeon` builds Haxe's own command lines, so a Haxe project builds without a `haxeon.toml`:

```sh
haxeon build.hxml
haxeon -cp src -main Main -D level=3 --hl bin/main.hl
```

The arguments are read as Haxe reads them. In an `.hxml` file each line is one argument, or, when it starts with `-`, its
first word and the rest of the line (`-D name=a b` defines `name` as `a b`); quotes around a value are removed, a line
starting with `#` is a comment, and a `#` later in a line is part of the value. An argument ending in `.hxml` is replaced by
that file's arguments. Every path, an included `.hxml` file's too, is relative to the working directory, not to the file
that names it. `--cwd DIR` changes the working directory for the rest of the run, as Haxe's does for its process: an
`.hxml` file named after it is read from there, and every path of a compilation, a class path given before the `--cwd`
too, is relative to the directory it is in when the compilation ends. `--next` separates compilations, `--each` gives the
arguments before it to every compilation, and the first compilation that fails stops the rest. A compilation with nothing
to compile (no `-main` and no dot path) prints the help and succeeds, as Haxe's does. The single-dash spellings (`-main`,
`-lib`, `-cmd`, `-debug`, `-dce`, `-hl`) are read as their `--` forms, as in Haxe 4.

| Haxe | Haxeon |
|---|---|
| `-cp DIR`, `-p`, `--class-path` | a source root; the one given last is looked in first, and the working directory, always one, last, as in Haxe |
| `-main CLASS`, `-m`, `--main` | the entry; one that no class path holds is Haxe's `Type not found : CLASS`, status 1 |
| dot paths (`pack.Module`) | modules compiled besides the entry |
| `-D NAME[=VALUE]`, `--define` | a define |
| `--hl FILE.hl` | build for the host and copy the module to `FILE.hl` |
| no target, or `--no-output` | check the program, writing nothing, as Haxe only types it then |
| `--debug` | a development build (otherwise release), and the define `debug` |
| `--dce std`, `--dce full` | accepted: Haxeon always removes what the entry cannot reach |
| `--no-inline` | the project setting `"inline": false` |
| `--macro nullSafety("PATH", MODE, RECURSIVE)` | Haxe's null-safety macro, also as `haxe.macro.Compiler.nullSafety(...)`; see below |
| `-lib NAME:VERSION`, `-L`, `--library` | a Haxelib dependency of that exact version, from the Haxelib cache (see Haxelib above) |
| `--cmd COMMAND` | run by the shell in the working directory after the compilation succeeds |
| `-v`, `--verbose`; `--times` | `-v normal`; `--timings` |

Anything else is one usage error (status 2) that lists each unsupported argument with what to do instead, before anything
is built: another target (`--js`, `--cpp`, ...; HashLink/C `--hl FILE.c` too, for now), `--interp`, `--run` and `-x` (Haxeon
has no interpreter: build with `--hl` and run the module with `hl`, or make a project and `haxeon run`), any `--macro` but
`nullSafety(...)`, `-lib`
without a version (Haxeon does not read haxelib's global repository), `--dce no`, `--resource` and the server and display
options.

```text
haxeon: this Haxe command line uses what Haxeon does not support:
  --js bin/main.js: Haxeon generates HashLink (--hl FILE) only
  --macro include("app"): macros are not supported, but for nullSafety("path", Mode, recursive)
See 'Haxe command lines' in docs/reference/CLI.md.
```

`--macro nullSafety("app.ui", Strict)` is the one macro Haxeon takes, as Haxe states it: the classes and abstracts at the dot
path (a package, a module or a type; `""` is everything) are checked as if marked `@:nullSafety(MODE)`. The path is a string in
double or single quotes; the mode is `Off`, `Loose` (the default), `Strict` or `StrictThreaded`, bare or as `NullSafetyMode.Strict`;
the optional third argument, `false`, keeps a package's rule out of its subpackages. A command line without the macro is not
checked. The checker's rules are in [LANGUAGE_SUPPORT.md](LANGUAGE_SUPPORT.md#null-safety), "Null safety".

Each compilation is a project the CLI makes in memory, as it does for a script, and builds like any host project. Its
build state lives in the CLI's cache, `~/.haxeon/cache/hxml/<digest>` (`HAXEON_HXML_CACHE` names another directory), one
per working directory, entry and output, so a second build is incremental; nothing is written to the working directory but
the module, copied to the `--hl` path. A compilation's cache is removed after 30 days without a build, as a script's is.

## Targets and backends

Two names describe a build, and Haxeon keeps them apart:

- The **target** (`--target`, `target` in `haxeon.toml`, `compatibility.targets` and `native.targets`) says where the
  program runs: `host` (this machine, the default), `android` (`android-arm64`), `wasm32`, `wasm-gc`, or an explicit
  `OS-ARCH[-ABI]` such as `linux-x86_64`, `macos-arm64` or `windows-x86_64-msvc`. Architectures are spelled `x86_64` and
  `arm64`; `aarch64`, `amd64` and `x64` are read too, and `wasm32-wasi` is `wasm32`. `haxeon platforms` lists them with this
  machine's name.
- The **backend** says what the compiler generates: `hl` (HashLink bytecode, run by the VM's JIT), `hlc` (C on the HashLink
  runtime, compiled ahead of time by the C compiler), `wasm32` (WebAssembly
  with linear memory) or `wasm-gc` (WebAssembly GC). The compiler takes it as `--target=NAME`, which is Haxe's sense of
  "target"; the project build passes it.

The target chooses the backend: `host`, `android` and the other native targets build `hl`, and each Wasm target selects its corresponding backend.
An app's release build (`--build-mode=release`) builds `hlc`, which its runner compiles into the executable.
For a standalone C build, the direct compiler's `--target=hlc` writes the C to `OUTPUT.c/` for a C toolchain. A CMake project builds it with the SDK's CMake package: after `find_package(Haxeon)`,
`haxeon_add_c_executable(TARGET SOURCES_DIR OUTPUT.c [DEVELOPMENT])` makes the executable, with the C compiler CMake
chooses (`CC`, `-DCMAKE_C_COMPILER`). Haxe's `--hl FILE.hl` is the target `host` with the backend `hl`,
and a Haxe target name given to `--target` is refused with Haxeon's (`--target hl` says to use `host`).

## Language server and FFI tools

- `haxeon lsp` is the Language Server Protocol server, over standard input and output; the VS Code extension starts it
  (`haxeon.server.path` and `haxeon.server.args`).
- `haxeon ffi import ...` imports C and C++ headers as HXI ([C_HEADER_FFI.md](C_HEADER_FFI.md)); a project's `ffi`
  recipes run it during the build.
- `haxeon ffi audit ...` imports one public header for several targets and compares their C ABIs.

`haxeon ffi import` resolves relative paths against the directory it is run from, like every other command.

## Scripts

`haxeon script.hx [arguments]` (or `haxeon run script.hx ...`) builds one Haxe file and runs it, with no project to set
up, as `dotnet run app.cs` does:

- The file is the project's one source. Its directory is the source root its imports resolve in, so modules beside it
  can be imported, but other files there are not compiled.
- A `haxeon.toml` (or `haxeon.json`) beside the script makes that project a path dependency, with its source roots and dependencies.
- The build is quiet: its output appears, on standard error, only if it fails. The program runs in the directory the
  command was invoked from, with the given arguments, and its exit status is the command's.
- The project is made in memory and built in `~/.haxeon/cache/scripts/<digest of the script's path>`
  (`HAXEON_SCRIPT_CACHE` names another directory), and the incremental build makes an unchanged script's next run cost a
  launch. A script's cache is removed after 30 days without a run.
- A first line `#!/usr/bin/env haxeon` makes the file executable where the shell reads such lines; Haxe accepts that
  line at the start of a file, and so do Haxeon's compiler and formatter.
- The file's name is its module's, dashes included (`check-self-hosting.hx`); a script is never imported by name, so it
  need not be an identifier. Only a further dot (`a.b.hx`) is refused, since it would read as a package.

A script can declare `main` or run top-level statements as an implicit `main`. Combining both is a compile
error. The statements run in source order and can call module-level functions and use types declared later in
the file. Plain `var` and `final` declarations in the implicit `main` are locals. A script with an explicit
`main` can still declare ordinary module fields. Read command-line arguments with `Sys.args()`.

```haxe
#!/usr/bin/env haxeon
final args = Sys.args();
Sys.println(greet(args.length > 0 ? args[0] : "world"));

function greet(name:String):String
	return 'hello $name';
```

Only the file invoked as a script accepts top-level statements. Imported modules and project sources use the
ordinary Haxe module grammar.

`haxeon.Script` (in the standard library) covers what shell scripts make short. It starts programs directly, never
through a shell, so arguments need no quoting and a script runs the same on every platform:

| Function | Does |
|---|---|
| `run(command, ?arguments, ?options)` | Runs a program and returns its status; its output passes through, or goes to `options.log` |
| `check(...)` | As `run`, and stops the script when the status is not 0 |
| `output(...)` | Returns the program's standard output; stops the script when the status is not 0 |
| `fail(message, status = 1)` | Prints to standard error and ends the script |
| `path()`, `directory()` | The script's file and directory (`HAXEON_SCRIPT`) |
| `vm()`, `haxeon()` | The `hl` VM and the `haxeon` command that run the script |
| `tail(file, count)`, `files(directory, suffix)`, `sameContent(left, right)` | Small file chores |

The options are `cwd` (the program's working directory), `env` (variables over those it inherits) and `log`.

```haxe
#!/usr/bin/env haxeon
import haxeon.Script;

function main() {
	var revision = Script.output("git", ["rev-parse", "--short", "HEAD"]);
	Script.check("cmake", ["--build", "out/cmake/release"], {log: "out/build.log"});
	Sys.println('built $revision');
}
```

## Workspace builds

`haxeon workspace plan|build|test` merges many projects into one build graph, so shared native code is built
once, everything runs from one work queue under one job limit, and tests run as graph nodes.

```sh
haxeon workspace test --workspace materia.workspace.json --skip-tag cadkit --skip-tag mujoco
```

The workspace file lists the member projects. Paths are relative to the file:

```json
{
  "version": 1,
  "buildDir": "build/workspace",
  "projects": [
    { "path": "animkit/tests/haxeon.json", "name": "animkit" },
    { "path": "stockkit/tests/haxeon.json", "name": "stockkit", "tags": ["cadkit"] },
    { "path": "kit/tests/haxeon.json", "name": "kit", "cache": false, "inputs": ["../fixtures"] }
  ]
}
```

- `tags` let a run skip projects that need something the machine may lack (`--skip-tag TAG`, `--only NAME`).
- `plan` prints the merged graph and how many actions were shared; `--actions` lists them.
- CMake packages are identified by (source, target), not package name, so projects that request the same native
  tree share one configure, one build, and one set of runtime libraries.
- `--jobs N` (default: CPU count) sets the total job limit and `--compilers N` (default 3) bounds simultaneous
  compiles, each of which holds a compiler heap. Across all build roots, Haxeon uses
  `HAXEON_COMPILER_WORKERS` (default 4) and, on Linux, `HAXEON_COMPILER_MEMORY_MB` (default 4096)
  to retire the least recently used batch workers. It first tries batch workers for the same output
  from older compiler versions. Live workers keep their patch baseline until their idle timeout, so
  active live sessions can temporarily exceed these limits.
- With Ninja 1.13 or newer, a GNU
  jobserver shares the job limit between Haxeon's own actions and every CMake build, so the machine is never
  oversubscribed. Older Ninja builds use their own parallelism; `HAXEON_CMAKE_GENERATOR=default` restores the
  platform's default CMake generator.
- Native compiles of CMake packages go through ccache when it is on `PATH` (`HAXEON_CCACHE=0` turns that off). The directory the
  project root and the package's CMake sources share (the checkout, when they are kits of one repository) is given to ccache as
  its base directory, so the same sources built in another checkout or worktree are served from the cache instead of
  recompiled: a cold build of the Materia app in a second worktree gets every compile from it. ccache runs in depend mode,
  which also caches sources whose preprocessed output names files that do not exist (HarfBuzz's Ragel-generated parsers).
  Configure and link steps, and the Haxe compile, are not cached. Size the cache (`max_size` in ccache's configuration) for
  the objects of every checkout you build, since entries beyond it are evicted.
- A project's Haxe compile and its native libraries build side by side: the compiler reads only the FFI interfaces a module
  imports, so its action waits for those and not for the libraries, which are loaded when the module runs. Whatever runs the
  module (`test`) waits for everything built for its project.
- `test` runs each project's compiled module and writes its output to `<buildDir>/tests/<name>.log`. A passing run
  is skipped while its inputs are unchanged: the module, the HashLink and Haxeon runtime libraries, the native
  libraries it loads, its project directory, and any files listed under `inputs`. Failing runs are never
  cached. Set `"cache": false` for a suite that depends on the clock, the network, or a peer process, or pass
  `--no-test-cache` to run everything.
- `"shards": N` splits a project's tests across N processes that run side by side from the one compiled module, so a suite
  made of independent groups takes as long as its slowest shard. Each runs `main.hl --shard I/N` as its own
  `test:<name>#<I>of<N>` action, with its own log and its own cached result. The program lists its groups with
  `haxeon.test.Shards.run`, which gives every group to exactly one shard for any N (heavier groups first, each to the
  lightest shard so far, from the groups' `weight`s) and runs them all when started without `--shard`. The groups must not
  depend on each other. Shard counts do not change what runs, only how it is spread across the machine's cores.
