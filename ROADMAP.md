# Realtime Haxe / Pragtical migration roadmap

This project is a Haxe-compatible compiler whose primary target is HashLink.
The official Haxe compiler is a bootstrap and differential-testing oracle only;
it is not part of the normal editor build.

## Non-negotiable architecture

```text
source -> tokens -> AST -> typed AST -> SSA IR -> HL lowering -> HLB/HLP
```

- The frontend owns Haxe semantics, source spans, symbols, and diagnostics.
- SSA is an internal compiler representation. HashLink does not need to know
  about SSA, phi nodes, or source locals.
- The HL backend owns encoding, stable append-only symbol tables, and ABI
  validation. It must never infer semantics from debug names.
- The forked HashLink owns live-module dispatch, patch staging, JIT lifetime,
  and the non-moving runtime type arena needed for safe reloads.
- The editor talks to a persistent compiler service, never to individual
  compiler passes or the official Haxe executable.

## Gates before Pragtical conversion

### A. Language and backend core

- [x] Integer/float/string/bool expressions, branches, loops, recursion.
- [x] Typed locals, nominal classes, fields, constructors, inheritance.
- [x] SSA construction, verification, phi elimination, deterministic lowering.
- [x] Function values for non-capturing references.
- [ ] Capturing closures and instance closures.
- [ ] Arrays, maps, enums, nullable values, and pattern matching.
- [ ] Interfaces, virtual dispatch, and basic generics.
- [ ] A documented runtime library ABI for strings, collections, IO, and time.

### B. Incremental compiler service

- [x] Persistent module state and dependency graph.
- [x] Separate signature/body fingerprints and selective regeneration.
- [x] Stable function IDs, tombstones, compaction, and identity persistence.
- [x] Typed function-value dependency invalidation.
- [ ] Import-aware symbol resolution with package-qualified nominal names.
- [ ] Source edits represented as transactions with diagnostics and rollback.
- [ ] Parallel parse/type work with deterministic assembly on the editor thread.
- [ ] Memory and latency budgets measured on a realistic Pragtical project.

### C. Runtime and hot reload

- [x] Forked HashLink submodule and reproducible local tool bootstrap.
- [x] HLP framing, strict validation, stable-target relocations, and atomic
  compatible function patching.
- [x] Revision checks, stale-patch rejection, call synchronization, and JIT
  allocation reclamation.
- [ ] Non-moving type arena for compatible type-table growth.
- [ ] Explicit reload domains for structural class changes.
- [ ] Plugin lifecycle/state migration API for domain reloads.
- [ ] In-memory module loading and patching without temporary `.hl` files.
- [ ] Crash-safe diagnostics and recovery when a patch fails in native code.

### D. Language service

- [ ] Token/AST/type snapshots keyed by source revision.
- [ ] Diagnostics, completion, hover, definition, references, rename, and
  document symbols from compiler state.
- [ ] Completion-safe partial parsing and error recovery.
- [ ] A small protocol adapter for Pragtical; no second typechecker.

### E. Self-hosting and release engineering

- [ ] Keep compiler sources inside the implemented subset.
- [ ] Bootstrap compiler A with official Haxe.
- [ ] Build compiler B using A and compare behavior against A.
- [ ] Check in a reproducible `bootstrap/compiler.hl`.
- [ ] Build/test in CI from the pinned HashLink fork and formatter version.
- [ ] Differential suite: official HL and realtime HL must agree on behavior,
  diagnostics where practical, and reload classifications.

## Feature order after the current milestone

1. Add capturing closures using generated environment objects plus
   `OInstanceClosure`; keep closure layout private to the compiler/runtime ABI.
2. Add a first-class `Array<T>` runtime type and bounds-checked indexing using
   HashLink array operations. Start with `Int`, `Float`, and object arrays.
3. Add enums/nullable values and pattern matching on the same tagged-value
   rules used by the runtime bridge.
4. Add interfaces and virtual method prototypes; direct calls remain an
   optimization, never the semantic contract.
5. Add package/import resolution, then migrate a small Pragtical utility
   plugin as the first real multi-module workload.
6. Expose compiler snapshots as the editor language service.
7. Add structural reload domains and state migration, then move larger editor
   subsystems and finally the editor core.

## Definition of Pragtical-ready

The compiler is ready for a staged Pragtical conversion when a representative
plugin can be edited and saved while the editor keeps running; compatible
function edits patch in place; class-layout edits reload only that plugin
domain; diagnostics and completion come from the same compiler snapshot; a
clean build works from the checked-in bootstrap compiler; and the differential
suite covers every language feature used by the migrated code.

