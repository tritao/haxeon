# Wasm linear-memory runtime in C

The `wasm32` backend keeps Haxe values in linear memory and needs a runtime: an
allocator, a collector, and the array, map, string and byte operations. Most of
it is still about 8,600 lines of Haxe that emit Wasm instructions directly
(`src/compiler/backend/wasm/linear/`), while HashLink runs the same operations
from about 4,800 lines of C (`native/runtime/`). The two are kept in step by
hand; `WasmLinearDynamicArrays` says it is a port of `arrays.c`.

The direction is one runtime written in C for both, compiled for HashLink as
before and for `wasm32` with clang, and linked by Haxeon into every `wasm32`
module. The allocator and sweep are there already; the rest waits on the object
model (see [Long term](#long-term-hashlinks-object-model)).

The `wasm-gc` backend, which the browser editor uses by default, keeps browser-managed
objects. It shares the object-independent cryptographic kernels described below.

## Why

- Profiling the browser editor (2026-10-01) put 78% of a `wasm32` frame in the
  emitted allocator, a first-fit walk over one free list. Fixing that in emitted
  Wasm is slow to write and to review; in C it is ordinary code.
- Every runtime fix lands twice, in C and in instruction emitters, and the two
  drift.

## How the runtime reaches a module

Haxeon links it; the output stays one module and embedders change nothing.

- `native/wasm/*.c` builds with clang (`--target=wasm32 -O2 -nostdlib
  -mbulk-memory`, `--import-memory`, `--no-entry`) through
  `scripts/build-wasm-runtime.sh` into `stdlib/haxeon/wasm/linear-runtime.wasm`,
  which is committed. The script checks that the module has no data segments,
  globals, table or stack, so it needs nothing from the linker but memory:
  runtime state lives in a struct at an address Haxeon reserves and passes in.
  `--check` fails when the committed module differs from a fresh build; the
  backend test runs it when clang is available.
- The runtime imports `env.memory` and the guest functions it calls back
  (module `haxeon_guest`, for example `collect`), and exports its entry points.
- `WasmRuntimeLinker` decodes the runtime module and appends its functions to
  the output: bodies are copied as bytes with `call` targets renumbered, the
  memory import becomes the module's memory, `haxeon_guest` imports bind to
  guest functions by name, and exports become function indices lowering calls.

Clang is needed only to rebuild the runtime, not to compile Haxe programs.

## Done

1. **Linker.** `WasmRuntimeLinker` decodes and merges the runtime module.
2. **Allocator and sweep in C** (`native/wasm/heap.c`). Exact-size free lists
   below 1 KiB and one first-fit list above, sweep with coalescing, and the
   collection budget, with the heap state in `hx_heap` instead of Wasm globals.
   Guest code still marks and traces (`WasmLinearGc`). In the browser editor a
   frame while hovering the 3D view went from 25 ms to 4.1 ms (wasm-gc: 3.1 ms).

## Long term: HashLink's object model

HashLink's C runtime cannot simply be compiled for `wasm32`, because it is
written against HashLink's object model, not just in C: `arrays.c`, `maps.c` and
the rest use `hl_type *` headers, `varray`, `vdynamic`, `vobj`,
`hl_alloc_array`, `hl_safe_cast` and `hl_get_obj_rt` throughout. `wasm32`
objects have a model of their own: an integer type id in the first word, and
their own array, map and box layouts.

Moving `wasm32` onto HashLink's object model is probably the way to go and
should be done eventually. Objects would start with an `hl_type *` pointing at
type descriptors Haxeon emits into static data, laid out for `wasm32`, and
arrays, dynamics and objects would use HashLink's layouts. Then HashLink's own C
compiles for `wasm32` largely unchanged, including precise marking from each
type's reference bitmap, and both targets run one runtime and one object model.
It is a large change: every layout, type test, boxing path and runtime helper in
the `wasm32` backend moves at once, and the runtime must provide the part of
HashLink's core API that its C calls.

Until then, `wasm32` is a fallback for hosts without Wasm GC and is held where
it is. Two smaller steps were considered and set aside, because the object
model change would replace them:

- **Marking in C** with a `wasm32`-specific table of reference offsets per type.
  Marking is about 1–2% of an editor frame now, so it buys tidiness rather than
  speed, and HashLink's reference bitmaps would replace the table.
- **Arrays, maps, strings and bytes in C** against the current `wasm32` layouts.
  That moves the code to C but keeps two runtimes and two object models.

## Shared SHA-256 kernel

`haxe.crypto.Sha256.make` and `encode` use the same synchronous C SHA-256 kernel
on HashLink, `wasm32`, and `wasm-gc`. The implementation lives in
`native/shared/sha256.h`; thin wrappers adapt HashLink byte buffers and the Wasm
C ABI. It owns no persistent state and leaves the input unchanged.

`scripts/build-wasm-runtime.sh` also builds the committed
`stdlib/haxeon/wasm/crypto-runtime.wasm`. `WasmCryptoRuntime` links it only when a
crypto function is used, through `HaxeonCrypto.hxi` and the existing C ABI bridge.
The resulting application needs no JavaScript crypto imports or asynchronous API.
On `wasm-gc`, the bridge copies managed bytes into temporary linear memory and
copies the digest back. Scratch space is caller-owned and aligned; the kernel
needs no global, data segment, allocator, or stack pointer.

Tools compiled with upstream Haxe use `build.execution.ContentDigest` to adapt
its HashLink Bytes ABI to the same kernel. Other upstream Haxe targets keep their
standard SHA-256 implementation. `Sha256.portableMake` retains the Haxe reference
implementation for differential testing and benchmarking.

Run `tests/integration/test-sha256-runtime.sh` after building the native runtime.
It checks known digests, padding boundaries, a million-byte input, unaligned byte
views, input preservation, and reference parity on all three backends. It needs
Node with Wasm GC support. `tests/bench/sha256/Sha256Benchmark.hx` provides native
and exported browser benchmarks; timings depend on the engine and ABI copy cost.
