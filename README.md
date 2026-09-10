# Haxeon ⚡

> **Haxe, always on.**

Haxeon is an experimental Haxe-compatible language and realtime compiler for
HashLink. It combines familiar Haxe syntax and static typing with incremental
compilation, transactional hot patching, and a runtime designed to keep an
application running while its code changes.

Haxeon currently implements a growing subset of Haxe. It is a serious compiler
experiment and is not yet recommended for production applications.

## 🔥 Why Haxeon?

Traditional development repeatedly stops, rebuilds, and restarts an
application. Haxeon is built around a continuous development loop:

1. Edit Haxe-compatible source.
2. Recompile only what changed.
3. Validate the resulting patch.
4. Atomically install it into the running HashLink program.
5. Keep existing state, objects, and closures alive.

If a patch is malformed, stale, or incompatible, the running program remains
untouched.

## ✨ Highlights

- Familiar Haxe-compatible syntax with static type checking
- A self-hosted compiler running on HashLink
- Incremental parsing, typing, and IR generation
- Function-level change detection and stable function identities
- Transactional, multi-function hot-code replacement
- Live callers and closures that immediately observe committed replacements
- Explicit reload boundaries for incompatible structural changes
- Persistent compiler identity across compiler and editor restarts
- Reclamation of superseded JIT allocations after protected calls finish
- Standard `.hl` output for ordinary HashLink compatibility

## 🧭 What Haxeon is

Haxeon is both a focused Haxe-compatible language implementation and a live
execution environment built on a patchable HashLink runtime.

For the initial application load, the compiler emits a standard HashLink
bytecode module—the same format normally stored in a `.hl` file. Compatible
edits become compact Haxeon patch data containing only changed function bodies
and the symbol additions they require. The runtime validates and JIT-compiles
the entire patch privately before publishing it as one atomic transaction.

Haxeon is not currently a drop-in replacement for the complete Haxe compiler.
Language and standard-library coverage are still expanding, and edits that
change the live module's structure may require a reload.

## 🏗️ How it works

```text
Haxe-compatible source
        │
        ▼
 Lexer → Parser → Type checker
        │
        ▼
 Immutable SSA IR
        │
        ▼
 HashLink lowering and assembly
        │
        ├── Initial build ──→ HashLink bytecode module (.hl)
        │                      + Haxeon identity manifest
        │
        └── Compatible edit → Haxeon patch
                               │
                               └── validate → stage → commit
```

The implementation uses three short format names:

- **HLB** is the standard serialized HashLink bytecode format. Its bytes begin
  with the `HLB` signature and are normally written as a `.hl` file.
- **HLI** is Haxeon's companion identity manifest. It binds a module identity
  and stable Haxeon function IDs to the function slots in an initial HLB module.
- **HLP** is Haxeon's versioned patch protocol. It carries validated symbol
  additions and replacement function bodies between incremental builds and the
  live runtime.

HLI and HLP are Haxeon-specific data formats; neither changes the standard HLB
module, so generated `.hl` files remain compatible with ordinary HashLink.

The frontend is divided into parsing, declaration and type checking, and IR
generation. Modules retain their source, tokens, syntax trees, typed trees,
dependencies, diagnostics, and generated IR. Body and signature fingerprints
allow Haxeon to reuse unaffected artifacts and propagate invalidation only where
required.

IR values are immutable SSA definitions. Assignments create new values, while
condition joins and mutable loop headers receive explicit, predecessor-complete
phi nodes. The HashLink backend eliminates those phis on incoming edges with
parallel-copy snapshots, emits real `OLabel` block markers, and leaves no SSA
constructs in the serialized bytecode module or patch.

## 🧩 Language support

The current subset includes:

- `Int`, `Bool`, `Float`, `String`, nullable values, and dynamic values
- Local variables, functions, methods, recursion, and expression statements
- Classes, interfaces, anonymous structures, enums, and enum abstracts
- Closures with generated environments and shared cells for mutable captures
- Arrays and compiler-owned primitive, string, and reference array operations
- Primitive and reference-valued `Map<String, T>` and `Map<Int, T>` forms
- Arithmetic, bitwise operations, comparisons, string operations, and casts
- `if`/`else`, `switch`, `while`, `do`/`while`, `for`, `break`, and `continue`
- Array iteration and comprehensions
- Exceptions
- Simple `typedef` aliases and generics
- Haxe-compatible `Sys` operations through the stable runtime ABI

String addition, equality, `.length`, `indexOf`, and `substring` use the
compiler-owned runtime ABI. Arrays support checked indexing, `.length`, `copy`,
`concat`, `slice`, `indexOf`, `push`, and `pop`. Capacity-aware array growth
preserves object identity so aliases and fields continue to observe the same
array.

Hosts may register typed HashLink natives with `Compiler.registerNative()`
before the first build. Registrations then freeze so the native-table layout
cannot silently change beneath a live module. `compiler.RuntimeAbi.register()`
installs the stable host surface used by the command-line compiler; Haxeon-owned
realtime operations remain in a separately versioned ABI.

Unsupported ABI combinations produce explicit typed diagnostics instead of
silently falling back to dynamic behavior.

### Source-declared HashLink bindings

Target functions can be declared without a Haxe body by combining `extern`
with `@:hlNative`:

```haxe
@:hlNative("std", "sys_time")
extern function nativeTime():Float;
```

The two metadata arguments are the HashLink library and exported symbol.
Bindings participate in normal name and type checking, but emit only a native
table entry. Missing, duplicate, non-string, or malformed bindings are compile
errors. Static methods on `extern class` and static or instance methods on
`extern abstract` use the same form; an instance abstract method passes its
underlying representation as native argument zero.

An extern class or abstract can provide a default library for all its methods.
The method name is used as the native symbol unless the method carries its own
two-argument `@:hlNative` binding:

```haxe
@:hlNative("platform")
extern class Native {
    public static function poll():Int;

    @:hlNative("override", "renamed")
    public static function draw():Void;
}
```

An extern abstract can declare its HashLink storage independently of its source
identity:

```haxe
@:hlType("bytes")
extern abstract Bytes(Dynamic) {}

@:hlType("nativeAbstract")
extern abstract Abstract<T>(Dynamic) {}
```

The supported representations are currently `bytes` and `nativeAbstract`.
Tagged types such as `hl.Abstract<"realtime_module">` use the latter and retain
the quoted tag as part of their ABI identity. These target declarations live
under `stdlib/hl`; unsupported representation names are diagnosed rather than
silently lowered as ordinary objects.

## 🛡️ Transactional patching

Haxeon treats hot replacement as a transaction, not a best-effort reload:

- Every live module has a 128-bit identity.
- Functions receive persistent stable IDs independent of bytecode ordering.
- Patches carry an expected base revision and replacement revisions.
- Symbol tables are verified by prefix length and content hash.
- Patch call sites use stable-target relocations rather than stale bytecode
  function-table indices.
- All replacements are validated and JIT-compiled before publication.
- Multi-function patches become visible atomically.
- Failed staging is discarded without changing the live program.
- Stale, replayed, cross-module, and incompatible patches are rejected.

Calls and commits are synchronized. Permanent per-slot dispatch entries keep
existing closures and object prototypes valid, while superseded JIT code is
reclaimed after protected calls complete. Retained objects and closures pin
their owning module until released, and module disposal is idempotent.

Type-table growth remains a reload boundary because initialized HashLink modules
store direct `hl_type*` pointers. Haxeon fails closed for new function or
structural types until the runtime has a non-moving type arena.

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

### Android host

The first Android host embeds the HashLink runtime and the existing JIT
backends directly in `libhaxeon.so`; it does not translate Haxeon to JVM or
Android VM bytecode. Gradle generates a small `.hl` asset and packages the
host for `arm64-v8a` and `x86_64`:

```sh
source scripts/android-env.sh
./scripts/build-android.sh assembleDebug
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The host keeps one Haxeon runtime module alive and exposes a loopback patch
port forwarded through `adb`. After changing `android/demo/Main.hx`, compile
and send a compatible body patch without rebuilding the APK:

```sh
./scripts/build-android-patch.sh
./scripts/android-send-patch.sh
```

The patch compiler stages a new baseline beside `android/app/src/main/assets/app.hcs`;
the send command promotes it only after the device acknowledges the patch.
Structural edits are sent as a full domain reload, still without rebuilding the
APK:

```sh
./scripts/build-android-reload.sh
./scripts/android-send-reload.sh
```

The reload bundle replaces the loaded HLB module and HLI manifest only after
the new module initializes and its `main` call succeeds. Its staged compiler
baseline is promoted only after the device acknowledges the replacement.

The local Android SDK, NDK, CMake, Gradle, and emulator are kept under
`.tools/`. Source `scripts/android-env.sh` when using `adb`, `emulator`, or
Gradle directly. The disposable API 36 emulator used for the smoke test is
named `haxeon-api36-x86_64`.

The full test script runs program fixtures with 16 workers by default. Set
`TEST_JOBS=1` for the sequential baseline, or invoke the driver directly to
select a suite or test:

```sh
TEST_JOBS=1 ./scripts/test.sh
.tools/haxe/haxe -cp tests --run driver.TestDriver --suite programs --jobs 16
.tools/haxe/haxe -cp tests --run driver.TestDriver --suite compiler --test ParserRecovery
```

The cross-platform Haxe build entry point provides the native build, bootstrap,
and core test workflow without Bash. This is the path used by Windows CI:

```sh
.tools/haxe/haxe -cp src --run build.HaxeonBuild native
.tools/haxe/haxe -cp src --run build.HaxeonBuild bootstrap-self
.tools/haxe/haxe -cp src --run build.HaxeonBuild test 16
```

`bootstrap/compiler.hl` is checked in. For ordinary compiler development,
`bootstrap-compiler.sh --self` rebuilds it with the checked-in compiler and
pinned HashLink without invoking the reference Haxe compiler.

The full bootstrap uses pinned reference Haxe to build the compiler, then asks
that compiler to build itself and requires byte-for-byte equality. Both modes
derive the same sorted source manifest from `src/` and build the native runtime
bridge before compilation.

The writer currently targets HashLink bytecode format version 6, matching the
decoder in `src/code.c`.

## 📊 Benchmarks

Run the repeatable edit-to-runtime benchmark:

```sh
./scripts/benchmark.sh
```

It reports median, p95, and p99 latency for cold compilation, no-op rebuilds,
body patches, signature reloads, and structural reloads. It also runs a patch
soak test and writes machine-readable results to `out/benchmark.json`.

Attribute soak-test memory growth with isolated compiler and runtime passes:

```sh
./scripts/benchmark.sh --only-soak --soak-mode compiler \
  --json out/benchmark-compiler.json
./scripts/benchmark.sh --only-soak --soak-mode runtime \
  --json out/benchmark-runtime.json
```

Generate scaling results and compare two runs:

```sh
./scripts/benchmark.sh --only-scale --json out/benchmark-scale.json
./scripts/benchmark-compare.sh baseline.json out/benchmark-scale.json
```

Use `--iterations`, `--warmup`, `--soak`, `--scales`, and
`--scale-iterations` to tune a run. Benchmark comparisons are informational and
do not enforce thresholds.

## 🧪 Development

### Native build

Haxeon uses CMake for its cross-platform native build and Ninja as the default
backend. HashLink is built from the pinned `vendor/hashlink` submodule; the
resulting VM and library are placed in `.tools/hashlink`, while Haxeon's runtime
HDLL is placed in `out`.

```sh
cmake --preset release
cmake --build --preset release
```

The same build can be driven by the cross-platform Haxe entry point:

```sh
.tools/haxe/haxe -cp src --run build.HaxeonBuild doctor
.tools/haxe/haxe -cp src --run build.HaxeonBuild native release
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

Pinned dependency versions, archive checksums, extraction, and submodule setup
are defined once in `cmake/Bootstrap.cmake`. The platform setup scripts are
thin launchers for that shared bootstrap rather than separate installers.

Haxe sources use the repository-pinned Haxe Formatter:

```sh
./scripts/format.sh
./scripts/format.sh --check
```

`bootstrap-status.sh` runs the real lexer, parser, and typer over the compiler
source tree and reports bootstrap progress. Pass `--json` for a machine-readable
dashboard.

## 🗺️ Project direction

The long-term goal is practical Haxe source compatibility where it matters,
with realtime behavior treated as a core compiler and runtime constraint rather
than an editor-side workaround.

The staged architecture, reload rules, and Pragtical conversion gates are
tracked in the [roadmap](ROADMAP.md). Deeper design notes live in
[`docs/`](docs/), including patch transactions, metadata ownership, module
reclamation, semantic contracts, and the implementation baseline.
