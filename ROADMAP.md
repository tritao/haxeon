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
- [x] Capturing closures and instance closures (read-only captures; mutable
  capture cells remain future work).
- [~] `Array<Int>` typing, indexed reads/writes, `.length`, and compiler-owned
	`Int`/`Float`/`String` allocation lower directly to HashLink array
	operations and the runtime ABI. Object arrays, maps, enums, nullable values,
	and pattern matching remain future work. Our HashLink fork enforces bounds in
	the JIT.
- [~] Prototype-dispatched instance calls and inheritance are live, including
  stable override slots and arbitrary fixed-arity calls; interface declarations
  and implementation contracts are typed, while interface ABI values and basic
  generics remain.
- [ ] A documented runtime library ABI for strings, collections, IO, and time
  (typed `trace` and a native-backed `IntArray` ABI probe are exercised
  end-to-end; the public generic collection ABI remains future work).

### B. Incremental compiler service

- [x] Persistent module state and dependency graph.
- [x] Separate signature/body fingerprints and selective regeneration.
- [x] Stable function IDs, tombstones, compaction, and identity persistence.
- [x] Typed function-value dependency invalidation.
- [~] Package-qualified module paths and imported function/module aliases plus
	imported class names/type annotations resolve incrementally; deeper nominal
	namespace identity remains.
- [~] Unsaved edits can be validated transactionally against a forked compiler
  snapshot without mutating the live source; shared snapshots and one-pass
  commit/rollback remain.
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

- [~] Persistent AST snapshots, diagnostics, document symbols, completion,
  hover, definition, references, and rename are exposed through
  `LanguageService`; token/type snapshots and semantic disambiguation remain.
- [ ] Definition, references, rename, and full type-aware completion from
  compiler state.
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

1. Extend the first-class `Array<T>` runtime type from the current
	`Int`/`Float`/`String` allocation slice to object arrays and compiler-owned
	collection operations; keep bounds checks in the HashLink operation contract.
2. Add enums/nullable values and pattern matching on the same tagged-value
   rules used by the runtime bridge.
3. Add interface declarations and interface-typed values on the same
   prototype-slot ABI; direct calls remain an optimization, never the
   semantic contract.
4. Complete package/import resolution for nominal types, then migrate a small
   Pragtical utility plugin as the first real multi-module workload.
5. Expose compiler snapshots as the editor language service.
6. Add structural reload domains and state migration, then move larger editor
   subsystems and finally the editor core.

## Definition of Pragtical-ready

The compiler is ready for a staged Pragtical conversion when a representative
plugin can be edited and saved while the editor keeps running; compatible
function edits patch in place; class-layout edits reload only that plugin
domain; diagnostics and completion come from the same compiler snapshot; a
clean build works from the checked-in bootstrap compiler; and the differential
suite covers every language feature used by the migrated code.

## Long-term delivery sequence

This is the order in which the project should spend complexity budget. Each
stage has a usable exit condition; later stages must not silently become a
second compiler or a second runtime.

### 0. Contract and instrumentation

- Keep the supported syntax/type/runtime subset explicit and reject everything
  else with source diagnostics.
- Pin Haxe Formatter, the reference Haxe toolchain, and the HashLink fork.
- Keep HLB/HLP readers, writers, and the native fork under differential tests.
- Add latency, allocation, patch-size, and JIT-reclamation measurements to the
  normal test run before optimizing.

### 1. Language kernel

- Finish nominal interfaces, nullable values, enums, pattern matching, and
  compiler-owned array/map operations.
- Add type aliases and the small generic forms needed by editor APIs; defer
  macros, abstracts, build-time metaprogramming, and cross-target semantics.
- Make diagnostics and source spans stable enough for editor edits while a
  file is incomplete.
- Keep every new feature represented as typed AST -> SSA IR -> HL lowering;
  no feature-specific AST-to-native shortcuts.

### 2. Runtime/ABI hardening

- Define the supported runtime ABI for strings, arrays, maps, IO, time, and
  exceptions, with Haxe declarations and native implementations versioned
  together.
- Finish the non-moving type arena and explicit reload domains in the fork.
- Add in-memory module load/patch APIs, failure recovery, and state migration
  hooks; preserve ordinary `.hl` compatibility for non-realtime builds.
- Make structural changes report a domain boundary before any native staging,
  so a failed patch cannot disturb the running editor.

### 3. Persistent compiler and language service

- Turn edits into transactions: parse/type/codegen failures retain the last
  good snapshot and return diagnostics without mutating live compiler state.
- Add dependency-aware parallel work with deterministic assembly on the editor
  thread, plus measured budgets for a representative Pragtical workspace.
- Complete definition, references, rename, semantic completion, hover, and
  document symbols from one compiler snapshot.
- Add a small protocol adapter for Pragtical and keep it deliberately thinner
  than the compiler service.

### 4. Plugin-first migration

- Select one small, representative Pragtical plugin and make it compile with
  the supported subset and runtime ABI.
- Run it in a reload domain with activate/deactivate and optional state
  save/restore; exercise body edits, signature edits, and class-layout edits.
- Migrate utility modules and shared editor services incrementally, maintaining
  an official-Haxe differential build until each feature is covered.
- Keep the editor process authoritative: a bad edit must leave the previous
  plugin generation running and diagnostics visible.

### 5. Editor integration

- Embed the persistent compiler service in a Pragtical-like host, wire save
  events to transactional compile/patch, and expose diagnostics/completion.
- [x] Compile and execute integer REPL expressions against a forked compiler
  snapshot; editor-scope values and richer result types remain.
- Measure end-to-end save latency, memory growth, patch churn, and recovery
  behavior under realistic multi-module edits.
- Expand domains from plugins to selected editor subsystems only after the
  plugin workflow is boring and repeatable.

### 6. Bootstrap and self-hosting

- Constrain compiler sources to the implemented subset and track unsupported
  syntax in the bootstrap dashboard.
- Build compiler A with official Haxe, then compiler B with A; compare HLB,
  diagnostics, and differential behavior rather than requiring byte identity.
- Check in a reproducible bootstrap compiler and make official Haxe optional
  for normal development and release builds.

### 7. Production conversion

- Convert the remaining Pragtical services and editor core in dependency order,
  retaining a fallback build while each domain is validated.
- Freeze the runtime/compiler protocol versions, document extension points, and
  publish compatibility and rollback procedures.
- Treat optimization (SSA quality, JIT tuning, parallelism) as a measured
  follow-up after correctness, reload safety, and editor UX are stable.
