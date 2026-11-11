# Architecture

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

The same canonical IR can also be emitted as experimental `wasm32` or `wasm-gc`;
see [`WASM_BACKEND.md`](WASM_BACKEND.md) for the representation
boundary, linear-memory and collector contracts, GC target, and test commands.

## Warm builds: what landed (M0 and M1 of ADR 0003)

The current plan and the measurements are in [`WARM_REBUILD_REUSE.md`](WARM_REBUILD_REUSE.md) and
[`COMPILER_MEMORY.md`](COMPILER_MEMORY.md). This section is the short record.

### Layers of a plain build

typed program, then IR (`IrGenerator`), then whole-program IR passes and `IrInliner`, then verification, then HashLink lowering
(`HlLower`), then the writer. Each stage keeps what the next build can reuse:

- **Pipeline shortcut.** When the typed-function IR, the canonical tables and the environment text (target, defines,
  `ProgramFacts.inputState`) equal the last plain build's, the final IR and the module bytes are reused (`reused: ir+module`).
  A miss says why (`--timings`).
- **Per-function verification.** `IrVerifier` reads the rest of the program only through `IrVerifyTable`s. `IrVerifyMemo` records what
  each accepted function read, so a build verifies the functions that changed and the ones whose reads changed.
- **Relocatable lowering.** `HlLower` records, for every function, the requests it made to the symbol tables and the facts it read about
  object types (through `HlLoweringView`, the only way lowering sees another entity). `HlLink` replays them against the next build's tables
  and gives the function its indices, so a function whose IR and facts are unchanged is linked, not lowered again.
  `HlLoweredCache` holds the entries.
- **Live patching** uses the same cache with trust instead of replay: append-only tables and stable slots keep a kept function's operands
  valid, so an entry not named in `regenerated` is kept as it is (`HlModuleAssembler.livePatching`).

### What generation reads

- `TargetProfile` (`HashLink` or `Wasm`): `packedValueFields`, `headerlessValueClasses`, `dynamicObjectLiterals`, `nativeArrayChecks`,
  `nativeStringFastPaths`, `nativeReflectionDispatch`. Immutable; `key()` is part of every cache key that depends on the target.
- `ProgramFacts.of(typed)`: enum constructor counts, value classes, class bases, generic owners, equatable and observable facts, interface
  contracts. Derived on every build.
- `IrGenerator` is an instance over `(facts, profile)`, with `withObjects(objects)` giving it the program's object tables as input and a
  fresh `FunctionScratch` per function. No generator state outlives a build. Left static on purpose: the `HAXEON_*` switches, a debug-location
  memo, and the Wasm caches (a follow-up).

### Session caches and the commit point

The inline cache, the pipeline snapshot, the lowered cache, the reachability cache, the declaration owners and the modules belong to
the last successful build. A build works on copies (`createCandidate`) and `adoptCandidate` replaces them together; a failed or rejected
build (including a failed artifact write) restores all of them with the modules (`CompilerSnapshot`). The verify memo is shared because an
acceptance holds only while its reads do.

### Check mode

`HAXEON_CHECK_REUSE=1` recomputes what a build reused and fails, naming the function, when the two differ: the shortcut is re-run, every
linked function is compared with a fresh lowering, the final IR is verified in full after the memoized run, and in a live build every kept
function is lowered again (`HlFunctionEquality`: type, slot, registers, opcodes with labels compared one to one, debug data). Functions
frozen on purpose (retired by a signature change, or dropped from the program) are skipped. The full driver suite and `test-hot-reload` pass
with it. It is a test aid, never a fallback.


## Performance rules for compiler code

- **Iterating a Map goes through dynamic calls in the stock-Haxe worker.** An iterator is a structural type, so `for (x in map)`,
  `for (k => v in map)` and `map.keys()` make a dynamic call per element (about 3% of a cold build before the hot sites were fixed). On a
  hot path keep an array next to the map, filled where entries are added, and iterate that. The Haxeon-built worker (ADR 0003 section 12)
  may make this moot; until then it is measured, not folklore.
- **Hash a name once.** A name used for several lookups in a pass (a callee, a local) is looked up once to get a dense number, and the
  per-name state after that is an array indexed by it (see `SsaBuilder`, `IrInliner`).
- **A new map keyed by a string that a pass fills and a hot loop reads is a candidate for the two rules above**; check a profile share before
  and after (`hlprof-live`, folded stacks), not the wall time of a loaded machine.
