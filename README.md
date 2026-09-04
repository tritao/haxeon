# realtime-haxe

An experimental Haxe-compatible realtime compiler targeting HashLink only.

The proof of concept compiles a small Haxe-compatible source file through a
lexer, parser, AST, typed IR, and HashLink backend. The generated entry point
passes the source `main()` result to HashLink's `std@sys_exit` native, making
the result observable to the integration test.

The example is expressed as typed, register-independent IR. `HlLower` assigns
function/type/register indices, interns constants and native names, and lowers
the IR to the serialized HashLink model.

The frontend is split into parsing, declaration/type checking, and IR
generation. The current subset supports `Int`, `Bool`, local variables,
functions, calls, arithmetic, comparisons, nested `if`/`else`, and recursive
functions.

IR values and control-flow blocks have numeric identities independent of
source names. Functions contain explicit basic blocks terminated by `Return`,
`Jump`, or `Branch`, and an IR verifier checks the graph and types before HL
lowering.

`compiler.modules.Compiler` retains source, tokens, syntax trees, typed trees,
dependencies, diagnostics, and generated IR per module. Qualified calls such
as `Math.add(20, 22)` create dependency edges; updating a module invalidates
its typed dependents while unrelated parsed and typed state is reused.

Function signatures and bodies have separate fingerprints. Body edits replace
only that function's typed and IR artifacts; signature edits propagate through
the function call graph. Cached IR objects for unaffected functions are reused
when the executable module is assembled.

The session-scoped HL assembler assigns append-only indices to functions,
types, strings, and constants. Compilation reports changed function indices
and whether a structural edit requires reload. Removed functions retain a
tombstone slot until `Compiler.compact()` performs a deterministic full rebuild.

The runtime proof of concept loads compiler-produced HLB bytes in-process and
calls functions through compiler-owned stable slots. A compatible edit arrives
as HLP, is validated and JIT compiled privately, and then commits all selected
slots atomically. Failed compilation, malformed bytecode, and structural edits
leave the live code untouched. `vendor/hashlink` tracks
our HashLink fork, which exports the module lifecycle needed by the runtime
bridge and provides an opt-in `HL_MODULE_PATCHABLE` JIT mode. Calls in that mode
dispatch through the module function table, so already-JITed callers immediately
observe a committed replacement. Names and debug metadata are deliberately not
used as function identity.

Calls and commits are synchronized. Each stable slot records its owning JIT
allocation; replacing its last referenced slot reclaims that allocation after
protected calls finish. Failed staging is discarded before publication, keeping
repeated editor reloads bounded. Runtime modules also support explicit disposal.
Patch sets carry expected-base and replacement revisions; stale or replayed
updates are rejected before loading or changing live dispatch state.

Compatible incremental builds also emit versioned `HLP` bytes. The patch format
contains the stable symbol/type requirements and only the changed function
definitions, with a strict Haxe decoder serving as the protocol oracle for the
native HashLink decoder. The fork exposes owned `hl_patch_read`/`hl_patch_free`
APIs with strict bounds, version, opcode, function-length, and trailing-data
validation; integration tests feed identical bytes through both decoders.
`hl_module_apply_patch` resolves those records against the live module and JITs
only their functions. Tests instrument the JIT to prove one changed function
causes one compilation and two-function patches publish as a single transaction.

## Run the proof of concept

```sh
./scripts/bootstrap-tools.sh
./scripts/test-poc.sh
./test-hot-reload.sh
```

Bootstrap/reference Haxe is downloaded below `.tools/`, while the runtime is
built from the pinned `vendor/hashlink` submodule. Normal development will
eventually use the checked-in bootstrap compiler instead of official Haxe.

The writer currently targets bytecode format version 6, matching the current
HashLink decoder in `src/code.c`.
