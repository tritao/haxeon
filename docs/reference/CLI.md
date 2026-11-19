# Project CLI and builds

The project CLI creates a small `haxeon.json` manifest, builds HashLink programs
for the current desktop host, experimental Wasm32 modules, and Android APKs, and
can launch host programs or install and launch an Android app. The same command
is available on Unix-like systems and Windows:

Desktop and Wasm builds default to `development`, retaining metadata for
debuggers and other development tools. Use `--build-mode release` when building
artifacts for packaging or distribution; `run --watch --live` always selects development. An
explicit release mode cannot be combined with `--live`. The Android debug host
uses development metadata for live patching. Release HashLink
modules retain function names and line tables for profiler output and stack
traces, and omit opcode spans and embedded source snapshots. The compiler CLI
accepts the equivalent `--build-mode=release` or `--build-mode=development`.

Module metadata mode is independent of native optimization. Host project builds
keep optimized `Release` native libraries in both modes, including the default
development mode and live rebuilds.

`haxeon` is a native executable built by the checkout's native build
(`scripts/build-native.sh`, `scripts\build-native.ps1`), beside the `hl` VM in
the directory `scripts/hashlink-path.sh` prints. Put that directory on `PATH` to
run it as `haxeon`. `scripts/haxeon` (and `scripts\haxeon` on Windows) runs it
after rebuilding it and the CLI's bytecode if their sources changed.

```sh
./scripts/haxeon init
./scripts/haxeon doctor
./scripts/haxeon platforms
./scripts/haxeon build
./scripts/haxeon build --plan
./scripts/haxeon build --jobs 8
./scripts/haxeon build --build-mode release
./scripts/haxeon run
./scripts/haxeon run --quiet -- arguments
./scripts/haxeon tool.hx arguments
./scripts/haxeon build --target wasm32
./scripts/haxeon init --target android
./scripts/haxeon build --target android
./scripts/haxeon run --target android
./scripts/haxeon devices
./scripts/haxeon fmt src/Main.hx
./scripts/haxeon fmt --check src/Main.hx
cat src/Main.hx | ./scripts/haxeon fmt --stdin
./scripts/haxeon lint --manifest haxeon.json src/Main.hx
./scripts/haxeon lint --fix --manifest haxeon.json src/Main.hx
```

`haxeon fmt` uses Haxeon's built-in lossless formatter. It rewrites files by
default, while `--check` reports files that would change; a directory stands for
the `.hx` files under it. Use `--stdin` for editor or pipeline integration.

The style comes from the project: the `format` section of the nearest
`haxeon.json` above a file that has one, else tabs and 120 columns. `haxeon fmt`,
`haxeon lint --fix` and the language server all read it (the language server
ignores an editor's tab settings), so a file formats the same everywhere. A
package's `tests/haxeon.json` without a `format` section takes the package's.

```json
"format": {"indent": "spaces", "indentWidth": 2, "lineWidth": 100}
```

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
`--only import-order` checks one rule. `scripts/format.sh` removes unused imports,
sorts the rest and formats the whole tree, and `scripts/format.sh --check`, which
CI and the pre-push hook (`scripts/hooks/pre-push`) run, fails on any of the three.

Those two rules read syntax only and run by default. The rule `unbound-local` needs
types, so it is opt-in and runs only when `--only unbound-local` names it:

```bash
./scripts/haxeon lint --only unbound-local src
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
`haxeon.json` or `.hxml` above it (`--manifest` is not used), and the file's module
is the entry. If a file's program has type errors, they go to standard error, the
bodies that typed are still checked, and a body that failed is not. The command exits
with 1 when it names a local or a program does not type. The rule has no `--fix`:
give each local it names a type. It runs in a tool of its own (`LintMain`), built on
first use like the language server.

The opt-in rule `module-namespace` names each module-level variable or function
reached through its module's name, a Haxeon extension stock Haxe rejects (see
[Language support](LANGUAGE_SUPPORT.md)):

```bash
./scripts/haxeon lint --only module-namespace src
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
./scripts/haxeon lint --only throw-non-exception src
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

On Windows, use `scripts/haxeon.cmd` or `scripts/haxeon.ps1`. `haxeon init`
creates `src/Main.hx` and a project file like this:

```json
{
  "version": 1,
  "package": { "name": "my-app" },
  "entry": "Main",
  "sources": ["src/Main.hx"],
  "sourceRoots": ["src"],
  "target": "host",
  "defines": [],
  "outputDir": "build"
}
```

`haxeon init --target android` also adds Android settings to the manifest:

```json
"android": {
  "applicationId": "org.haxeon.android",
  "label": "Haxeon"
}
```

Paths in the project file are relative to that file. Host builds go to
`build/host/main.hl`; Wasm32 builds go to `build/wasm32/main.wasm`; Android
builds go to `build/android/app-debug.apk`, packaged by Gradle from the module
the build compiles to `build/android-arm64/app.hl` (see
[ANDROID.md](ANDROID.md)). Android projects require a
top-level `main():Void` entry function and an installed Android SDK/NDK. Use
`--device SERIAL` with `run --target android` when more than one device is
connected. Android builds use the pinned `vendor/libffi` submodule, which is
initialized by `scripts/bootstrap-tools.sh` or with
`git submodule update --init vendor/libffi`. Use
`--project path/to/haxeon.json` to select another project, repeat
`--define NAME[=VALUE]` to add conditional defines, and pass arguments to a
running program after `--`:

```sh
./scripts/haxeon run -- --verbose
```

For function breakpoints during debugging, set `"inline": false` in `haxeon.json`; inlining is on otherwise. The
choice applies to the root project's compilation, including dependencies, and participates in action and compiler memo
fingerprints. It does not disable the other IR passes. Direct compiler calls turn it off with `--no-inline`.

A compile states its passes and self-checks as flags, never through the environment, so one compile server serves any
mix of them: `--no-inline`, `--no-load-store-forwarding`, `--no-strength-reduction`, `--no-early-prune` (a migration
reference for the reachability walk), `--check-reuse` (compare everything a compile reuses with a fresh build; slow, for
the test suites), `--check-resolution` (compare the body resolver with the typer's scopes at every local; slow, for the
test suites), `--no-verify-ir` and `--verify-ir`, and `--wasm-legacy-exceptions` (below). The IR verifiers check each
function's CFG and the final HashLink IR before lowering; a release build (`--build-mode=release`) skips them unless
`--verify-ir` is given, and the test driver always gives it.

A compile server keeps a session between requests and builds on it (`--session=reuse`, the default); a request with
other settings starts it over anyway. `--session=fresh` starts it over before compiling, so the result depends on the
request alone, never on what the server compiled before.

`run --profile[=SOURCES]` launches the program under `hl --diagnostics`, records it with `hlprof-live` into an HLPC
capture directory (`profile.hlpc`, `profile.pftrace`, `capture.json`, the bytecode) and prints a report when it ends.
`SOURCES` is a comma list of `instrument`, `sampling` and `alloc`; without a list the default is `instrument`, which
runs the instrumented build. `--profile-output PATH` names the `.hlpc` file (with `--watch`, the directory that holds one
capture per launch) and implies `--profile`. `--profile-start`, `--profile-duration`, `--profile-max-size`,
`--profile-window` and `--profile-min-call` control what is recorded and exported; [PROFILING.md](PROFILING.md) lists
them.

```sh
./scripts/haxeon run --profile=sampling -- --verbose
```

On Linux, macOS and Windows, `run --watch` rebuilds after edits to resolved package
sources and relaunches the host app after a successful build. Haxe source edits
use the compiler-only build path; FFI, manifest, and native source edits use the
full project build. A failed build leaves the running app open. Runtime output
is forwarded from `<output>.watch.log`. This mode restarts the process.

```sh
./scripts/haxeon run --watch --project path/to/haxeon.json -- --verbose
```

`run --watch --live` keeps a stable host process and applies compatible HLP
patches between application pump steps. The project entry class must expose
static `start(arguments:String):Void`, `tick():Int` (nonzero while running),
`saveState():String`, `close():Int`, and `restoreState(state:String):Void`, and,
like any entry class, a `main` (the live host never calls it).
The host calls `start` once, then `tick` repeatedly. A structural change reloads
the module through those state methods. Non-Haxe changes restart the process.
The output path must be separate from any ordinary app build output.

```sh
./scripts/haxeon run --watch --live --project path/to/live.json \
  --output build/host/live.hl -- --verbose
```

> **Warning: a watch session keeps the compiler it started with.** `run --watch` picks its compiler worker
> once, at the first build, and logs it as `haxeon: compiler worker version <hash> (kept for this watch
> session)`. Later rebuilds reuse that worker even if Haxeon's own compiler sources (`src/`, `stdlib/`)
> change, and nothing reports it. **After changing the compiler, restart the watch session** before you judge
> whether the change worked. This is deliberate: a live app can only be patched by the worker that holds its
> patch history, and not re-checking the compiler sources saves about 0.3 s per rebuild. See
> [LIVE_PATCHING.md](LIVE_PATCHING.md#artifact-builds-and-live-sessions).

Host builds resolve local path dependencies declared by package name. A
dependency can provide Haxe sources and optional C sources; C sources are
compiled into the HashLink native library requested by the build:

```json
{
  "version": 1,
  "package": { "name": "my-app" },
  "entry": "Main",
  "sourceRoots": ["src"],
  "dependencies": {
    "foo": { "path": "../foo" }
  },
  "target": "host",
  "outputDir": "build"
}
```

The `foo` package can list native inputs in its own manifest:

```json
{
  "version": 1,
  "package": { "name": "foo" },
  "sourceRoots": ["src"],
  "native": {
    "sources": ["native/foo.c"],
    "includeDirs": ["native/include"],
    "std": "c++20"
  }
}
```

The optional native `std` value controls compilation of package-owned C and
C++ sources. It is separate from the `std` value in an FFI recipe, which
controls Clang's header import and generated thunk compilation. CMake-backed
packages continue to declare their language standard in `CMakeLists.txt`.

`haxeon build --plan` prints the deterministic artifact and action plans.
Add `--explain` to show why each artifact is present, and `--timings` to print
resolution, planning/lowering, and execution wall-clock measurements.
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
CLI invocations (on Windows, only the compiled CLI; `scripts/haxeon.cmd` interprets
the CLI and compiles one-shot). Small source edits retain semantic compiler state; changes to the
source manifest, roots, defines, or FFI configuration reset it. Compiler or
standard-library changes select a fresh worker. Workers exit after
`HAXEON_COMPILER_IDLE_SECONDS` (default 90) without a request. Every build root
shares one per-user session directory (`$XDG_CACHE_HOME/haxeon/compiler`,
`%LOCALAPPDATA%\haxeon\compiler` on Windows, or `HAXEON_COMPILER_SESSION_DIR`) holding worker programs, connection metadata, and
logs, so the resident limits below apply to the whole machine. Set
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
`windows-x86_64-msvc`, `linux-x86_64-gnu`, `macos-aarch64`, `android-aarch64`,
and `wasm32`.

Git dependencies can be added and installed reproducibly:

```sh
./scripts/haxeon add --git https://github.com/example/foo.git --rev main foo
./scripts/haxeon install
./scripts/haxeon install --locked
./scripts/haxeon update
./scripts/haxeon tree
./scripts/haxeon why foo
./scripts/haxeon publish --registry local --version 1.0.0
./scripts/haxeon package check
```

`install` records the requested source and resolved Git commit in
`haxeon.lock`; `install --locked` rejects manifest changes and checks out the
exact recorded revision.

Registry sources use the same lockfile path. A registry index records immutable
release checksums, SemVer versions, yanked status, compatibility metadata, and
native provider metadata. For local development, `publish` writes an immutable
release and index below `~/.haxeon/cache/sources/registry`; projects then use
`{"registry":"local","version":"^1.0"}` and resolve through the normal
package graph.

Repositories can declare workspace members. A workspace member with the same
package name overrides an external dependency source while retaining the same
package identity:

```json
"workspace": ["packages/core", "packages/editor"]
```

Native packages may instead delegate an existing CMake project as one coarse
provider:

```json
"native": {
  "cmake": { "source": "native", "target": "foo" }
}
```

Native providers advertise their supported targets with `native.targets`; the
default source and CMake providers support `host` and `android`. If a package
has no provider for a requested target, planning stops with the package and
missing-provider chain—for example, `foo cannot be built for wasm32`—before
compilation or linking begins.

Packages can also gate resolution with compatibility metadata:

```json
"compatibility": {
  "haxeon": ">=0.3",
  "targets": ["host", "android"],
  "runtimeAbi": "2"
}
```

These requirements are checked while resolving the package graph, before any
compiler or native action is planned.

Haxelib is an adapter, not Haxeon's package model. A pure-Haxe Haxelib release
can be placed in the dedicated `~/.haxeon/cache/sources/haxelib/<name>/<version>`
cache (or supplied as an archive under its downloads cache); its `haxelib.json`
is translated to a normal Haxeon manifest. Haxeon does not read global
`haxelib dev` state or execute `extraParams`, macros, or HXML compiler settings;
unsupported settings fail with an explicit import diagnostic.

Android builds resolve the same package graph, compile `native.sources` with the
Android NDK, and expose the resulting ABI-specific shared libraries to Gradle
under `build/android-arm64/jniLibs/arm64-v8a`. A native package therefore gets
rebuilt and repackaged when its C sources change; Haxe-only edits continue to
use the Android HLB asset path.

The `doctor` command checks the local compiler, HashLink runtime, and Android
SDK tools. `platforms` lists CLI targets, and `devices` reports connected
Android devices. Wasm32 is build-only; host output runs through HashLink on the
current machine.

## Language server and FFI tools

- `haxeon lsp` is the Language Server Protocol server, over standard input and output; the VS Code extension starts it
  (`haxeon.server.path` and `haxeon.server.args`).
- `haxeon ffi import ...` imports C and C++ headers as HXI ([C_HEADER_FFI.md](C_HEADER_FFI.md)); a project's `ffi`
  recipes run it during the build.
- `haxeon ffi audit ...` imports one public header for several targets and compares their C ABIs.

`scripts/haxeon-lsp`, `scripts/haxeon-ffi-import` and `scripts/haxeon-ffi-audit` remain as names for the same commands.
The import one runs in the checkout's root, as it always has; `haxeon ffi import` resolves relative paths against the
directory it is run from, like every other command.

## Scripts

`haxeon script.hx [arguments]` (or `haxeon run script.hx ...`) builds one Haxe file and runs it, with no project to set
up, as `dotnet run app.cs` does:

- The file is the project's one source. Its directory is the source root its imports resolve in, so modules beside it
  can be imported, but other files there are not compiled.
- A `haxeon.json` beside the script makes that project a path dependency, with its source roots and dependencies.
- The build is quiet: its output appears, on standard error, only if it fails. The program runs in the directory the
  command was invoked from, with the given arguments, and its exit status is the command's.
- The project is written to `~/.haxeon/cache/scripts/<digest of the script's path>` (`HAXEON_SCRIPT_CACHE` names
  another directory), and the incremental build makes an unchanged script's next run cost a launch. A script's cache
  is removed after 30 days without a run.
- A first line `#!/usr/bin/env haxeon` makes the file executable where the shell reads such lines; Haxe accepts that
  line at the start of a file, and so do Haxeon's compiler and formatter.
- The file's name is its module's, dashes included (`check-self-hosting.hx`); a script is never imported by name, so it
  need not be an identifier. Only a further dot (`a.b.hx`) is refused, since it would read as a package.

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
./scripts/haxeon workspace test --workspace materia.workspace.json --skip-tag cadkit --skip-tag mujoco
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
  compiles, each of which holds a compiler heap. Every project keeps its own compiler worker. Across all build
  roots, at most `HAXEON_COMPILER_WORKERS` (default 4) stay resident and, on Linux, their total resident memory
  stays within `HAXEON_COMPILER_MEMORY_MB` (default 4096); the least recently used workers are retired first, and a
  project's workers from older compiler versions are retired immediately.
- With Ninja 1.13 or newer (`scripts/bootstrap-tools.sh` installs a pinned copy under `.tools/ninja`), a GNU
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
