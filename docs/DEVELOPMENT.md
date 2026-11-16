# Development

## Setup

```sh
./scripts/bootstrap-tools.sh             # pinned Haxe and submodules
./scripts/build-native.sh                # HashLink and the runtime HDLL
./scripts/test.sh --only driver-default  # the test driver: compiler and program cases
```

`scripts/test.sh` with no arguments runs everything CI runs, which is slow. While working on a change, run the suite or the
single test it touches (see Tests) and leave the full run to CI. On Windows, see [Native build](#native-build).

## Tests

Every suite is one line of `tests/suites.txt`, in the order it runs, with its groups and how it is scheduled (the file's header
documents the format). `scripts/haxeon dev test MODE` runs a mode: `quick`, `wave` (quick and wave), `ci` (what CI runs) or `full`
(all of them, each suite once). Before the first suite it builds the native runtime and resolves the prebuilt tools, once. Every suite
runs even when an earlier one fails, and the exit code is 0 only if all that ran passed. Each suite writes a log to `out/test/<time>-<mode>/`,
next to `summary.txt`.

```sh
./scripts/test.sh                                  # dev test ci; TEST_JOBS sets the jobs (default 16), SKIP_FORMAT_CHECK=1 skips the format check
./scripts/test.sh --only driver-default,wasm-backend
scripts/haxeon dev test full --list                # the suites a mode runs, with their lanes and pools
./scripts/gate.sh quick|wave|full [jobs]           # dev test MODE --gate, 4 jobs by default: a report in out/gate (docs/reports/2026-11-test-suite-cost.md section 8)
```

A new suite is a line in `tests/suites.txt`, not a stage in a script. Give it the groups it belongs to; put it in a `lane` or `pool`
only when it shares no files with what runs beside it. A test script, `tests/hxml` file or test main that no suite, driver case
or workflow runs fails the `test-registration` suite (`scripts/haxeon dev check-tests`) unless `tests/unregistered.txt` lists it
with its reason.

`scripts/test-driver.sh [jobs]` runs the test driver alone, and the options after the job count select cases. The driver's
suites are `compiler`, `programs`, `runtime` and `tooling`; `--test` takes a regular expression over case names:

```sh
scripts/test-driver.sh 16 --suite programs
scripts/test-driver.sh 4 --suite compiler --test ParserRecovery
scripts/test-driver.sh 1 --list
```

The script runs the driver with private copies of the VM and runtime, so a native rebuild cannot overwrite a library the
driver has loaded, and compiles program cases with the prebuilt compiler. `HAXEON_TEST_INTERPRETED=1` makes it compile them
with `haxe --run Main` instead, for debugging the compiler's sources under the Haxe interpreter. Running
`haxe --run driver.TestDriver` by hand skips that setup: it needs the checkout's `hl` on `PATH` and the runtime on the library path.

Without Bash, the same workflow runs through the build entry point with the pinned Haxe. `scripts/test-driver.sh` and
`scripts/bootstrap-compiler.sh` are wrappers around it, and this is what Windows CI runs (`.tools\haxe\haxe.exe` there):

```sh
.tools/haxe/haxe common.hxml --run build.HaxeonBuild doctor       # check git, cmake, ninja and the pinned Haxe
.tools/haxe/haxe common.hxml --run build.HaxeonBuild native       # the CMake build; the release preset, or windows-msvc on Windows
.tools/haxe/haxe common.hxml --run build.HaxeonBuild bootstrap    # scripts/bootstrap-compiler.sh
.tools/haxe/haxe common.hxml --run build.HaxeonBuild test 16      # the test driver; 4 jobs by default, same options
```

## Formatting

Haxe sources are formatted by `haxeon fmt` ([CLI.md](reference/CLI.md)), with imports sorted by `haxeon lint`. This tree has no
`format` setting, so it uses the standard style: tabs and 120 columns. `--check` covers every `.hx` file outside vendored code; a
test file whose lines are part of the test carries `@formatter:off` at the end of its first line.

```sh
./scripts/format.sh                        # haxeon dev format
./scripts/format.sh --check
./scripts/format.sh --changed              # only files that differ from the merge base with origin/main
scripts/haxeon fmt --check FILE...         # exactly these files
```

## Bootstrapping and self-hosting

The compiler builds itself. Three scripts cover that:

- `scripts/check-self-hosting.sh` is the check to run after a compiler change, and CI runs it. It builds a seed by running the
  sources under the pinned Haxe interpreter, builds stage 1 with the seed and stage 2 with stage 1, and requires stages 1 and 2
  to be identical. It does not use the checked-in compiler.
- `scripts/bootstrap-compiler.sh` refreshes the checked-in compiler, `bootstrap/compiler.hl`. It builds the native runtime,
  builds a seed with the pinned Haxe, then has each stage build the next until two consecutive stages are byte-identical (at most
  eight), and copies the result over `bootstrap/compiler.hl` and `bootstrap/compiler.hl.functions`.
- `scripts/bootstrap-compiler.sh --self` rebuilds the sources with `bootstrap/compiler.hl`, without the reference Haxe compiler,
  and requires the output to be byte-identical to it. It passes only when the checked-in compiler was refreshed from the current
  sources, so it fails after any compiler change until the refresh is committed. CI does not run it.

Both bootstrap modes compile the same sorted manifest of every `.hx` file under `src/`, `lib/` and `stdlib/`.

`scripts/bootstrap-status.sh` runs the real lexer, parser and typer over the compiler source tree and reports bootstrap
progress. Pass `--json` for a machine-readable dashboard.

The writer emits HashLink bytecode format version 8 (`HlCode.VERSION`), the newest the decoder in
`vendor/hashlink/src/code.c` accepts.

## Prebuilt tools: `haxeon dev tool-path`

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

`bootstrap/compiler.hl` is not one of these builds; see the section above.

## Building the compiler's sources from outside (the contract)

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

## Native build

Haxeon uses CMake for its cross-platform native build and Ninja as the default
backend. HashLink is built from the pinned `vendor/hashlink` submodule; the
resulting VM and library are placed in `out/cmake/<preset>/hashlink-runtime`
(`scripts/hashlink-path.sh` prints the directory), while Haxeon's runtime HDLL is
placed in `out`.

The `release` preset owns those shared tool paths. The Debug preset, `dev`, writes its VM
and runtime HDLL under `out/cmake/dev` so a development build cannot replace
the optimized VM used by profiler captures and normal project commands.

```sh
cmake --preset release
cmake --build --preset release
```

`scripts/build-native.sh` runs those two commands, and `build.HaxeonBuild native [preset]` runs the same build without Bash.

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

## Performance rules for compiler code

- **Iterating a Map goes through dynamic calls in the stock-Haxe worker.** An iterator is a structural type, so `for (x in map)`,
  `for (k => v in map)` and `map.keys()` make a dynamic call per element (about 3% of a cold build before the hot sites were fixed). On a
  hot path keep an array next to the map, filled where entries are added, and iterate that. The Haxeon-built worker (ADR 0003 section 12)
  may make this moot; until then it is measured, not folklore.
- **Hash a name once.** A name used for several lookups in a pass (a callee, a local) is looked up once to get a dense number, and the
  per-name state after that is an array indexed by it (see `SsaBuilder`, `IrInliner`).
- **Allocation sites come from the allocation census, not the profiler.** `HAXEON_COMPILER_ALLOC_CENSUS=<file>` on a build and
  `scripts/alloc-sites.py <file>` rank where a build allocates (stacks sampled by bytes, exact counts by type). The profiler's alloc samples
  carry only the allocator's return address and cannot name a site.
- **Do not build a key or a list to look something up or to iterate once.** A prefix test with `a + "."` per element, a `[x, y]` literal returned
  from a helper that callers only loop over, and a `"len:owner:field"` map key each allocate per call; the census found them at 6.9%, 4.4% and 1.7% of a
  cold build's bytes. Group once and look up by the parts (`IrInlineEnumEligibility`, `IrOptionalFieldStorage`), or give the helper `count`/`at`
  (`IrOperands`). A callback is no substitute: a closure that captures allocates at each call.
- **A new map keyed by a string that a pass fills and a hot loop reads is a candidate for the two rules above**; check a profile share before
  and after (`hlprof-live`, folded stacks), not the wall time of a loaded machine.
