# Releases

A release is one archive per platform that holds everything the `haxeon` command needs: unpack it anywhere and run
`bin/haxeon`. No pinned Haxe or checkout is needed, and building and running a program needs no C compiler or CMake. A
project that uses a package with C or C++ code (the UI package, for one), an executable built ahead of time
(`--target hlc`) and an Android build do need them: `haxeon doctor` checks for them.

## What an archive holds

`haxeon-VERSION-PLATFORM.tar.gz` (`.zip` on Windows) holds one directory, `haxeon-VERSION-PLATFORM/`, which is Haxeon's SDK
([SDK_LAYOUT.md](../design/SDK_LAYOUT.md)), laid out as a checkout's `out/sdk`:

| Path | What it is |
| --- | --- |
| `haxeon-sdk.toml` | The SDK's manifest: `version`, `commit`, `platform` and `compiler-sources` (the digest of the compiler's sources and standard library the release was made from), and `[roots]` naming `stdlib`, `templates` and `registry`. It has no `source`, which a checkout's names: that makes the directory a release. |
| `bin/hl`, `bin/haxeon` | The VM, and the VM with the CLI as its entry point (`native/haxeon_main.c`). |
| `bin/haxeon-cli.hl` | The CLI's bytecode, which `bin/haxeon` runs when there is no executable built ahead of time. |
| `bin/haxeon-aot`, `bin/haxeon-aot.sources` | The CLI and the compiler built ahead of time, one executable for the CLI (which `bin/haxeon` runs), a compile, the compile server and the language server, with its stamp (docs/design/AOT_BACKEND.md), and with MSVC its `haxeon-aot.pdb`, which its stack traces read. Present where the release job builds it. |
| `bin/haxeon-compiler.hl`, `bin/haxeon-compiler.hl.sources` | The compiler's roles as bytecode, with its stamp: what the VM runs when there is no executable. The roles include the tools that carry the compiler: the language server, the typed lint rules and `haxeon ffi`. |
| `bin/haxeon-live-host.hl`, `bin/haxeon-live-host-instrument.hl` | The live development host `run --watch --live` runs the program or app in (`tools.LiveHost`), and its instrumented flavor for `--profile`, each with its stamp: a checkout builds them from the compiler's sources. |
| `bin/hlprof-live` | The profiler's recorder, which `run --profile` runs. |
| `bin/*.dll`, `*.hdll`, `*.so`, `*.dylib`, `*.lib` | Shared libraries the native build put beside the VM, if any (Linux has none: `hl` has the runtime compiled in), and on Windows the VM's import library, which native packages link against. |
| `stdlib/` | The standard library. |
| `templates/` | The project templates of `haxeon create` ([templates/README.md](../../templates/README.md)). |
| `registry/` | The `haxeon` registry ([MANIFEST.md](MANIFEST.md)): `index.json` and each first-party package at `NAME/VERSION/` (`ui`, `platform`, `nativekit`, ...), published from the checkout's with its path dependencies on the others as version ranges, its submodules' files in it and its `publish.exclude` left out. |
| `lib/<target>/`, `include/`, `src/`, `cmake/` | The VM libraries, runtime headers, entry points and the CMake package an app's runner, or any build of a program compiled ahead of time (`haxeon_add_c_executable`), finds with `find_package(Haxeon)`. |
| `LICENSE`, `NOTICE`, `README.md` | |

Platforms:

- **Linux x86-64**: with the CLI and the compiler built ahead of time.
- **Windows x86-64**: built with MSVC, as `ci.yml` builds it. The release job does not build the compiler ahead of time there
  until the MSVC AOT build has passed on CI, so the archive has no `bin/haxeon-aot` and the CLI and the compiler run on the VM from
  `bin/haxeon-cli.hl` and `bin/haxeon-compiler.hl`: the same programs with a slower start. `haxeon doctor` says `not built: CLI
  and compiler built ahead of time`. Turning it on is `aot: true` for the job in `release.yml`: `haxeon dev package` takes the executable, and its
  `haxeon-aot.pdb`, whenever they are built.
- **macOS arm64**: experimental. It has the CLI and the compiler built ahead of time, whose stack traces are not verified on macOS.

## How an unpacked release finds itself

`bin/haxeon` finds its own path (`/proc/self/exe`, `_NSGetExecutablePath` or `GetModuleFileNameW`, symbolic links resolved). The
directory above `bin` is its SDK, Haxeon's home, which must hold `haxeon-sdk.toml`: the launcher names it in `HAXEON_SDK`, and
the CLI finds everything else from it and its manifest (`build.HaxeonSdk`): `bin` is the VM's directory (`build.HashLinkPath`),
`bin/haxeon-cli.hl` is the CLI, and the manifest's `[roots]` name the standard library, the templates and the registry. A
checkout's `out/sdk/bin/haxeon` is found the same way; its manifest's `source` names the checkout, whose tools and sources the
commands that need them read there (`HaxeonSdk.requireSource`). A symbolic link to `bin/haxeon` from a directory on `PATH`
works, and so does a checkout's `out/sdk/bin` on `PATH`.

A release never writes into its own directory: the shared trees of native packages' CMake builds, which a checkout keeps in
`out/native-cache`, are under the user's cache (`~/.haxeon/cache/native`) for a release.

The CLI runs the compiler as `build.AotCompiler.program` says: the executable when its stamp matches, else the bytecode on the
VM when its stamp matches, else (in a checkout) bytecode it builds from the sources with the pinned Haxe. A checkout matches the
stamps against the digest of its `src/`, `lib/haxeon-io/` and `stdlib/`. A release ships no compiler sources, as its compiler
cannot change: it matches them against the digest its manifest records, so the pinned Haxe is never needed, and `haxeon doctor` does
not ask for it.

Every program a checkout builds from the compiler's sources when a command needs it is prebuilt in a release, beside the VM with
its stamp (`AotCompiler.shipped`): the compiler and the tools that carry it (`haxeon lsp`, the typed rules of `haxeon lint`,
`haxeon ffi`), and the live development host of `run --watch --live`. So live patching works from a release: its compile
server patches the module, and the shipped host, or an app's runner built from the SDK's `libhaxeon-app` running it, applies
them. Native packages build against the SDK's `include/` and `cmake/`, as in a checkout.

What a release does not do, as it is for working on Haxeon or needs a checkout's tools: `haxeon dev` (it says so, and runs
only from a checkout), `--self-hosted` builds (the committed bootstrap compiler) and `haxeon heap inspect` (HashLink's
analyzer, built from the checkout's vendored sources). Android builds (`--target android`, `haxeon devices`) need the
checkout's `android/` host and its SDK under `.tools` until their runner lands in the SDK (`platforms/android`,
[SDK_LAYOUT.md](../design/SDK_LAYOUT.md)).

## Making one

From a checkout with the native build done (`scripts/build-native.sh`, or `scripts/setup.ps1` on Windows):

```sh
scripts/haxeon dev aot                         # optional: the CLI and compiler built ahead of time, included when current
scripts/haxeon dev package [--version=V] [--output=DIR] [--no-archive]
scripts/smoke-test-release.sh out/release/haxeon-V-PLATFORM.tar.gz --aot   # --no-aot for an archive without it
```

`haxeon dev package` (`tools.dev.ReleasePackage`) stages the directory in `out/release` in three steps. It installs the
checkout's `out/sdk` as the native build staged it (the `haxeon-sdk` target and the VM's directory in CMakeLists.txt, the one
definition of the layout), without its manifest and live registry; it materializes the roots that manifest names (the standard
library, the templates, and the registry with each package published); and it adds what only a release has: the programs built
from the compiler's sources (the compiler's bytecode with the pinned Haxe, `tools.CompilerExecutable` through the tool cache,
and both live hosts with Haxeon, `tools.LiveHostBuild`), each stamped with the sources' digest, LICENSE, NOTICE and README.md,
and the manifest recording that digest. It checks that the sources still have that digest, and archives the directory with
`cmake -E tar`. The compiler's sources are not shipped. It changes nothing in the checkout's VM directory. A stale `haxeon-aot`
is an error, since the release would never run it: rebuild it or remove it.
The version defaults to the CLI's (`project.PackageCompatibility.CURRENT_HAXEON`).

`scripts/smoke-test-release.sh` unpacks the archive outside the checkout with a home directory of its own, so every cache
starts cold, and runs `--version`, `doctor`, `init` + `build` + `run` + `check` of a new project and a script, a typed lint
rule, `haxeon ffi audit` (with clang), `haxeon dev`'s refusal, and a program under `run --watch --live` that it edits while it
runs, checking that the running program prints the new value and that the edit applied as a patch. Where the app template has a
runner for the platform it also creates the app, whose UI package comes from the release's registry, builds it through its runner
in development and release mode, running each for three frames with a capture (a C toolchain, and on Linux GTK's development
files, are needed), patches the app running under `run --watch --live` (headless under `xvfb-run` on Linux; not on Windows), and
builds and runs programs with `nativekit` and with `filesystem` from the same registry, checking that NativeKit was built once. It
checks that no compiler was built from sources and, on Linux and macOS, that the resident compile server is the expected compiler.
With `--aot` it times the same cold build without `bin/haxeon-aot`, which also exercises the bytecode fallback.

## The release workflow

`.github/workflows/release.yml` runs on `v*` tags and by hand (workflow_dispatch). One job per platform (Linux, Windows, macOS) builds the VM and
the CLI in release mode and the compiler ahead of time where supported, packages, smoke-tests the archive and uploads it. It runs no
test suites; the macOS job may fail without failing the run. A final job downloads the archives and writes `SHA256SUMS`. For a
tag it then checks that the tagged commit is on `main` and has a successful `ci.yml` run, and creates the GitHub release with
the archives and checksums, or uploads them to the release if it exists. Run by hand, it stops before that: the archives are the
run's artifacts. A tag's version must be the CLI's version, optionally with a suffix (`v0.3.0`, `v0.3.0-rc.1`).

## A checkout's stale compiler

In a checkout the executable is current only until the sources change. A build with a stale one prints one line,

```
note: haxeon-aot is older than the sources, so the CLI and the compiler run on the VM (a slower start); rebuild it with "haxeon dev aot"
```

unless it prints no progress (`--quiet`, `--verbosity quiet`, a script), and `haxeon doctor` reports it as stale with the same
remedy. Nothing rebuilds it automatically.
