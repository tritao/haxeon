# Development

## 🚀 Run the proof of concept

Initialize the pinned tools, verify formatting, bootstrap the compiler, and run
the integration suites:

```sh
./scripts/bootstrap-tools.sh
./scripts/format.sh --check
./scripts/bootstrap-status.sh
./scripts/bootstrap-compiler.sh
./scripts/bootstrap-compiler.sh --self
./scripts/test.sh
./tests/integration/test-hot-reload.sh
```

### Test suites: `haxeon dev test`

Every suite is one line of `tests/suites.txt`, in the order it runs, with its groups and how it is scheduled (the file's header
documents the format). `scripts/haxeon dev test MODE` runs a mode: `quick`, `wave` (quick and wave), `ci` (what CI runs) or `full`
(all of them, each suite once). Before the first suite it builds the native runtime and resolves the prebuilt tools, once. Every suite
runs even when an earlier one fails, and the exit code is 0 only if all that ran passed. Each suite writes a log to `out/test/<time>-<mode>/`,
next to `summary.txt`.

```sh
./scripts/test.sh                                  # dev test ci; TEST_JOBS sets the jobs (default 16), SKIP_FORMAT_CHECK=1 skips the format check
./scripts/test.sh --only driver-default,wasm-backend
scripts/haxeon dev test full --list                # the suites a mode runs, with their lanes and pools
./scripts/gate.sh quick|wave|full [jobs]           # dev test MODE --gate: a report in out/gate (docs/TEST_SUITE_COST.md section 8)
```

A new suite is a line in `tests/suites.txt`, not a stage in a script. Give it the groups it belongs to; put it in a `lane` or `pool`
only when it shares no files with what runs beside it. Invoke the driver directly to select a driver suite or test:

```sh
.tools/haxe/haxe -cp tests --run driver.TestDriver --suite programs --jobs 16
.tools/haxe/haxe -cp tests --run driver.TestDriver --suite compiler --test ParserRecovery
```

The cross-platform Haxe build entry point provides the native build, bootstrap,
and core test workflow without Bash. This is the path used by Windows CI:

```sh
.tools/haxe/haxe common.hxml --run build.HaxeonBuild native
.tools/haxe/haxe common.hxml --run build.HaxeonBuild bootstrap-self
.tools/haxe/haxe common.hxml --run build.HaxeonBuild test 16
```

### Building the compiler's sources from outside (the contract)

The class paths of the compiler are listed once, in `common.hxml` (`src` and `lib/haxeon-io`). Anything that builds or runs these sources
with stock Haxe, in this repository or in another one (the editor's project-module builds do), passes `common.hxml` and adds only its
own class paths:

```sh
.tools/haxe/haxe --cwd <haxeon root> common.hxml -cp <tool sources> -main <Tool> -hl <output.hl>
```

Do not list `src` (or any other directory of this tree) by hand: a source that moves to a directory `common.hxml` does not list breaks
every external tool, and a hand-written list is exactly what missed `lib/haxeon-io` when `haxeon.io` moved there. A tool that caches its
build by hashing sources must hash the directories `common.hxml` names, not a fixed pair. `tests/integration/test-external-tool-build.sh`
builds and runs a small external tool this way and is part of the wave gate.

### Prebuilt tools: `haxeon dev tool-path`

Scripts in this tree do not build their own copy of the compiler or another entry point. They ask for it by main class and get a cached
HashLink build:

```sh
compiler=$(scripts/haxeon dev tool-path compiler.tools.HaxeonCompiler)   # the compiler CLI
main=$(scripts/haxeon dev tool-path Main)                                # the compiler entry the driver uses
probe=$(scripts/haxeon dev tool-path --cp tests/runtime RuntimeBuildSafetyProbe)
```

Builds live in `out/tools/<main>-<key>.hl`. The key hashes `common.hxml`, every file under its class paths and any `--cp` directories,
the pinned Haxe binary and its standard library, and the `--define` values, so an unchanged tree reuses the last build and any edit
gets a new one. stdout is only the path; build diagnostics go to stderr. The newest three builds of each main are kept, and older ones
are removed once they are an hour old. A build in `out/tools` does not sit next to `haxeon_runtime.hdll`, so run it with
`out` and the HashLink directory on the library path, as every launcher here does.

`HAXEON_MAIN_HL`, `HAXEON_COMPILER_HL` and `HAXEON_BUILD_HL` remain as pins: when set, a script uses that exact build instead
(a frozen control compiler, for example). `haxeon dev test` resolves the tools once and exports them, so every suite of one run uses
the same builds even if the sources change while it runs.

`bootstrap/compiler.hl` is checked in. For ordinary compiler development,
`bootstrap-compiler.sh --self` rebuilds it with the checked-in compiler and
pinned HashLink without invoking the reference Haxe compiler.

The full bootstrap uses pinned reference Haxe to build the compiler, then asks
that compiler to build itself and requires byte-for-byte equality. Both modes
derive the same sorted source manifest from `src/` and build the native runtime
bridge before compilation.

The writer currently targets HashLink bytecode format version 6, matching the
decoder in `src/code.c`.

## API documentation

Haxeon recognizes Haxe documentation comments beginning with `/**`. Their
Markdown and `@param`, `@return`/`@returns`, `@deprecated`, `@see`, `@throws`,
`@exception`, and `@since` tags are shared by editor hover, completion, and
signature help.

The compiler can also emit deterministic Haxe type-description XML for tools
such as [dox](https://github.com/HaxeFoundation/dox):

```sh
compiler.hl --xml=docs/api.xml --output=out/app.hl \
  --entry=my.app.Main --root=src src/my/app/Main.hx
haxelib run dox -i docs -o docs/html
```

Both `--xml=docs/api.xml` and the standard two-argument form
`--xml docs/api.xml` are accepted. Documentation generation does not change
runtime fingerprints or hot-reload compatibility.

## Language server workspace discovery

Workspace discovery needs bounds for folders inside large trees. A test workspace rooted inside the checkout caused discovery to traverse the whole checkout for 49:48.88 and peak at 1,972,216 KB RSS; moving the fixture to the OS temp directory reduced the same run below one second. Opening a real editor folder inside a large tree can hit the same path. Follow up by stopping at project manifests, skipping `out`, build, `.git` and ignored directories, and capping or indexing large trees.

## Native build

Haxeon uses CMake for its cross-platform native build and Ninja as the default
backend. HashLink is built from the pinned `vendor/hashlink` submodule; the
resulting VM and library are placed in `.tools/hashlink`, while Haxeon's runtime
HDLL is placed in `out`.

The Release preset owns those shared tool paths. The Debug preset writes its VM
and runtime HDLL under `out/cmake/dev` so a development build cannot replace
the optimized VM used by profiler captures and normal project commands.

```sh
cmake --preset release
cmake --build --preset release
```

The same build can be driven by the cross-platform Haxe entry point:

```sh
.tools/haxe/haxe common.hxml --run build.HaxeonBuild doctor
.tools/haxe/haxe common.hxml --run build.HaxeonBuild native release
```

On a fresh Windows checkout, run `scripts/setup.ps1` from a Visual Studio
developer shell. It installs the pinned tools and selects the `windows-msvc`
preset. The CI job also builds and tests `windows-msvc-debug`, which uses the
matching MSVC Debug CRT. Later native-only builds can use
`scripts/build-native.ps1`. Unix environments may use
`scripts/bootstrap-tools.sh` followed by
`scripts/build-native.sh`; macOS CI covers both Intel and Apple Silicon, with
the latter using HashLink's AArch64 JIT. The `macos-arm64` preset can also be
used for an explicit arm64 build on Darwin. Set `HAXEON_CMAKE_PRESET` to
override the wrapper's default preset.

Linux AArch64 hosts need `qemu-user` and `libc6-amd64-cross`: the pinned Haxe
release is currently Linux x86-64, so the shared bootstrap keeps the normal
`.tools/haxe/haxe` path and runs that compiler through an explicit QEMU
wrapper. The native HashLink and runtime still build and execute for AArch64.

Pinned tool versions, archive checksums, extraction, and submodule setup are
defined once in `cmake/Bootstrap.cmake`. The platform setup scripts are thin
launchers for that shared bootstrap rather than separate installers.

Haxe sources use the repository-pinned Haxe Formatter:

```sh
./scripts/format.sh
./scripts/format.sh --check
```

`bootstrap-status.sh` runs the real lexer, parser, and typer over the compiler
source tree and reports bootstrap progress. Pass `--json` for a machine-readable
dashboard.

