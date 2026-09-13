# Haxeon WebAssembly backend

The Wasm backend lowers canonical Haxeon SSA IR. It does not lower from
HashLink registers or put Wasm locals, linear-memory offsets, or table slots
into the language IR.

```text
frontend / typer
      |
      v
canonical Haxeon IR
      |
      +-- SSA interpreter
      +-- HashLink backend
      `-- Wasm backend
            |
            +-- CFG analysis / region structuring
            +-- phi edge lowering / value placement
            +-- linear or GC representation
            +-- target Wasm instruction model
            `-- binary encoder
```

## Executable targets

Haxeon currently emits two executable Wasm targets:

- `wasm32` uses linear memory. Managed references are 32-bit pointers, and
  `WasmLayout` owns object, array, enum, closure, string, and byte offsets.
- `wasm-gc` (also spelled `wasmgc`) uses native WebAssembly GC references,
  structs, and arrays. `WasmGcTypePlan` reserves nominal and recursive type
  groups before function lowering; it does not use `WasmLayout` for managed
  objects.

Both targets share canonical IR, CFG lowering, arithmetic, calls, exceptions,
and the target-independent function and patch metadata. The GC target uses the
engine's tracing collector for managed references and emits no Haxeon
mark/sweep collector or shadow-root stack. Its ordinary modules need no linear
memory. Linear memory can still be added for raw-memory FFI operations.

The GC type plan covers the currently supported object and inheritance,
enum, array, map, iterator, closure, dynamic-value, string, and byte layouts.
The supported IR subset is still growing; unsupported operations and native
signatures fail explicitly during compilation. `scripts/test-wasm-gc-parity.sh`
compiles shared language fixtures for both targets and checks their results.

## Wasm32 linear memory and collector

Wasm32 modules export `main` and `memory` by default. The runtime uses a
non-moving mark/sweep collector with precise static and shadow-frame roots.
Each aligned heap block has an inline 16-byte header containing its physical
size, state and trace flags, payload-owner pointer, and auxiliary link. For
reference-bearing array or map storage, the link identifies the owner while
the block is allocated; for free blocks it links the free list. Marking
resolves a pointer directly to its header. Sweeping walks the heap, merges
adjacent dead blocks, and rebuilds the free list without an out-of-line
allocation metadata table.

Generated functions publish dense snapshots of live references at allocation
and call safepoints. Their shadow frames restore the root chain during tagged
exception unwinding. The reserved root area is bounds-checked and traps on
exhaustion. The collector traces known layouts precisely: declared object
fields, active enum payloads, live array elements, map keys and values, closure
receivers, iterator arrays, and the owner retained by a `Bytes.view`. It uses
conservative word scanning only for opaque layouts. Marking is iterative; its
temporary work queue grows linear memory only when required. Normal
allocations collect according to a byte budget, retry the free list, then grow
memory. Reused blocks are zero-filled. `--wasm-gc-stress` collects before each
allocation for collector tests.

`--wasm-memory-stats` adds exports for heap, root-stack, allocation, and
collection counters. The legacy `metadata_base` and `metadata_top` exports
remain temporarily available and report an empty region. Run
`scripts/benchmark-wasm-gc.sh [samples]` for a non-gating comparison of stress
and budgeted collection, including deep and wide graph tracing.

## Wasm GC references and linear memory

`wasm-gc` relies on Wasm references to keep managed parameters, locals, globals,
and object fields alive. It does not create `__haxeon_alloc`, collector helper
functions, a linear managed object heap, root-stack globals, or
`haxeon.gc.roots` metadata. Its nominal type planner preserves the Haxe object
and enum relationships needed by generated code while Haxe runtime type IDs
remain available for reflection and dispatch.

An ordinary Wasm-GC module exports `main` and does not export linear memory.
The current FFI boundary can add memory when needed: scalar C-native arguments
use typed Wasm imports, while declared byte-slice inputs and outputs are copied
through guest scratch memory. Returned native byte pointers also require guest
memory. Other aggregate and raw-memory ABI forms remain unsupported. Wasm-GC
compilation rejects the Wasm32 memory import, base, contract, and statistics
options.

Wasm32 accepts `--wasm-import-memory --wasm-memory-contract=<path>` for a
host-owned memory. The JSON contract is validated at compile time and copied
into the `haxeon.memory.contract` custom section. Hosts should compare that
section with their own contract before calling the guest. This option applies
only to `wasm32`.

Both targets emit `haxeon.patch` and `haxeon.patch.slots` custom sections with
stable function identities, semantic signatures, and table slots.
`WasmBackend.compilePatch` validates replacement artifacts against the
semantic ABI and returns a filtered manifest for atomic host publication.
Wasm32 uses linear-memory closure environments; Wasm GC stores closure
environments in GC-managed structs. Both retain the current function-table
dispatch model.

Wasm exception tags carry the backend's managed exception representation:
linear pointers for Wasm32 and GC references for Wasm GC. Exception-bearing
functions currently use the explicit CFG dispatcher so handler state and
rethrow behavior remain correct. Ordinary reducible scalar CFGs use structured
lowering, with the dispatcher retained as a correctness fallback.

## Building and testing

Bootstrap the pinned local compiler tools once:

```sh
./scripts/bootstrap-tools.sh
```

Run the focused backend tests and Wasm32/GC parity suite:

```sh
./scripts/test-wasm-backend.sh
./scripts/test-wasm-gc-parity.sh
```

The command-line compiler accepts `--target=wasm32` and `--target=wasm-gc`:

```sh
.tools/haxe/haxe --cwd . -cp src --run compiler.tools.HaxeonCompiler \
  --target=wasm-gc --output=out/main.wasm --entry=add \
  --root=stdlib --root=tests/programs tests/programs/add.hx
```

The driver supplies `haxeon` and `target=<target>` to every build. `wasm32`
adds `wasm` and `wasm32`; `wasm-gc` adds `wasm` and `wasmgc`. The HashLink
target adds `hl` and `sys`. Project defines can be added with repeated
`--define=NAME` or `--define=NAME=value` options. Target defines are reserved
and applied after project defines so the selected backend stays authoritative.

The same compile can publish the verified target-neutral IR container with
`--ir-output=out/main.hir`. HIR is versioned, preserves SSA value identity,
CFG edges, semantic runtime declarations, and typed native contracts, and can
be decoded independently before Wasm or HashLink lowering.

## Architectural invariants

- Haxeon IR owns semantic types and operations.
- Backend lowering owns physical representations.
- Wasm encoding owns binary sections and opcodes.
- Wasm32 root maps come from SSA reference types and liveness, not native-stack
  scans; generated shadow frames form the runtime root chain.
- Runtime ABI decisions use semantic declarations, not byte offsets.
- Patch decisions use `RuntimeAbi`, not Wasm code offsets.
- CFG normalization is explicit; the dispatcher is a correctness fallback
  for CFGs the region builder cannot structure.

## Deliberate boundaries

`wasm64` is accepted by the CLI but is not implemented by the backend yet.
Wasm-GC support is a real executable target, but the GC-compatible IR and FFI
subsets are still narrower than the complete Wasm32 backend. Unsupported
operations fail at the Wasm backend boundary instead of receiving guessed
representations.
