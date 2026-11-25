# Releases

A release is one archive per platform that holds everything the `haxeon` command needs: unpack it anywhere and run
`bin/haxeon`. No pinned Haxe or checkout is needed. A console development build with only Haxe code uses the
included HashLink VM. Console release builds, desktop app builds, projects with C or C++ packages
(such as UI), and Android builds require a native toolchain and CMake. `haxeon doctor` checks the tools and shows
how to install them. [Get started](../guides/00-get-started.md) walks through installing one.

## What an archive holds

`haxeon-VERSION-PLATFORM.tar.gz` (`.zip` on Windows) holds one directory, `haxeon-VERSION-PLATFORM/`, which is Haxeon's SDK:

| Path | What it is |
| --- | --- |
| `haxeon-sdk.toml` | The SDK's manifest: `version`, `commit`, `platform`, the digest of the compiler's sources the release was made from, and `[roots]` naming `stdlib`, `templates` and `registry`. |
| `bin/haxeon` | The command. |
| `bin/hl` | The VM, which runs a program's module. |
| `bin/haxeon-aot` | The CLI and the compiler built ahead of time, with its stamp (`.sources`) and, with MSVC, its `haxeon-aot.pdb`, which its stack traces read. Present where the release job builds it (below). |
| `bin/haxeon-cli.hl`, `bin/haxeon-compiler.hl` | The CLI and the compiler as bytecode, each with its stamp: what runs when there is no `haxeon-aot`. The compiler's bytecode also carries the language server, the typed lint rules and `haxeon ffi`. |
| `bin/haxeon-live-host.hl`, `bin/haxeon-live-host-instrument.hl` | The program `run --watch` runs a program in, and its instrumented flavor for `--profile`. |
| `bin/hlprof-live` | The profiler's recorder, which `run --profile` runs. |
| `bin/*.dll`, `*.hdll`, `*.so`, `*.dylib`, `*.lib` | Shared libraries beside the VM, if any (Linux has none), and on Windows the VM's import library, which native packages link against. |
| `stdlib/` | The standard library. |
| `templates/` | The project templates of `haxeon create` ([Create](cli/project.md#create)). |
| `registry/` | The `haxeon` registry ([MANIFEST.md](MANIFEST.md)): `index.json` and each first-party package at `NAME/VERSION/` (`ui`, `platform`, `nativekit`, ...). |
| `lib/<target>/`, `include/`, `src/`, `cmake/` | The VM libraries, runtime headers, entry points and the CMake package that an app's runner, or any build of a program compiled ahead of time (`haxeon_add_c_executable`), finds with `find_package(Haxeon)`. The SDK also includes the CMake project that builds console release executables. |
| `LICENSE`, `NOTICE`, `README.md` | |

Platforms:

- **Linux x86-64**: with the CLI and the compiler built ahead of time.
- **Windows x86-64**: built with MSVC. The archive has no `bin/haxeon-aot` yet, so the CLI and the compiler run on the VM
  from `bin/haxeon-cli.hl` and `bin/haxeon-compiler.hl`: the same programs with a slower start. `haxeon doctor` says `not
  built: CLI and compiler built ahead of time`.
- **macOS arm64**: experimental. It has the CLI and the compiler built ahead of time, whose stack traces are not verified
  on macOS.

## Installing one

Unpack the archive anywhere, and put its `bin` directory on `PATH`, or make a symbolic link to `bin/haxeon` from a
directory on `PATH`. `bin/haxeon` finds its own path (symbolic links resolved), and the directory above `bin` is the SDK it
uses: the archive's directory must stay whole, but it can be moved or renamed. Several releases can be unpacked side by
side; each `bin/haxeon` uses its own.

A release never writes into its own directory. What it builds once per machine, such as the native packages' CMake builds
that every project shares, goes under the user's cache, `~/.haxeon/cache/native`.

The compiler of a release cannot change, so it never builds a compiler or a tool from sources: everything a command runs
is in the archive, including the language server, `haxeon ffi`, the typed lint rules and the live development host. Live
patching (`run --watch`) works from a release, and an app's runner builds against the SDK's `include/` and
`cmake/`.

Release archives include the Android host AAR and web loader under `platforms/`.
Android APK builds also need a local Android SDK. See [Android](ANDROID.md).

## What a release does not do

These are for working on Haxeon itself, or need a checkout's tools:

- `haxeon dev`, which says so and runs only from a checkout.
- `--self-hosted` builds, which use the checkout's committed bootstrap compiler.
- `haxeon heap inspect`, which runs HashLink's analyzer built from the checkout's sources.
