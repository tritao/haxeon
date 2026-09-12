# Haxeon WebAssembly backend

The Wasm backend is a target of canonical Haxeon SSA IR. It does not lower from
HashLink registers and it does not put Wasm locals, linear-memory offsets, or
table slots into the language IR.

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
            +-- target Wasm instruction model
            `-- binary encoder
```

## Current target contract

The current executable target is `wasm32` with linear memory. Managed values
are 32-bit references at this layer; scalar `Int`/`Bool` values are `i32` and
`Float` values are `f64`. `WasmLayout` is the only owner of object, array,
enum, closure, and string offsets.

Map operations are also implemented by the linear-memory runtime. Maps use a
fixed header plus pointer-backed entry storage, linear key lookup, capacity
growth, compact removal, and typed `keys()`/`values()` projections. Primitive
`get()` results are boxed into the existing dynamic-value layout so nullable
map reads retain the canonical IR semantics.

Array-backed `Iterator<T>` creation, `hasNext()`, and `next()` are explicit
typed IR operations. HashLink adapts them to its existing dynamic native ABI;
Wasm stores the source array and cursor in a GC-managed iterator record and
loads each item using its statically known element type. This keeps iteration
typed on Wasm without per-element dynamic boxing. The cursor observes the
array's current length on each `hasNext()`, and separate iterators over one
array maintain independent positions.

The backend emits the WebAssembly exception tag/try/catch instructions for
programs with Haxeon exception edges. Exception-bearing functions currently
use the explicit CFG dispatcher so handler state and rethrow behavior remain
correct while structured exception regions mature; ordinary reducible scalar
CFGs use the structured lowering path, with the dispatcher retained as a
correctness fallback.

The module exports `main` and `memory`. It also carries versioned custom
sections:

When the module is embedded into a host-owned memory, the compiler accepts
`--wasm-import-memory --wasm-memory-contract=<path>`. The JSON contract is
validated at compile time and copied into the `haxeon.memory.contract` custom
section. Hosts must compare that section with their own contract before calling
the guest.

- `haxeon.gc.roots` contains precise SSA liveness at allocation/call
  safepoints. Generated functions also maintain typed shadow frames in a
  reserved linear-memory root area, so the runtime has an actual root chain,
  not just an offline map. The current collector is a non-moving mark/sweep
  collector with compacted allocation metadata, a free list, and precise
  static/shadow-frame roots. Each allocation has an aligned private prefix
  pointing to its GC record, so tracing resolves references directly instead
  of scanning every record; metadata compaction refreshes those back-pointers.
  The prefix also identifies payloads that may contain managed references.
  Numeric-array backing stores and `Bytes` payloads are atomic and skipped during
  tracing; reference arrays and object fields remain traced. Collection still
  runs before selecting a block for each allocation, preserving the current
  safepoint/rooting guarantees. Recycled blocks are zero-filled before reuse,
  preserving Haxe's default values for fields, array elements, and byte storage
  just as newly grown Wasm memory does.
- `haxeon.patch` contains stable function identities and semantic signatures
  for validating replacement table entries. `haxeon.patch.slots` maps those
  stable names to exported function-table slots. `WasmBackend.compilePatch`
  produces a validated replacement artifact and filtered manifest; the host
  can instantiate it and publish changed table entries atomically.

Static closures use stable table entries. Bound method closures use a small
linear-memory environment containing the function slot and receiver. Direct
object calls and interface calls remain semantic until Wasm lowering; virtual
calls dispatch through the object type ID in the managed header.

Ordinary `@:cNative` declarations are emitted as typed WebAssembly function
imports. The import module is the declared native library (or `env` when the
library is empty), and the import field is the declared symbol. Pointer-like
Haxeon IR values use the linear-memory reference representation; no native
call is silently treated as a HashLink runtime function.

## Building and testing

Bootstrap the pinned local tools once:

```sh
./scripts/bootstrap-tools.sh
```

Run the focused backend and Node execution tests:

```sh
./scripts/test-wasm-backend.sh
```

The command-line compiler accepts `--target=wasm32` and writes a `.wasm`
module plus a function manifest:

```sh
.tools/haxe/haxe --cwd . -cp src --run compiler.tools.HaxeonCompiler \
  --target=wasm32 --output=out/main.wasm --entry=add \
  --root=stdlib --root=tests/programs tests/programs/add.hx
```

The driver also supplies target defines before source analysis. Every build
gets `haxeon` and `target=<target>`; `wasm32` adds `wasm` and `wasm32`, while
the HashLink target adds `hl` and `sys`. Project-specific defines can be added
with repeated `--define=NAME` or `--define=NAME=value` options:

```sh
... --target=wasm32 --define=nativekit_web --define=feature=on ...
```

Target defines are reserved and are applied after command-line project
defines, so the selected compiler target remains authoritative. Keep
platform-specific entry loops in small host classes; use conditional
compilation in shared code only for genuinely target-sensitive behavior.

The same compile can publish the verified target-neutral IR container with
`--ir-output=out/main.hir`. The HIR is versioned, preserves SSA value identity,
CFG edges, semantic runtime declarations, and typed native contracts, and can
be decoded independently before any Wasm or HashLink lowering.

## Architectural invariants

- Haxeon IR owns semantic types and operations.
- Backend lowering owns physical representations.
- Wasm encoding owns binary sections and opcodes.
- GC roots are derived from SSA reference types and SSA liveness metadata, not
  conservative native-stack scans; generated shadow frames are the runtime
  root-chain boundary.
- Runtime ABI decisions use semantic declarations, not byte offsets.
- Stable closures use exported table slots and versioned patch metadata; a
  patch decision is made from `RuntimeAbi`, never from Wasm code offsets.
- CFG normalization is an explicit pass; the dispatcher is only a correctness
  fallback for CFGs the current region builder cannot structure.

## Deliberate boundaries

`Wasm64` and Wasm GC are accepted as explicit target requests so capability
errors occur at the Wasm backend boundary, but are not enabled by this
bring-up yet. C-native signatures that require
multi-value aggregates or unsupported scalar representations still fail
explicitly during Wasm lowering; those need a versioned ABI extension rather
than an implicit representation guess.

`WasmTarget` already models linear32, linear64, and Wasm-GC reference modes.
Those modes remain below IR; adding them must not change `IrType` or
`IrInstruction`.
