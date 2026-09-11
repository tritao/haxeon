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

The backend emits the WebAssembly exception tag/try/catch instructions for
programs with Haxeon exception edges. Exception-bearing functions currently
use the explicit CFG dispatcher so handler state and rethrow behavior remain
correct while structured exception regions mature; ordinary reducible scalar
CFGs use the structured lowering path, with the dispatcher retained as a
correctness fallback.

The module exports `main` and `memory`. It also carries two versioned custom
sections:

- `haxeon.gc.roots` contains precise SSA liveness at allocation/call
  safepoints.
- `haxeon.patch` contains stable function identities and semantic signatures
  for validating replacement table entries.

Static closures use stable table entries. Bound method closures use a small
linear-memory environment containing the function slot and receiver. Direct
object calls and interface calls remain semantic until Wasm lowering; virtual
calls dispatch through the object type ID in the managed header.

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

## Architectural invariants

- Haxeon IR owns semantic types and operations.
- Backend lowering owns physical representations.
- Wasm encoding owns binary sections and opcodes.
- GC roots are derived from SSA liveness, not conservative native-stack scans.
- Runtime ABI decisions use semantic declarations, not byte offsets.
- CFG normalization is an explicit pass; the dispatcher is only a correctness
  fallback for CFGs the current region builder cannot structure.

## Deliberate boundaries

`Wasm64` and Wasm GC are represented as target configurations below canonical
IR, but are not enabled by this bring-up yet. Ordinary `@:cNative` calls also
remain explicit backend errors: they require a Wasm host-import ABI rather
than being silently treated as HashLink natives. Use the HashLink backend for
those programs until that import contract is added.

`WasmTarget` already models linear32, linear64, and Wasm-GC reference modes.
Those modes remain below IR; adding them must not change `IrType` or
`IrInstruction`.
