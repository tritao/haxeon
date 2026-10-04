# Project CLI and builds

The project CLI creates a small `haxeon.json` manifest, builds HashLink programs
for the current desktop host, experimental Wasm32 modules, and Android APKs, and
can launch host programs or install and launch an Android app. The same command
is available on Unix-like systems and Windows:

On Unix-like systems, `scripts/haxeon` compiles the CLI to cached HashLink
bytecode when its sources change, then runs that bytecode. If HashLink is not
installed yet, the script uses the pinned Haxe interpreter for bootstrap and
diagnostic commands.

```sh
./scripts/haxeon init
./scripts/haxeon doctor
./scripts/haxeon platforms
./scripts/haxeon build
./scripts/haxeon build --plan
./scripts/haxeon build --jobs 8
./scripts/haxeon run
./scripts/haxeon build --target wasm32
./scripts/haxeon init --target android
./scripts/haxeon build --target android
./scripts/haxeon run --target android
./scripts/haxeon devices
./scripts/haxeon fmt src/Main.hx
./scripts/haxeon fmt --check src/Main.hx
cat src/Main.hx | ./scripts/haxeon fmt --stdin --line-width 100
```

`haxeon fmt` uses Haxeon's built-in lossless formatter. It rewrites files by
default, while `--check` reports files that would change. Use `--stdin` for
editor or pipeline integration, `--line-width` to set the column limit, and
`--tab-size` with `--use-tabs` to control indentation.

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
builds go to `build/android/app-debug.apk`. Android projects require a
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

On Linux and macOS, `run --watch` rebuilds after edits to resolved package
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
directory when running dependents. Omit `library` for CMake targets that produce
the package's `<package>.hdll` output themselves.
Native implementation changes do not invalidate independently compiled bytecode;
Haxe sources, FFI interfaces/projections, compiler sources, and the standard
library still do. Failed native builds still block the project build and launch.

On Linux and macOS, host builds reuse a private compiler worker between CLI
invocations. Small source edits retain semantic compiler state; changes to the
source manifest, roots, defines, or FFI configuration reset it. Compiler or
standard-library changes select a fresh worker. Workers exit after
`HAXEON_COMPILER_IDLE_SECONDS` (default 90) without a request. Every build root
shares one per-user session directory (`$XDG_CACHE_HOME/haxeon/compiler`, or
`HAXEON_COMPILER_SESSION_DIR`) holding worker programs, connection metadata, and
logs, so the resident limits below apply to the whole machine. Set
`HAXEON_COMPILER_SERVER=0` to use one-shot compilation, which runs the compiler
as a HashLink program compiled once per compiler version (Windows interprets it). Windows, explicit `--self-hosted` builds, and unavailable workers
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

