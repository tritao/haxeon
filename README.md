# Haxeon ⚡

> **Haxe, always on.**

Haxeon is a cross-platform application toolkit built on a Haxe-compatible
language. Write your app once in typed, familiar Haxe, call C and C++ libraries
through generated bindings, and run it on desktop, Android, and the web, with
live code updates while it runs.

Haxeon currently implements a growing subset of Haxe.

## 🧱 What you get

| | |
|---|---|
| **One language** | Haxe-compatible syntax with static typing, served by a self-hosted, incremental compiler |
| **Many targets** | Desktop and Android on HashLink, plus WebAssembly (`wasm32`, `wasm-gc`), all lowered from one IR |
| **Native code, typed** | HXI bindings generated from C and C++ headers, fixed-layout records, raw pointers, and arenas |
| **Always on** | Transactional hot patching: edits land in the running program, and a bad patch leaves it untouched |
| **One CLI** | `haxeon` initializes, builds, runs, formats, and packages projects, including their native dependencies |

## 🔥 Always on

Traditional development repeatedly stops, rebuilds, and restarts an
application. Haxeon is built around a continuous loop:

1. Edit Haxe-compatible source.
2. Recompile only what changed.
3. Validate the resulting patch.
4. Atomically install it into the running program.
5. Keep existing state, objects, and closures alive.

If a patch is malformed, stale, or incompatible, the running program remains
untouched. Changes that alter a module's structure use an explicit reload
boundary that carries your state across.

## 🚀 Quick start

HashLink stdout flushes immediately on terminals and buffers output to pipes and
files. It flushes before stdin reads, subprocesses, sleep, and exit; fatal signals
attempt a best-effort flush. `Sys.stdout().flush()` flushes explicitly, and
`HL_STDOUT_FLUSH=1` restores flushing after every print. SIGKILL can discard the
buffered tail.

Requirements: a C/C++ toolchain, CMake, and Git. The pinned Haxe, HashLink, and
Ninja tools are installed locally by the setup scripts.

```sh
./scripts/bootstrap-tools.sh     # pinned tools (Windows: scripts/setup.ps1)
cmake --preset release
cmake --build --preset release   # HashLink VM and Haxeon runtime

./scripts/haxeon init            # creates haxeon.json and src/Main.hx
./scripts/haxeon run             # build and launch
./scripts/haxeon run --watch     # rebuild and relaunch on edits
```

`run --watch --live` keeps one process alive and applies patches between
application ticks. It requires an entry class with `start`, `tick`, `saveState`,
`close`, and `restoreState`; see [Project CLI](docs/CLI.md).

| Platform | Status |
|---|---|
| Linux, macOS (x86-64 and Apple Silicon), Windows | Supported host targets |
| Android (`arm64-v8a`, `x86_64`) | Supported, with live patching |
| WebAssembly (`wasm32`, `wasm-gc`) | Experimental, build-only |

## 🧬 What Haxeon adds over Haxe

Haxeon keeps Haxe's syntax and static typing, then adds the pieces that are
awkward to get from the reference compiler:

| | **Haxe** | **Haxeon** |
|---|---|---|
| Live code changes | Compilation server speeds up rebuilds; the app restarts | Transactional patches applied to the running program |
| Calling C and C++ | A different mechanism per target: hand-written HashLink C glue, hxcpp externs, JS externs | One typed interface format (**HXI**), generated from headers, shared by every target |
| WebAssembly | No official target | Self-hosted `wasm32` and `wasm-gc` backends |
| Native data layout | Managed objects only | Fixed-layout `@:value @:repr("C")` records, `RawPtr<T>`, and arenas, with `sizeof`/`offsetof` folded to constants |
| Native build | Left to the user | Packages declare C/C++ sources or a CMake project; the CLI plans, caches, and builds them |
| Mobile | Via other targets | Android host with the same runtime and live patching |

### HXI: one interface for C and C++

**HXI** is Haxeon's typed description of a native library's ABI: functions,
records and their exact layouts, enums, callbacks, and who owns each pointer.
A Clang-based importer generates it from your C headers (and a deliberately
constrained C++ subset), so you don't hand-write bindings. Haxe code then calls
the library as ordinary typed Haxe, with generated wrappers for out-parameters,
owned handles that you `close()`, and byte buffers.

```text
 C / C++ headers ──► Clang importer ──► HXI (target-specific, deterministic)
                                            │
                  ┌─────────────────────────┼──────────────────────────┐
                  ▼                         ▼                          ▼
        HashLink / desktop             Android                  WebAssembly
        libffi bridge, no          same runtime and       typed Wasm imports using the
        HDLL glue code             native packages        clang/Emscripten C ABI
```

Attach an import to a package with a recipe; the build regenerates the HXI when
the recipe or headers change:

```json
{ "version": 1, "package": { "name": "mylib-bindings" },
  "ffi": { "imports": ["ffi/mylib.ffi.json"] } }
```

```json
{ "version": 1, "name": "mylib", "language": "c", "header": "include/mylib.h",
  "includes": ["include"], "library": "mylib", "interface": "MyLib" }
```

Unsupported constructs produce explicit diagnostics instead of a guessed
binding. See [`docs/C_HEADER_FFI.md`](docs/C_HEADER_FFI.md) for the supported
subset, C++ profiles, ownership rules, and exception thunks.

### Cross-platform apps, including the browser

The Wasm backends lower the same canonical IR as the HashLink backend, so an
application's Haxe code, its HXI bindings, and its C/C++ library share one
source of truth across desktop, Android, and the web:

- **`wasm32`** uses linear memory with a precise collector. **`wasm-gc`** uses
  the engine's native garbage collector and needs no linear memory unless FFI
  asks for it.
- A guest and its host meet only at C-ABI functions, so one host serves both
  Wasm targets. Compile your C/C++ library with Emscripten; Haxeon's
  `haxeon-host.js` connects the guest to that module and forwards the HXI
  imports to its exports.
- C callbacks, records by value, out-parameters, and owned handles work across
  the boundary; Wasm GC copies records and strings through scratch memory.

Wasm support is experimental and narrower than the desktop target:

- Haxeon does not yet build a package's C/C++ sources for `wasm32`. A package
  with no provider for a target stops at planning with a clear error, so
  compile the library with Emscripten yourself.
- `wasm-gc` supports a smaller subset of the FFI than `wasm32`, and HXI
  interfaces with 64-bit pointers are rejected for Wasm.
- `wasm64`, threads, and `sys.io.Process` are not available, and file access
  uses an in-memory store.
- Wasm builds are build-only; `haxeon run` does not launch them.

See [`docs/WASM_BACKEND.md`](docs/WASM_BACKEND.md) for the host ABI and test
commands.

## ⚖️ How it compares

Hot reload is not new. These are the closest widely used tools, and how
Haxeon's approach differs.

| | **Haxeon** | **.NET Hot Reload** | **Dart / Flutter hot reload** |
|---|---|---|---|
| Language | Haxe-compatible subset | C#, F# | Dart |
| Runtime | HashLink (JIT) | CLR (`dotnet watch`, Visual Studio) | Dart VM (JIT, debug mode) |
| How edits apply | Compiler emits a patch of changed function bodies; the runtime validates and JIT-compiles it, then publishes it atomically | Compiler emits metadata/IL deltas applied to the running process | Updated source is compiled and injected into the running VM |
| Granularity | Function bodies, with stable function IDs | Method bodies and some member additions | Classes and functions |
| Failed or incompatible edit | Patch is rejected; the live program is untouched | Unsupported ("rude") edits require a restart | Reload fails or needs a hot restart |
| Structural changes | Explicit reload boundary; state moves through `saveState`/`restoreState` | Restart | Hot restart (state is lost) |
| Output when not live | Standard `.hl` bytecode, also Wasm and Android | Normal .NET assemblies | AOT binaries for release |
| Primary use | General applications, tools, and editors | General applications, web, desktop | UI development, mostly Flutter |

.NET Hot Reload and Flutter's hot reload are mature, polished workflows with
large ecosystems behind them. Haxeon's bet is different: make transactional
patching a core compiler and runtime contract rather than an IDE feature, on top
of a language that targets many platforms.

## 📚 Documentation

| Topic | Where |
|---|---|
| Project CLI, manifests, dependencies, workspaces | [`docs/CLI.md`](docs/CLI.md) |
| Supported Haxe subset, FFI, and native bindings | [`docs/LANGUAGE_SUPPORT.md`](docs/LANGUAGE_SUPPORT.md) |
| How patching works, reload rules, artifact builds | [`docs/LIVE_PATCHING.md`](docs/LIVE_PATCHING.md) |
| Compiler pipeline, SSA IR, HLB/HLI/HLP formats | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Patch transactions in depth | [`docs/PATCH_TRANSACTIONS.md`](docs/PATCH_TRANSACTIONS.md) |
| WebAssembly backend | [`docs/WASM_BACKEND.md`](docs/WASM_BACKEND.md) |
| Android host | [`docs/ANDROID.md`](docs/ANDROID.md) |
| Building, testing, bootstrapping, formatting | [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) |
| Benchmarks and profiling | [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md), [`docs/PROFILING.md`](docs/PROFILING.md) |
| More design notes | [`docs/`](docs/) |

## 🗺️ Project direction

The long-term goal is practical Haxe source compatibility where it matters,
with realtime behavior treated as a core compiler and runtime constraint rather
than an editor-side workaround.

The staged architecture, reload rules, and Pragtical conversion gates are
tracked in the [roadmap](ROADMAP.md).

## Platform, GPU, and UI libraries

Optional native integration libraries live in [packages/](packages/README.md). NativeKit provides their C ABI; Haxeon owns the managed wrappers, FFI bindings, and integration tooling.
