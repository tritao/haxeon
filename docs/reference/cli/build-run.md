# Build & run

## build

An app builds through its runner project, the CMake project for each platform that `haxeon create` writes beside the
sources (`linux/`, `macos/`, `windows/`), which is the app's to change (the executable's name, the bundle's Info.plist, the
version resources, packaging): `haxeon build` compiles the module,
writes `build/generated/PLATFORM/haxeon.cmake` and builds this machine's runner with CMake into `build/PLATFORM/app/`,
where the executable (named after the package), its module and its native packages' libraries sit together, or on macOS
make the bundle `NAME.app`; on Windows it builds with MSVC, as a Windows program (no console window from Explorer).
`cmake -S linux -B DIR &&
cmake --build DIR` (or `macos`, `windows`) builds the same app once a build has written the fragment. Building for a
platform the app does not list, or without its
runner, is a usage error that names `haxeon create .`.

Paths in the project file are relative to that file. Console host builds write
`build/host/main.hl`, which the VM runs. A console project's release build (`--build-mode release`) compiles it ahead of
time into `build/OS/bin/NAME` (`linux`, `macos` or `windows`; `NAME.exe` on Windows), where `NAME` is the package name,
with the shared libraries of its native packages beside it: that directory is what you ship, and the executable runs
from wherever it is copied. It needs a C toolchain and CMake. Web app bundles go to `build/web/wasm32/` or
`build/web/wasm-gc/`, ready to serve over HTTP. Console Wasm builds write just
the module in `build/wasm32/` or `build/wasm-gc/`.
Android builds package `build/android/app-debug.apk` through the app's Gradle
runner. Use `--gradle-inputs FILE` to prepare a standalone Gradle build.

Android app runners build native CMake packages with Gradle's NDK toolchain once per ABI.
The APK contains the resulting libraries, the generated Haxe assets and the SDK host.

Serve web bundles over HTTP to run them in a browser. Host development modules run through HashLink on the current machine.

```sh
haxeon build
haxeon build --plan
haxeon build --jobs 8
haxeon build --build-mode release
haxeon build --target wasm32
haxeon build --target android
```

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

A worker sets its own collector policy (`compiler.tools.ProcessMemory`): it runs a full collection after each compile's
response has been sent, and during a compile it collects only once it has allocated three quarters of what the last
collection found alive. A small edit therefore usually runs without a collection, and the worker's peak stays a bounded
multiple of its session's live data. A request that arrives during that collection waits for it to finish.

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

`build --compiler-only --patchable` builds the module as a patching watch does,
for a host that applies the patches itself (a phone's, say): the compiler worker
keeps the module's history, so each later `build --compiler-only --patchable`
publishes an `.hlp` patch and its `.live.*` descriptions beside the module.

### Targets and backends

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

The target chooses the backend: host development builds and Android builds use `hl`, and each Wasm target selects its corresponding backend.
Host console and desktop app release builds use `hlc`, then CMake compiles the C into an executable.
For a standalone C build, the direct compiler's `--target=hlc` writes the C to `OUTPUT.c/` for a C toolchain. A CMake project builds it with the SDK's CMake package: after `find_package(Haxeon)`,
`haxeon_add_c_executable(TARGET SOURCES_DIR OUTPUT.c [DEVELOPMENT])` makes the executable, with the C compiler CMake
chooses (`CC`, `-DCMAKE_C_COMPILER`). Haxe's `--hl FILE.hl` is the target `host` with the backend `hl`,
and a Haxe target name given to `--target` is refused with Haxeon's (`--target hl` says to use `host`).

## check

`haxeon check` types the project's program as `haxeon build` would and reports the same diagnostics, but generates and
writes nothing: the compiler takes the request as `--no-output`, Haxe's name for it. It runs only the compile (and the FFI
imports the compile reads, never the native libraries), for the project's target or `--target`, and takes `--define`,
`--build-mode`, `-v`, `--color`, `--diagnostic-format` and `--timings` as `build` does. It shares the build's compiler
session, so a check after a build, or a build after a check, reuses what the other typed. It exits with 1 when the program
has an error.

A package whose manifest sets `package.documentation = "required"` also has every public declaration of its own modules
checked for a doc comment ([E1032](../ERRORS.md#e1032-public-declaration-without-a-doc-comment)). The check then types every
module of the package, as `haxeon doc` does, not only what the entry reaches. A package that depends on it is not checked
for it.

```text
Checking my-app (host)…
✔ No errors (0.3 s)
```

## doc

`haxeon doc` types the project as `haxeon check` does and writes a description of its public API to `build/api.json`, or
to `--output`: every public type, member, and module-level function and variable, with its signature, its doc comment and
where it is declared. A package's API is its own modules, without what it declares `internal`, which the description marks
and the reference leaves out; it reaches what they use, so a type the API refers to is in the description as well, and the file lists which modules
are the API (`described`). A library needs no `entry`. Types are written as the source writes them, so a signature keeps
the names of the typedefs it uses. The format is Haxeon's own JSON, versioned. A package that requires its documentation
fails `haxeon doc` as it fails `haxeon check`, on each public declaration without a doc comment.

`haxeon doc --standard-library` describes the standard library instead, with no project: each of its modules for the
target (the host's unless `--target` names another), into `build/api.json` of the directory it runs in, or to `--output`.
The standard library belongs to no package, so its sources are given relative to the directory `stdlib` is in.

```sh
haxeon doc
haxeon doc --output docs/ui-api.json
haxeon doc --standard-library --output std-api.json
```

## run

`haxeon run` runs the app executable, or a console project's module on the VM, and `--watch` runs the module it rebuilds
in it. `haxeon run --build-mode release` builds and runs the release executable, passing the arguments after `--` to the
program; a release build cannot be watched.

```sh
haxeon run
haxeon run --quiet -- arguments
haxeon run --target android
```

`--device SERIAL` selects one of several connected Android devices. See
[Android](../ANDROID.md) for prerequisites and live editing. Use
`--project path/to/haxeon.toml` (or the project's directory) to select another project, repeat
`--define NAME[=VALUE]` to add conditional defines, and pass arguments to a
running program after `--`:

```sh
haxeon run -- --verbose
```

An app's window takes the host's standard flags after `--`, so a test or a script can run any app without code of its
own: `--frames=N` stops after N rendered frames, requesting redraws while idle. `--capture=DIR` writes diagnostics to DIR
and on X11 saves an image of the app window as `frame.png`.
`--capture-seconds=S` captures after S seconds instead, and `--input-script=PATH` plays timed input
(`haxeon.ui.host.DesktopUiHostOptions.withArguments`):

```sh
haxeon run -- --frames=10 --capture=out/capture
```

A program's standard output flushes at once on a terminal and is buffered into a pipe
or a file. It is flushed before a read from standard input, a subprocess, a sleep and
exit, and a fatal signal attempts a last flush; SIGKILL can lose the buffered tail.
`Sys.stdout().flush()` flushes explicitly, and `HL_STDOUT_FLUSH=1` flushes after every
print (`haxeon script.hx` sets it, so a script's lines appear as they are printed).

### Debugging

`run --debug-port PORT` builds a host development project and waits for a debugger on a loopback port
before entering the program. The VS Code extension provides F5 launch and a local attach configuration.
See [Debug in VS Code](../../guides/00-get-started.md#debug-in-vs-code).

For function breakpoints during debugging, set `inline = false` in `haxeon.toml`; inlining is on otherwise. The
choice applies to the root project's compilation, including dependencies, and participates in action and compiler memo
fingerprints. It does not disable the other IR passes. Direct compiler calls turn it off with `--no-inline`.

### Profiling

`run --profile[=SOURCES]` launches the program under `hl --diagnostics`, records it with `hlprof-live` into an HLPC
capture directory (`profile.hlpc`, `profile.pftrace`, `capture.json`, the bytecode) and prints a report when it ends.
`SOURCES` is a comma list of `instrument`, `sampling` and `alloc`; without a list the default is `instrument`, which
runs the instrumented build. `--profile-output PATH` names the `.hlpc` file (with `--watch`, the directory that holds one
capture per launch) and implies `--profile`. `--profile-start`, `--profile-duration`, `--profile-max-size`,
`--profile-window` and `--profile-min-call` control what is recorded and exported; [PROFILING.md](../PROFILING.md) lists
them.

```sh
haxeon run --profile=sampling -- --verbose
```

### Watch mode

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
of reloading ([LIVE_PATCHING.md](../LIVE_PATCHING.md#strict-mode)); it is an error
with `--restart` or for an app the watch would restart.

```sh
haxeon run --watch --project path/to/haxeon.toml -- --verbose
haxeon run --watch --restart --project path/to/haxeon.toml
```

Besides the console, `run --watch` appends what it does with each edit to `<output>.watch-events.jsonl`, one JSON
object per line, and passes that path to the app in `HAXEON_WATCH_EVENTS`: `rebuild-started` (with `changedFiles`),
one `output-line` per line the build printed, `build-failed` or `build-ok`, and when it patches `patch-published`
(`revision`, `reloadReasons`). The live host adds `patch-applied`, `patch-rejected` (a refused patch or a failed
reload, with `message`) and `reload`. The file starts empty with each watch and moves to `<file>.1` past 4 MiB.

> A watch session keeps the compiler it started with. Restart the session after changing the compiler.
> See [Live patching](../LIVE_PATCHING.md#artifact-builds-and-live-sessions).

## SCRIPT.hx

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

## FILE.hxml

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
checked. The checker's rules are in [LANGUAGE_SUPPORT.md](../LANGUAGE_SUPPORT.md#null-safety), "Null safety".

Each compilation is a project the CLI makes in memory, as it does for a script, and builds like any host project. Its
build state lives in the CLI's cache, `~/.haxeon/cache/hxml/<digest>` (`HAXEON_HXML_CACHE` names another directory), one
per working directory, entry and output, so a second build is incremental; nothing is written to the working directory but
the module, copied to the `--hl` path. A compilation's cache is removed after 30 days without a build, as a script's is.

### Direct compiler options

A compile states its passes and self-checks as flags, never through the environment, so one compile server serves any
mix of them: `--no-inline`, `--no-load-store-forwarding`, `--no-strength-reduction`, `--no-early-prune` (a migration
reference for the reachability walk), `--check-reuse` (compare everything a compile reuses with a fresh build; slow, for
the test suites), `--no-verify-ir` and `--verify-ir`, and `--wasm-legacy-exceptions`. The IR verifiers check each
function's CFG and the final HashLink IR before lowering; a release build (`--build-mode=release`) skips them unless
`--verify-ir` is given, and the test driver always gives it.

A compile server keeps a session between requests and builds on it (`--session=reuse`, the default); a request with
other settings starts it over anyway. `--session=fresh` starts it over before compiling, so the result depends on the
request alone, never on what the server compiled before.

`--null-safety=MODE[:PATH[:shallow]]` gives the classes and abstracts at the dot path `PATH` (every one when it is left out) the
null-safety mode `MODE` (`off`, `loose`, `strict`, `strict-threaded` or `warn`), as Haxe's `nullSafety(PATH, MODE)` does;
`:shallow` keeps a package's rule out of its subpackages. The flag may repeat. A build passes one per package path from each
package's `nullSafety` setting ([MANIFEST.md](../MANIFEST.md#null-safety)) and one per `--macro nullSafety(...)` of a Haxe command
line.

## workspace

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

Repositories can declare workspace members. A workspace member with the same
package name overrides an external dependency source while retaining the same
package identity:

```toml
workspace = ["packages/core", "packages/editor"]
```

### workspace plan

Prints the merged graph and how many actions were shared. `--actions` lists them.

### workspace build

Builds the projects in the merged graph with a shared job limit.

### workspace test

- Runs each project's compiled module and writes its output to `<buildDir>/tests/<name>.log`. A passing run
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
