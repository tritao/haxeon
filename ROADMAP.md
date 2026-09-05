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

- [x] Integer/float/string/bool expressions and literals, arithmetic (including
  modulo and unary negation), branches, loops,
  recursion.
- [x] Typed locals, nominal classes, fields, constructors, inheritance.
- [x] SSA construction, verification, phi elimination, deterministic lowering.
- [x] Function values for non-capturing references.
- [x] Capturing closures and instance closures (read-only captures; writes to
  captured locals are rejected until mutable capture cells are implemented).
- [~] `Array<T>` typing, indexed reads/writes, `.length`, and compiler-owned
	`Int`/`Float`/`Bool`/`String` plus reference-array allocation lower directly
	to HashLink array operations and the runtime ABI; `for (item in array)` is
	lowered to a bounds-checked SSA loop with `break`/`continue` control edges.
	Immutable `copy`, `concat`, `slice`, and primitive/String `indexOf` are
	now ABI-backed and tested. ABI-backed primitive/string maps and reference-valued
	`Map<String,T>`/`Map<Int,T>` specializations support construction,
	indexed set/get, `set`, `exists`, key-array iteration, `remove`, and `clear`;
	reference-valued maps for classes, interfaces, arrays, and function values
	use the same dynamic pointer representation;
	immutable array operations cover primitive, string, and reference arrays;
	primitive/String/reference `push` and `pop` now use capacity-aware HashLink
	arrays; `push` rebinds local array variables, while field/alias mutation and
	broader key/value collections remain future work.
	Our HashLink fork
	enforces bounds in the JIT.
- [~] Explicit `Null<T>` values for reference types lower to HashLink's native
	 null representation, support equality, and reject implicit untyped null
	 locals; null-guard narrowing now flows through `&&`, `||`, and `!=`, while migration-safe
	 object arrays remain future work.
- [~] Enums lower to HashLink tagged values, including payload constructors,
  payload extraction, equality by constructor tag, typed enum/int `switch`
  cases, duplicate-case diagnostics, and exhaustive enum return-path analysis;
  richer pattern forms remain future work.
- [~] Primitive and array type aliases resolve in the frontend; cross-module
	alias identity and generic aliases remain future work.
- [~] Prototype-dispatched instance calls and inheritance are live, including
  stable override slots and arbitrary fixed-arity calls. Basic HashLink virtual
	interface values now lower through `OToVirtual`, support inherited interface
	slots, and dispatch through `OCallMethod`; generic interfaces and advanced
	variance remain future work.

- [~] A documented runtime library ABI for strings, collections, IO, and time
	(compiler-owned string concatenation, length, equality, search, slicing, and
	typed `trace` plus the standard `Sys` time/filesystem/process surface are
	exercised end-to-end; file handles, generic collections, and richer IO remain
	future work).

### B. Incremental compiler service

- [x] Persistent module state and dependency graph.
- [x] Separate signature/body fingerprints and selective regeneration.
- [x] Stable function IDs, tombstones, compaction, and identity persistence.
- [x] Typed function-value dependency invalidation.
- [~] Package-qualified module paths and imported function/module aliases plus
	imported class names/type annotations resolve incrementally; deeper nominal
	namespace identity remains.
- [~] Unsaved edits can be validated transactionally against a forked compiler
  snapshot without mutating the live source, including through the JSON-lines
  protocol; shared snapshots and one-pass commit/rollback remain.
- [ ] Parallel parse/type work with deterministic assembly on the editor thread.
- [ ] Memory and latency budgets measured on a realistic Pragtical project.

### C. Runtime and hot reload

- [x] Forked HashLink submodule and reproducible local tool bootstrap.
- [x] HLP framing, strict validation, stable-target relocations, and atomic
  compatible function patching.
- [x] Revision checks, stale-patch rejection, call synchronization, and JIT
  allocation reclamation.
- [ ] Non-moving type arena for compatible type-table growth.
- [~] Structural class layout/base changes are classified as full-reload
	generations and rebuild HashLink type metadata; explicit per-plugin domains
	remain.
- [~] Plugin lifecycle/state migration and staged native-module ownership are
	tested in the host `RuntimeDomain`; native type-arena integration remains.
- [x] In-memory module loading and patching without temporary `.hl` files.
- [ ] Crash-safe diagnostics and recovery when a patch fails in native code.

### D. Language service

- [~] Persistent AST snapshots, diagnostics, document symbols, completion,
  hover, definition, references, and rename are exposed through
  `LanguageService`; typed local member completion now covers classes,
  interfaces, arrays, maps, and strings, and semantic symbol identity now
  follows local bindings, class/interface members, and imported module
  functions. Full semantic resolution remains.
- [~] Definition, references, and rename now use compiler symbol identity for
  locals, members, and imported functions; full type-aware navigation remains.
- [~] Completion-safe partial parsing and error recovery through last-good
  snapshots; true partial parsing remains.
- [x] A small JSON-lines protocol adapter for Pragtical; it exposes diagnostics,
  semantic queries, transactional validation, and base64 HLB/HLP payloads with
  runtime identity. There is no second typechecker.

### E. Self-hosting and release engineering

- [ ] Keep compiler sources inside the implemented subset.
- [ ] Bootstrap compiler A with official Haxe.
- [ ] Build compiler B using A and compare behavior against A.
- [ ] Check in a reproducible `bootstrap/compiler.hl`.
- [ ] Build/test in CI from the pinned HashLink fork and formatter version.
- [~] Differential suite: four paired programs currently compare official HL
	and realtime HL behavior in the normal gate; broader collections, diagnostics,
	and reload-classification coverage remain.

## Feature order after the current milestone


1. Extend the first-class `Array<T>` and map runtime types with broader key/value
	operations and iterator compatibility; keep bounds checks in the HashLink
	operation contract.
2. Complete package/import resolution for nominal types, then migrate a small
	Pragtical utility plugin as the first real multi-module workload.
3. Expose compiler snapshots through a thin editor protocol adapter and finish
	semantic definition/references/rename.
4. Add structural reload domains and state migration, then move larger editor
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
- Add latency, module-size, patch-size, and JIT-reclamation measurements to the
	normal test run before optimizing; compile latency and patch metrics are now
	exposed in `CompileResult` and the editor protocol.

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
