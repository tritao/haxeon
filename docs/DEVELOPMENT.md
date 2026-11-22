# Development

## Setup

```sh
./scripts/bootstrap-tools.sh             # pinned Haxe and submodules
./scripts/build-native.sh                # the VM: HashLink with the Haxeon runtime compiled in
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

It is `haxeon dev test-driver` after a native build. The driver compiles program cases with the prebuilt compiler;
`HAXEON_TEST_INTERPRETED=1` makes it compile them with `haxe --run Main` instead, for debugging the compiler's sources under the
Haxe interpreter. Running `haxe --run driver.TestDriver` by hand skips that setup: it needs the checkout's `hl` on `PATH` and
`out` (the test libraries the driver's programs load) on the library path.

Programs compile in compile servers (`compiler.tools.CompilerServer`), one after another in each, every compile in a fresh session.
Two options check that a server's history cannot change a build. `--check-reuse` rebuilds each program warm after edits and
compares it with a fresh build of the same text. `--check-isolation` also compiles each program's live build in a server started
for it alone, which must write the same bytes as the shared server, whatever that compiled before; a difference is state a
compile left in the process, which `CompilerStaticsMain` keeps out of compiler statics. The `driver-checked` and
`driver-isolated` suites run them. Program cases build in development mode unless `--release` is given, which makes their plain
builds release builds (`driver-release`), the mode tools ship in.

### Performance guard

The `perf-guard` suite (`scripts/perf-guard.py`) builds the compiler from the checkout in release mode and measures that build
compiling a frozen input: the compiler's sources at the revision `input_revision` in `tests/perf/self-compile-baseline.json`
names, extracted with `git archive`, so every checkout is measured on the same program and a change that adds code does not
grow its own input. It measures allocated bytes and collections (from the driver's allocation phases), live data at the
phase boundaries (from a heap census taken there in a second run), peak RSS (an outcome of the collection schedule, so gated
loosely), and
main-thread `instructions:u` (and `cycles:u`, printed, never compared) where perf is installed and `perf_event_paranoid` is at most 2 (on CI runners it is not, and the
metric is skipped). Wall time is printed, never compared. It measures on Linux x86-64 only and passes elsewhere.

It then measures incremental builds, which the one-shot compile never exercises: the same build's compile server, whose session
keeps its state, on a copy of the frozen input, through a cold build, two no-op rebuilds, a body-only edit of the entry module made
and taken back six times, and an optional argument added to `InternalError`'s constructor, which most modules call. For each it
gates allocated bytes and the functions retyped, artifacts invalidated and functions regenerated (the `HAXEON_EXPLAIN_INVALIDATION`
counts); wall is printed. A heap census at the end of every build gives the session's live data after the last body edit and its
growth over the last two, which stays near zero unless the session keeps something from every build. A second session of the
server, without those reports, gates edit latency: main-thread `instructions:u` of the body edit and of the signature edit, from
`perf stat --per-thread` attached to the server around each build (skipped where perf is not available). This part adds about
three minutes.

The small-project part runs the CLI as a user does: a cold `haxeon build` and `haxeon check` of `tests/perf/small-project`, from
no compile server running to the server's exit, so the CLI's start, the server's start and the compile all count. It gates the
instructions of every process the command starts and the bytes the server allocated for the request; the CLI's wall is printed.
`--only=self-compile`, `--only=incremental` or `--only=small-project` runs one part.

Every metric fails the run beyond its tolerance, but the primary ones are what the compiler is optimized for, in this order:
edit latency in the compile server, startup (the small project's cold build and check), and the server's live data, weighted
above the one-shot peak. They are marked `*` and summed up in the first line of the summary the run ends with. The cold
self-compile (instructions, wall, peak, allocation, live data) and the incremental allocation and function counts are regression
guards.

Each metric is compared with `tests/perf/self-compile-baseline.json`, `tests/perf/incremental-baseline.json` or
`tests/perf/small-project-baseline.json`, which hold its
value and tolerance and why the tolerance is what it is. Above the tolerance the suite fails; below it the suite passes and asks
for the baseline to be updated, so a gain is locked in. Moving `input_revision` (when the old sources no longer compile, or to
follow the compiler's growth) re-baselines every metric in the same commit. A change that moves the values on purpose (a feature that costs memory, an optimization) updates the baseline in the same
commit, from a quiet Linux x86-64 machine:

```sh
python3 scripts/perf-guard.py            # measure and compare
python3 scripts/perf-guard.py --update   # write the measured values into the baselines; tolerances are kept
```

The incremental edits are anchored on a line of `HaxeonCompiler.main` and on `InternalError`'s constructor (`BODY_EDIT` and
`SIGNATURE_EDIT` in the script); a change that removes an anchor makes the suite say so, and picks another of the same kind.

Say in the commit message what moved and why. A tolerance is changed by editing the file, with its `why`.

### The same commands on every platform

Setup is two CMake invocations, wrapped by a script per shell. Everything after that is the `haxeon` command, spelled the
same everywhere. It is a native executable the build puts beside `hl`: the same VM, running the CLI's bytecode, which the
build compiles with the pinned Haxe and publishes next to it (`native/haxeon_main.c`). It belongs to the checkout it was built
in, which it names in `HAXEON_HOME`, and needs no library path, so its directory can go on `PATH`.

`scripts/haxeon` (Unix) and `scripts\haxeon` (`haxeon.cmd`, `haxeon.ps1`; Windows) run it after bringing it and the CLI's
bytecode up to date with `cmake --build <build> --target haxeon-command`, so an edit to the CLI is in the next command. That
check costs about a tenth of a second; `HAXEON_NATIVE_READY=1` skips it, as the suite runner does after its own native build.

| Step | Command | Unix wrapper | Windows wrapper |
|---|---|---|---|
| Pinned tools and submodules | `cmake -P cmake/Bootstrap.cmake` | `scripts/bootstrap-tools.sh` | `scripts/setup.ps1` |
| The VM, first build | `cmake --preset P`, `cmake --build --preset P` | `scripts/build-native.sh` | `scripts/build-native.ps1` |
| The VM, rebuilt | `haxeon dev native [preset]` | | |
| Test suites | `haxeon dev test MODE` | `scripts/test.sh`, `scripts/gate.sh` | |
| Test driver | `haxeon dev test-driver [jobs] [options]` | `scripts/test-driver.sh` | |
| Refresh or check the checked-in compiler | `haxeon dev bootstrap [--self]` | `scripts/bootstrap-compiler.sh` | |
| Format | `haxeon dev format [--check]` | `scripts/format.sh` | |
| Run an entry point of this checkout (benchmarks, probes) | `haxeon dev run [--cp DIR]... MAIN [arguments]` | | |
| Toolchain report | `haxeon doctor` | | |

The Unix wrappers pass their arguments on; `test.sh`, `gate.sh` and `test-driver.sh` build the native runtime first.
`bootstrap-compiler.sh` runs the bootstrap without the CLI, so it works before HashLink is built. `haxeon dev test` runs its
suites through Bash, so it needs a Unix shell.

`build.HaxeonBuild` is the entry point underneath `dev test-driver` and `dev bootstrap`. Running it by hand with the pinned Haxe
(`.tools/haxe/haxe common.hxml --run build.HaxeonBuild native|bootstrap|test|doctor`) is only needed when there is no HashLink
to run the CLI on; its `doctor` checks for git, cmake, ninja and the pinned Haxe.

## Scripts

New scripts for this tree are Haxe, run by `haxeon` ([CLI.md](reference/CLI.md#scripts)): `scripts/check-self-hosting.hx`
and `tests/integration/test-haxeon-script.hx` are examples. They run the same on every platform, which the Bash scripts
in `scripts/` and `tests/integration/` do not; those are ported as they are touched. What runs before `haxeon` exists
stays as shell: `bootstrap-tools.sh`/`setup.ps1`, `build-native.sh`/`.ps1` and the `haxeon` launchers.

## Formatting

Haxe sources are formatted by `haxeon fmt` ([CLI.md](reference/CLI.md)), with imports sorted by `haxeon lint`. This tree has no
`format` setting, so it uses the standard style: tabs and 120 columns. `--check` covers every `.hx` file outside vendored code; a
test file whose lines are part of the test carries `@formatter:off` at the end of its first line.

```sh
./scripts/format.sh                        # haxeon dev format
./scripts/format.sh --check
./scripts/format.sh --changed              # only files that differ from the merge base with origin/main
./scripts/format.sh --check --range A..B   # only files the commits in A..B change
scripts/haxeon fmt --check FILE...         # exactly these files
```

`git config core.hooksPath scripts/hooks` turns on a pre-push hook that runs that check over the commits a push sends, so a
push CI's format check would fail is refused before it leaves (`git push --no-verify` skips it).

## Bootstrapping and self-hosting

The compiler builds itself. Three scripts cover that:

- `haxeon scripts/check-self-hosting.hx` is the check to run after a compiler change, and CI runs it. It builds a seed by running the
  sources under the pinned Haxe interpreter, then stages 1, 2 and 3, each with the one before, and requires stages 2 and 3 to be
  identical (the seed writes its debug sections uncompressed: the interpreter has no HashLink natives). It does not use the
  checked-in compiler.
- `scripts/bootstrap-compiler.sh` refreshes the checked-in compiler, `bootstrap/compiler.hl`. It builds the native runtime,
  builds a seed with the pinned Haxe, then has each stage build the next until two consecutive stages are byte-identical (at most
  eight), and copies the result over `bootstrap/compiler.hl` and `bootstrap/compiler.hl.functions`.
- `scripts/bootstrap-compiler.sh --self` rebuilds the sources with `bootstrap/compiler.hl`, without the reference Haxe compiler,
  and requires the output to be byte-identical to it. It passes only when the checked-in compiler was refreshed from the current
  sources, so it fails after any compiler change until the refresh is committed. CI does not run it.

Both bootstrap modes compile the same sorted manifest of every `.hx` file under `src/`, `lib/` and `stdlib/`.

The writer emits HashLink bytecode format version 8 (`HlCode.VERSION`), the newest the decoder in
`vendor/hashlink/src/code.c` accepts.

## Prebuilt tools: `haxeon dev tool-path`

Scripts in this tree do not build their own copy of the compiler or another entry point. They ask for it by main class and get a cached
HashLink build:

```sh
compiler=$(scripts/haxeon dev tool-path compiler.tools.HaxeonCompiler)   # the compiler CLI
main=$(scripts/haxeon dev tool-path Main)                                # the compiler entry the driver uses
probe=$(scripts/haxeon dev tool-path --cp tests/runtime GcModuleLifetimeMain)
```

Builds live in `out/tools/<main>-<key>.hl`. The key hashes `common.hxml`, every file under its class paths and any `--cp` directories,
the pinned Haxe binary and its standard library, and the `--define` values, so an unchanged tree reuses the last build and any edit
gets a new one. stdout is only the path; build diagnostics go to stderr. The newest three builds of each main are kept, and older ones
are removed once they are an hour old. Run a build with the checkout's VM; the runtime is part of it.

`HAXEON_MAIN_HL`, `HAXEON_COMPILER_HL`, `HAXEON_COMPILER_SERVER_HL` (the compile server the test driver compiles program cases in)
and `HAXEON_BUILD_HL` remain as pins: when set, a script uses that exact build instead
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
backend. The VM is one file, `hl`: HashLink from the pinned `vendor/hashlink`
submodule with libhl and the Haxeon runtime (`native/runtime.c`) compiled in. It
needs no library path, and it exports the VM's API to the libraries it loads, so
those link nothing of HashLink's. It is placed in
`out/cmake/<preset>/hashlink-runtime` (`scripts/hashlink-path.sh` prints the
directory), with `haxeon` and the CLI's bytecode `haxeon-cli.hl`, `hlprof-live`,
and `libhl.a` (`libhl.lib` with MSVC): the same VM without `main.c`, which
`haxeon` and C test programs that host the VM themselves link.

The build links the programs in `hashlink-staging` and publishes them by rename
(`cmake/haxeon-replace.cmake`), never writing over the file in place. A process
running the VM, the CLI or the test driver among them, keeps the file it started
from, so `haxeon dev native` can rebuild the VM it runs on. On Windows, which does
not let a running program be replaced, the old file is renamed aside first and
deleted by a later build.

The `release` preset owns those shared tool paths. The Debug preset, `dev`, writes its VM
under `out/cmake/dev` so a development build cannot replace
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

`scripts/haxeon dev aot-compiler` builds the compiler ahead of time beside the VM,
which the CLI runs while it is built from the current sources; after a compiler
edit, builds say once that it is stale and `haxeon doctor` reports it. A release
archive for this platform is `scripts/haxeon dev package`, checked with
`scripts/smoke-test-release.sh`: see [RELEASES.md](reference/RELEASES.md).

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
  per-name state after that is an array indexed by it (see `IrSsaVariables`, `IrInliner`).
- **Allocation sites come from the allocation census, not the profiler.** `HAXEON_COMPILER_ALLOC_CENSUS=<file>` on a build and
  `scripts/alloc-sites.py <file>` rank where a build allocates (stacks sampled by bytes, exact counts by type). The profiler's alloc samples
  carry only the allocator's return address and cannot name a site.
- **Do not build a key or a list to look something up or to iterate once.** A prefix test with `a + "."` per element, a `[x, y]` literal returned
  from a helper that callers only loop over, and a `"len:owner:field"` map key each allocate per call; the census found them at 6.9%, 4.4% and 1.7% of a
  cold build's bytes. Group once and look up by the parts (`IrInlineEnumEligibility`, `IrOptionalFieldStorage`), or give the helper `count`/`at`
  (`IrOperands`). A callback is no substitute: a closure that captures allocates at each call.
- **A new map keyed by a string that a pass fills and a hot loop reads is a candidate for the two rules above**; check a profile share before
  and after (`hlprof-live`, folded stacks), not the wall time of a loaded machine.
