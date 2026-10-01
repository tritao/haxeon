# Wasm linear-memory runtime in C

The `wasm32` backend keeps Haxe values in linear memory and needs a runtime: an
allocator, a collector, and the array, map, string and byte operations. Today it
is about 8,600 lines of Haxe that emit Wasm instructions directly
(`src/compiler/backend/wasm/linear/`), while HashLink runs the same operations
from about 4,800 lines of C (`native/runtime/`). The two are kept in step by
hand; `WasmLinearDynamicArrays` says it is a port of `arrays.c`.

The plan is one runtime written in C, compiled for HashLink as before and for
`wasm32` with clang, and linked by Haxeon into every `wasm32` module.

## Why

- Profiling the browser editor (2026-10-01) put 78% of a `wasm32` frame in the
  emitted allocator, a first-fit walk over one free list. Fixing that in emitted
  Wasm is slow to write and to review; in C it is ordinary code.
- Every runtime fix lands twice today, in C and in instruction emitters, and the
  two drift.

## How the runtime reaches a module

Haxeon links it; the output stays one module and embedders change nothing.

- `runtime/wasm/*.c` builds with clang (`--target=wasm32 -O2 -nostdlib
  -mbulk-memory`, `--import-memory`, `--no-entry`) into
  `runtime/wasm/linear-runtime.wasm`, which is committed. The build script
  checks that the module has no data segments, globals, table or stack, so it
  needs nothing from the linker but memory: runtime state lives in a struct at
  an address Haxeon reserves and passes in.
- The runtime imports `env.memory` and the guest functions it calls back
  (module `haxeon_guest`, for example `collect`), and exports its entry points.
- Haxeon decodes the runtime module and appends its functions to the output:
  bodies are copied as bytes with `call` immediates remapped, the memory import
  becomes the module's memory, `haxeon_guest` imports bind to guest functions by
  name, and exports become ordinary function indices that lowering calls.

Clang is needed only to rebuild the runtime, not to compile Haxe programs.

## Milestones

1. **Linker** (done). `WasmRuntimeLinker` decodes and merges the runtime module.
2. **Allocator and sweep in C** (done, `native/wasm/heap.c`). Exact-size free
   lists below 1 KiB and one first-fit list above, sweep with coalescing, and
   the collection budget, with the heap state in `hx_heap` instead of Wasm
   globals. Guest code keeps marking and tracing. In the browser editor a frame
   while hovering the 3D view went from 25 ms to 4.1 ms (wasm-gc: 3.1 ms).
3. **Marking in C.** Haxeon emits per-type reference layouts as static data; the
   runtime marks from the shadow stack and a root table. Replaces the emitted
   mark and trace in `WasmLinearGc`.
4. **Shared operations.** Arrays, maps, strings and bytes from the same C files
   as HashLink, behind a small header for object layout and allocation;
   replaces `WasmLinearArrays`, `WasmLinearDynamicArrays` and parts of
   `WasmLinearRuntime` one area at a time, with the parity suite as the gate.

The `wasm-gc` backend is unaffected: the browser collects its objects.
