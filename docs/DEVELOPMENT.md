# Development

## Setup

```sh
./scripts/bootstrap-tools.sh             # pinned Haxe and submodules
./scripts/build-native.sh                # the VM: HashLink with the Haxeon runtime compiled in
./scripts/test.sh --only driver-default  # the test driver: compiler and program cases
```

`scripts/test.sh` with no arguments runs everything CI runs, which is slow. While working on a change, run the suite or the
single test it touches (see Tests) and leave the full run to CI. On Windows, see [Native build](#native-build).

## Writing pages with examples

CI builds the example projects for the guides, the language tour and the migration pages.

- Name a guide `NN-slug.md` in reading order. Name a language or migration page `slug.md`. Put a page's code in
  `examples/<page>/` beside it, using the filename without `.md` as `<page>`. The directory holds one or more Haxeon
  projects, each with a `haxeon.toml`, and any other files needed to follow the page, such as step-by-step edits.
- Every ` ```haxe ` and ` ```toml ` block on the page must appear in a file under `examples/<page>/`, line for line. The
  check ignores the block's common indentation, so a method can be shown without the indentation of its class, and
  trailing spaces. A line that holds only `// ...` (in Haxe) or `# ...` (in TOML) stands for lines left out: the parts
  around it must appear in the same file, in that order.
- A ` ```text title="Output" ` block is what a program prints: it must appear in that project's `expected-output.txt`,
  and the check runs the program and compares what it prints with that file.
- Commands go in ` ```sh ` blocks (` ```powershell ` for Windows only) and other output in ` ```text ` blocks; neither
  is checked against the examples, so keep them to what the reader types and sees.
- For code in another language, label the block with that language, such as `dart`, `csharp` or `go`.
- Published pages link to guides, language pages, migration pages, reference pages and their examples, or to full URLs.
  Keep links to design notes, reports, internals and decision records in repository documentation.
- An app is kept without its runner directories (`linux/` and the others): the check adds them with `haxeon create .`, so
  an example always has the runner the current template writes.

`tests/integration/test-docs-guides.hx` checks snippets and published links, then copies each example project out of the tree
and builds it with the checkout's `haxeon`. It runs a program and compares its output when the project has an
`expected-output.txt`, and opens an app for a few frames (under `xvfb-run` on Linux when it is installed). A guide that
needs more, such as the live edits of [Live editing](guides/02-live-editing.md), gets its own function there. Run it from the
repository root:

```sh
scripts/haxeon tests/integration/test-docs-guides.hx               # check the pages, then build and run every example
scripts/haxeon tests/integration/test-docs-guides.hx --no-build    # check the pages only
```

## Tests

Every suite is one line of `tests/suites.txt`, in the order it runs, with its groups and how it is scheduled (the file's header
documents the format). `scripts/haxeon dev test MODE` runs a mode: `quick`, `wave` (quick and wave), `ci` (what CI runs) or `full`
(all of them, each suite once). Before the first suite it builds the native runtime and resolves the prebuilt tools, once. Every suite
runs even when an earlier one fails, and the exit code is 0 only if all that ran passed. Each suite writes a log to `out/test/<time>-<mode>/`,
next to `summary.txt`.

```sh
./scripts/test.sh                                  # dev test ci; TEST_JOBS sets the jobs (default 16), SKIP_FORMAT_CHECK=1 skips the format check
./scripts/test.sh --only driver-default,wasm-backend
./scripts/test.sh full --list                      # the suites a mode runs, with their lanes and pools
./scripts/test.sh quick|wave|full --gate           # 4 jobs unless --jobs says otherwise: a report in out/gate (docs/reports/2026-11-test-suite-cost.md section 8)
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
server, without those reports, gates what an edit costs: main-thread `instructions:u` of a no-op rebuild (the floor every build
pays), of the body edit and of the signature edit, from `perf stat --per-thread` attached to the server around each build, each
build starting once the server has settled from the one before (skipped where perf is not available), and the collections inside
a body edit and their milliseconds (`body_edit_collections`, `body_edit_collection_ms`, means of three, from the runtime's
collection count and mark time), which the instructions leave out; per build it prints wall and the server's peak resident set.
A third session prints edit wall on the server built ahead of time, with the collector marking on its threads as a user's does,
never compared. The guard builds `haxeon-aot` for it and for the small project's aot mode when it is not current
(`haxeon dev aot`), and removes it again at the end, so a checkout that had none current is left without one. This part adds
about three minutes, and a stale `haxeon-aot` its build.

`--quick` runs only that second session, without its signature edit: the cold build, the no-ops and the three body edits,
compared on the same metrics and tolerances (the no-op and body-edit instructions, the body edit's collections). It takes a
few minutes, and is the check for a change to the IR, the backends or the typer between full runs.

The small-project part runs the CLI as a user does: a cold `haxeon build` and `haxeon check` of `tests/perf/small-project`, from
no compile server running to the server's exit, so the CLI's start, the server's start and the compile all count. It gates the
instructions of every process the command starts and the bytes the server allocated for the request; the CLI's wall is printed.
The live part runs `haxeon run --watch` as a user does, on `tests/perf/live-project` (three files) and on the app template
(`haxeon create`, a window on haxeon-ui, run under `xvfb-run`; skipped without it), with the server and CLI a user's edits run on:
`haxeon-aot` (built when it is not current), which names the metrics (`aot_`). Each edit is timed from its save to the
running app's `patch-applied` event (the watch-events file), and split into the watch's settle, the CLI's work before the request,
the compile up to the published patch, the host's pickup and the runtime's apply. It gates the median body edit and the signature
edit with a wide tolerance (wall varies with load; it catches a wait added on the path), the functions each patch carries, and, from
a second session whose builds each end with a full collection, the server's live data after the edits and its growth over them.
The first run builds haxeon-ui's native libraries, which takes minutes; later runs keep them. The ui app builds NativeKit and
haxeon-ui's own native libraries, whose submodules `bootstrap-tools.sh` does not fetch; the guard checks that they are at their
pins before it starts, and names the command that puts them there. In a fresh worktree, before the guard:

```sh
git submodule update --init --recursive vendor/nativekit packages/ui
./scripts/build-native.sh
```

After a pin moves, the same command brings them back to it. The guard keeps the app's native build (`out/perf-guard/live/ui-app`)
between runs, and configures it again after a configure that failed.
`--only=self-compile`, `--only=incremental`, `--only=small-project` or `--only=live` runs one part. The `edit-replay-short` suite (`wave`)
replays the last two commits that change `src/compiler` as warm builds in one server, each checked against a fresh build;
`edit-replay` (`ci`) replays four.

Every metric fails the run beyond its tolerance, but the primary ones are what the compiler is optimized for, in this order:
edit latency in the compile server (the no-op floor, the body edit, the signature edit), startup (the small project's cold build and check), and the server's live data, weighted
above the one-shot peak. They are marked `*` and summed up in the first line of the summary the run ends with. The cold
self-compile (instructions, wall, peak, allocation, live data) and the incremental allocation and function counts are regression
guards.

Each metric is compared with `tests/perf/self-compile-baseline.json`, `tests/perf/incremental-baseline.json` or
`tests/perf/small-project-baseline.json` or `tests/perf/live-baseline.json`, which hold its
value and tolerance and why the tolerance is what it is. Above the tolerance the suite fails; below it the suite passes and asks
for the baseline to be updated, so a gain is locked in. A baseline never moves up by itself: `--update` writes only the
metrics that improved beyond their tolerance, so a metric that got worse within it stays where it was and a series of updates
cannot ratchet it up. A cost taken on purpose (a feature that costs memory) is raised by name, with its reason, which the
baseline keeps beside the value (`raise_reason`) until the metric improves again. Moving `input_revision` (when the old sources
no longer compile, or to follow the compiler's growth) re-baselines in the same commit: `--update`, and `--raise` for each metric
that went up, with the move as its reason. Measure from a quiet Linux x86-64 machine, and commit the baseline with the change:

```sh
python3 scripts/perf-guard.py                                   # measure and compare
python3 scripts/perf-guard.py --quick                           # the edit-cost session alone, a few minutes
python3 scripts/perf-guard.py --update                          # also write the metrics that improved; tolerances are kept
python3 scripts/perf-guard.py --raise=server_live_bytes=REASON  # also write this higher value, with why
```

The incremental edits are anchored on a line of `HaxeonCompiler.main` and on `InternalError`'s constructor (`BODY_EDIT` and
`SIGNATURE_EDIT` in the script); a change that removes an anchor makes the suite say so, and picks another of the same kind.

Say in the commit message what moved and why. A tolerance is changed by editing the file, with its `why`.

### The same commands on every platform

Setup is two CMake invocations, wrapped by a script per shell. Everything after that is the `haxeon` command, spelled the
same everywhere. It is a native executable the build puts beside `hl`: the same VM, running the CLI's bytecode, which the
build compiles with the pinned Haxe and publishes next to it (`native/haxeon_main.c`). It belongs to the SDK the build stages in
`out/sdk`, which it names in `HAXEON_SDK` and whose manifest names the checkout as its `source` (`build.HaxeonSdk`), and needs
no library path, so its directory can go on `PATH`.

`scripts/haxeon` (Unix) and `scripts\haxeon` (`haxeon.cmd`, `haxeon.ps1`; Windows) run it after bringing it and the CLI's
bytecode up to date with `cmake --build <build> --target haxeon-command`, so an edit to the CLI is in the next command. That
check costs about a tenth of a second; `HAXEON_NATIVE_READY=1` skips it, as the suite runner does after its own native build.

| Step | Command | Unix wrapper | Windows wrapper |
|---|---|---|---|
| Pinned tools and submodules | `cmake -P cmake/Bootstrap.cmake` | `scripts/bootstrap-tools.sh` | `scripts/setup.ps1` |
| The VM, first build | `cmake --preset P`, `cmake --build --preset P` | `scripts/build-native.sh` | `scripts/build-native.ps1` |
| The VM, rebuilt | `haxeon dev native [preset]` | | |
| Test suites | `haxeon dev test MODE` | `scripts/test.sh [MODE]` | |
| Test driver | `haxeon dev test-driver [jobs] [options]` | `scripts/test-driver.sh` | |
| Refresh or check the checked-in compiler | `haxeon dev bootstrap [--self]` | `scripts/bootstrap-compiler.sh` | |
| Format | `haxeon dev format [--check]` | | |
| Run an entry point of this checkout (benchmarks, probes) | `haxeon dev run [--cp DIR]... MAIN [arguments]` | | |
| Toolchain report | `haxeon doctor` | | |

The Unix wrappers pass their arguments on; `test.sh` and `test-driver.sh` build the native runtime first.
`bootstrap-compiler.sh` runs the bootstrap without the CLI, so it works before HashLink is built. `haxeon dev test` runs its
suites through Bash, so it needs a Unix shell.

`build.HaxeonBuild` is the entry point underneath `dev test-driver` and `dev bootstrap`. Running it by hand with the pinned Haxe
(`.tools/haxe/haxe common.hxml --run build.HaxeonBuild native|bootstrap|test|doctor`) is only needed when there is no HashLink
to run the CLI on; its `doctor` checks for git, cmake, ninja and the pinned Haxe.

## Scripts

A command of this tree is a `haxeon` command (`haxeon dev ...`, `haxeon lsp`, `haxeon ffi ...`), a check is a suite of
`tests/suites.txt`, a benchmark lives under `benchmarks/` with its driver, and a build step is CMake. `scripts/` keeps what
none of those can be, and no alias for any of them:

- what runs before `haxeon` exists: `bootstrap-tools.sh`/`setup.ps1`, `build-native.sh`/`.ps1`, `bootstrap-compiler.sh`
  (the checked-in compiler, with the pinned Haxe only); the pinned libffi is built by `cmake/libffi.cmake`, which
  `cmake/Bootstrap.cmake` includes;
- the launchers of the checkout's builds: `haxeon` (`haxeon.cmd`, `haxeon.ps1`), `hl`, `hlprof-live`, with
  `hashlink-launch.sh` and `hashlink-path.sh` under them; `android-env.sh`, sourced to put the Android tools on `PATH`;
- the test entry points: `test.sh`, `test-driver.sh`, `check-self-hosting.hx`, `perf-guard.py`, `smoke-test-release.sh`,
  `test-cli-launcher.sh` (the suite runner's `cli-launcher` option), `hooks/pre-push`, and `lib/`, which test scripts source;
- tools that read what a run wrote: `alloc-sites.py` (the allocation census), `peak-timeline.py`, `check-pftrace.py`,
  `hlprof-report.py`, `hlprof-spans.py`, `report-binary-size.py`; and `compiler-class-paths.sh` for tools outside the tree,
  `generate-ryu-table-data.py` for the checked-in table it generates; `apply-ir-layout.py`, which moves the modules of
  `src/compiler/ir` into the packages `ir-layout.txt` names and fixes every reference, for a branch made before the move
  (`python3 scripts/apply-ir-layout.py .` after rebasing; it is idempotent).

New scripts for this tree are Haxe, run by `haxeon` ([CLI scripts](reference/cli/build-run.md#scripthx)): `scripts/check-self-hosting.hx`
and `tests/integration/test-haxeon-script.hx` are examples. They run the same on every platform, which the Bash scripts
in `scripts/` and `tests/integration/` do not; those are ported as they are touched.

## Formatting

Haxe sources are formatted by `haxeon fmt` ([Formatter](reference/cli/test-quality.md#fmt)), with imports sorted by `haxeon lint`. This tree has no
`format` setting, so it uses the standard style: tabs and 120 columns. `--check` covers every `.hx` file outside vendored code; a
test file whose lines are part of the test carries `@formatter:off` at the end of its first line.

```sh
scripts/haxeon dev format                        # the whole tree
scripts/haxeon dev format --check
scripts/haxeon dev format --changed              # only files that differ from the merge base with origin/main
scripts/haxeon dev format --check --range A..B   # only files the commits in A..B change
scripts/haxeon fmt --check FILE...               # exactly these files
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
those link nothing of HashLink's. It is placed in the `bin` of the checkout's
SDK, `out/sdk/bin` ([SDK_LAYOUT.md](design/SDK_LAYOUT.md); another preset's
build stages its own in `out/cmake/<preset>/sdk/bin`, and
`scripts/hashlink-path.sh` prints the directory), with `haxeon`, the CLI's
bytecode `haxeon-cli.hl` and `hlprof-live`. The SDK's `lib/<target>`
(`scripts/hashlink-path.sh --lib-dir`, `build.HashLinkPath.libraryDirectory`)
holds `libhl.a` (`hl.lib` with MSVC), the same VM without `main.c`, which C test
programs that host the VM themselves link, and the profiler's function hooks.

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

`scripts/haxeon dev aot` builds the CLI and the compiler ahead of time beside the VM,
which the CLI runs while it is built from the current sources; after a compiler
edit, builds say once that it is stale and `haxeon doctor` reports it (below).

## Releases

What a release archive holds and how a user installs it is in [RELEASES.md](reference/RELEASES.md). This section is how
one is made, and how the CLI finds what it runs.

### How the CLI finds its SDK and its compiler

`bin/haxeon` (`native/haxeon_main.c`) finds its own path (`/proc/self/exe`, `_NSGetExecutablePath` or
`GetModuleFileNameW`, symbolic links resolved). The directory above `bin` is its SDK (docs/design/SDK_LAYOUT.md), which
must hold `haxeon-sdk.toml`: the launcher names it in `HAXEON_SDK`, and the CLI finds everything else from it and its
manifest (`build.HaxeonSdk`): `bin` is the VM's directory (`build.HashLinkPath`), `bin/haxeon-cli.hl` is the CLI, and the
manifest's `[roots]` name the standard library, the templates and the registry. A checkout's `out/sdk/bin/haxeon` is found
the same way; its manifest's `source` names the checkout, whose tools and sources the commands that need them read there
(`HaxeonSdk.requireSource`). A release's manifest has no `source`: that is what makes the directory a release. A
release's archive directory is laid out as a checkout's `out/sdk`.

The CLI runs the compiler as `build.AotCompiler.program` says: the executable (docs/design/AOT_BACKEND.md) when its stamp
matches, else the bytecode on the VM when its stamp matches, else (in a checkout) bytecode it builds from the sources with
the pinned Haxe. A checkout matches the stamps against the digest of its `src/`, `lib/haxeon-io/` and `stdlib/`. A release
ships no compiler sources, as its compiler cannot change: it matches them against the digest its manifest records
(`compiler-sources`), so the pinned Haxe is never needed, and `haxeon doctor` does not ask for it.

Every program a checkout builds from the compiler's sources when a command needs it is prebuilt in a release, beside the
VM with its stamp (`AotCompiler.shipped`): the compiler and the tools that carry it (`haxeon lsp`, the typed rules of
`haxeon lint`, `haxeon ffi`), and the live development hosts (`tools.LiveHost`). A release keeps the shared trees of
native packages' CMake builds, which a checkout keeps in `out/native-cache`, under the user's cache
(`~/.haxeon/cache/native`). Android builds need the checkout's `android/` host and its SDK under `.tools` until their
runner lands in the SDK (`platforms/android`, docs/design/SDK_LAYOUT.md).

### Making one

From a checkout with the native build done (`scripts/build-native.sh`, or `scripts/setup.ps1` on Windows):

```sh
scripts/haxeon dev aot                         # optional: the CLI and compiler built ahead of time, included when current
scripts/haxeon dev package [--version=V] [--output=DIR] [--no-archive]
scripts/smoke-test-release.sh out/release/haxeon-V-PLATFORM.tar.gz --aot   # --no-aot for an archive without it
```

`haxeon dev package` (`tools.dev.ReleasePackage`) stages the directory in `out/release` in three steps. It installs the
checkout's `out/sdk` as the native build staged it (the `haxeon-sdk` target and the VM's directory in CMakeLists.txt, the one
definition of the layout), without its manifest and live registry; it materializes the roots that manifest names (the standard
library, the templates, and the registry with each package published, its path dependencies on the others as version
ranges, its submodules' files in it and its `publish.exclude` left out); and it adds what only a release has: the programs
built from the compiler's sources (the compiler's bytecode with the pinned Haxe, `tools.CompilerExecutable` through the
tool cache, and both live hosts with Haxeon, `tools.LiveHostBuild`), each stamped with the sources' digest, LICENSE,
NOTICE and README.md, and the manifest recording that digest. It checks that the sources still have that digest, and
archives the directory with `cmake -E tar`. The compiler's sources are not shipped. It changes nothing in the checkout's
VM directory. A stale `haxeon-aot` is an error, since the release would never run it: rebuild it or remove it. The
version defaults to the CLI's (`project.PackageCompatibility.CURRENT_HAXEON`).

`scripts/smoke-test-release.sh` unpacks the archive outside the checkout with a home directory of its own, so every cache
starts cold, and runs `--version`, `doctor`, `init` + `build` + `run` + `check` of a new project and a script, a typed lint
rule, `haxeon ffi audit` (with clang), `haxeon dev`'s refusal, and a program under `run --watch` that it edits while it
runs, checking that the running program prints the new value and that the edit applied as a patch. Where the app template has a
runner for the platform it also creates the app, whose UI package comes from the release's registry, builds it through its runner
in development and release mode, running each for three frames with a capture (a C toolchain, and on Linux GTK's development
files, are needed), patches the app running under `run --watch` (headless under `xvfb-run` on Linux; not on Windows), and
builds and runs programs with `nativekit` and with `filesystem` from the same registry, checking that NativeKit was built once. It
checks that no compiler was built from sources and, on Linux and macOS, that the resident compile server is the expected compiler.
With `--aot` it times the same cold build without `bin/haxeon-aot`, which also exercises the bytecode fallback.

### The release workflow

`.github/workflows/release.yml` runs on `v*` tags and by hand (workflow_dispatch). One job per platform (Linux, Windows,
macOS) builds the VM and the CLI in release mode and the compiler ahead of time where supported, packages, smoke-tests the
archive and uploads it. It runs no test suites; the macOS job may fail without failing the run. A final job downloads the
archives and writes `SHA256SUMS`. For a tag it then checks that the tagged commit is on `main` and has a successful
`ci.yml` run, and creates the GitHub release with the archives and checksums, or uploads them to the release if it exists.
Run by hand, it stops before that: the archives are the run's artifacts. A tag's version must be the CLI's version,
optionally with a suffix (`v0.3.0`, `v0.3.0-rc.1`).

The Windows job builds with MSVC, as `ci.yml` does, and does not build the compiler ahead of time until the MSVC AOT build
has passed on CI. Turning it on is `aot: true` for the job in `release.yml`: `haxeon dev package` takes the executable,
and its `haxeon-aot.pdb`, whenever they are built.

### A checkout's stale compiler

In a checkout the executable is current only until the sources change. A build with a stale one prints one line,

```
note: haxeon-aot is older than the sources, so the CLI and the compiler run on the VM (a slower start); rebuild it with "haxeon dev aot"
```

unless it prints no progress (`--quiet`, `--verbosity quiet`, a script), and `haxeon doctor` reports it as stale with the
same remedy. Nothing rebuilds it automatically.

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
