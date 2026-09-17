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
- [x] Typed locals, nominal classes, fields, constructors, inheritance, and
	instance field initializers injected into explicit or implicit constructors;
	constructor availability changes invalidate `new` callers incrementally.
- [x] Static fields and unqualified static access lower to persistent HashLink
	globals; literal and expression initializers run through a stable `__init`
	entry at normal startup and live-module load, while compatible body patches
	preserve global state.
- [x] SSA construction, verification, phi elimination, deterministic lowering.
- [x] Function values for non-capturing references.
- [x] Capturing closures and instance closures, including shared generated
  capture cells for mutable locals.
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
	arrays whose backing storage grows without changing array identity; local,
	mutable-field, and alias mutation are covered, while broader key/value
	collections remain future work. `for (key in map)` now snapshots typed map
	keys through the same bounds-checked array loop lowering.
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
	exercised end-to-end; typed `throw` and catch-all `try`/`catch` now lower
	through HashLink's dynamic exception ABI. Locals mutated across a handler
	boundary use selective stable cells rather than blanket register spills, and
	HashLink validates branch and trap targets before JIT compilation. Typed catch filters, file
	handles, generic collections, and richer IO remain future work).

### B. Incremental compiler service

- [x] Persistent module state and dependency graph.
- [x] Separate signature/body fingerprints and selective regeneration.
- [x] Stable function IDs, tombstones, compaction, and identity persistence.
- [x] Typed function-value dependency invalidation.
- [~] Package-qualified module paths and imported function/module aliases plus
	imported class names/type annotations resolve incrementally; explicit function
	aliases retain their owning module identity; nominal class,
	interface, enum, and alias identities now retain their package-qualified names.
	Wildcard package imports now resolve direct source modules, secondary
	declarations, enum constructors, top-level functions, and explicit-import
	precedence; conflicting wildcard or explicit imports remain unresolved instead
	of using last-write-wins; deeper namespace and broader alias semantics remain.
- [~] Unsaved edits can be validated transactionally against a forked compiler
  snapshot without mutating the live source, including through the JSON-lines
  protocol; cooperative request cancellation now unwinds compiler phase
  boundaries, while shared snapshots and one-pass commit/rollback remain.
- [ ] Parallel parse/type work with deterministic assembly on the editor thread.
- [ ] Memory and latency budgets measured on a realistic Pragtical project.

### C. Runtime and hot reload

- [x] Forked HashLink submodule and reproducible local tool bootstrap.
- [x] HLP framing, strict validation, stable-target relocations, and atomic
  compatible function patching.
- [x] Revision checks, stale-patch rejection, call synchronization, and JIT
	allocation reclamation.
- [x] Functions containing `OTrap`, `OThrow`, and handler control flow patch in
  place and execute their replacement handlers without restarting the module.
- [x] A representative multi-module plugin now loads through the native runtime,
	patches compatible closure/method bodies in place, and replaces the live module
	on structural edits (`tests/hxml/plugin-test.hxml`).
- [x] Non-moving type arena for compatible primitive, abstract, and function
  type-table growth, with transactional publication and domain-owned cleanup.
- [~] Structural class layout/base changes are classified as full-reload
	generations and rebuild HashLink type metadata; compatible appended metadata
	retains stable addresses within the live domain arena.
- [x] Loaded modules expose typed lifecycle calls by stable function ID, and
	`LoadedPlugin` exercises activation, deactivation, state save/restore, staged
	disposal, and recovery through `RuntimeDomain`.
- [x] In-memory module loading and patching without temporary `.hl` files.
- [~] Native runtime call/patch failures return typed status codes and preserve
	last-good domain ownership; crash-safe diagnostics and automatic recovery for
	all native faults remain.

### D. Language service

- [~] `LanguageService` now selects one compiler-owned editor snapshot in the
  order current-valid, current-recovered, then last-known-good. Edits publish
  a recovered AST, tokens, and editor-only semantic model immediately; the
  recovered model never becomes authoritative workspace state.
- [~] Analysis and build transactions now detach module state at their snapshot
  boundary, retain published object identity for untouched modules, and reject
  candidates whose source/configuration generation was superseded. This keeps
  source, semantic artifacts, diagnostics, and revisions coherent while work is
  in flight. Rejecting a pending runtime publication also preserves newer
  source edits while restoring the acknowledged compiler/runtime baseline;
  immutable publication before parallel analysis remains future work.
- [~] Semantic index construction now has a dedicated `SemanticIndexBuilder`,
  shared exhaustive typed-AST traversal, and an immutable query-state snapshot
  detached from the construction workspace. Token-only completion-context
  classification now lives in a separate semantic query helper; published
  completion facts, nested receiver types, direct recovered function
  signatures, callable signatures, and receiver-aware/inherited signature
  variants are materialized into the recovery query boundary, and call edges
  are finalized before publication. Remaining work is richer error-tolerant
  recovery resolution and broader immutable semantic-query state, not
  request-time access to the construction builder.
- [~] Recovery construction is isolated in `RecoveryEngine`; workspace name
  resolution, dependency visibility, and recovered-body reuse remain explicit
  callbacks so editor snapshots cannot publish speculative declarations.
- [~] Interactive parser recovery retains incomplete declarations, parameter
	and type lists, member access, calls, blocks, and control-flow constructs.
	Recovery diagnostics are merged and deduplicated with compiler diagnostics,
	and lexical, parser, partial-typing, indexing, and LSP work honor cooperative
	cancellation. The interactive corpus covers real edit sequences and UTF-16
	positions in recovered source.
- [~] Recovered typing propagates `TUnknown`/`TError` locally, preserves
  scopes and local types around unrelated failures, records expected argument
  types, retains nominal receivers with unknown generic arguments, and exposes
  unresolved names and compiler-owned completion contexts. Full error-tolerant
  type resolution remains.
- [~] Completion, symbols, folding, selection ranges, links, highlights,
  semantic tokens, hover, and signature help consume current recovered source
  where safe. Completion reports incomplete results while recovery is active.
- [~] Definition and references require a bound compiler identity; rename and
  stale fallback edits remain conservative and reject speculative or stale
  symbols. Implementation lookup now reads current recovered candidate classes
  only for authoritative targets, and ambiguous recovered inheritance names are
  rejected. Full type-aware navigation and global reference precision remain.
- [x] A small JSON-lines protocol adapter for Pragtical; it exposes diagnostics,
  semantic queries, transactional validation, and base64 HLB/HLP payloads with
  runtime identity, plus a caller-owned cancellation token and `cancel` method.
  There is no second typechecker.
- [~] `benchmarks/editor-benchmark.hxml` measures edit-to-recovery,
  completion, signature-help, hover, definition, background-analysis latency,
  recovered-snapshot publication, and process-memory growth under rapid
  incomplete edits, including multi-module malformed-source scenarios. Its
  opt-in `--check-budgets` gate defines representative budgets: 100 ms p95 for
  small-workspace editor recovery and interactive queries, 500 ms p95 for
  background analysis and scaled 64-module recovery/queries, 32 MiB maximum
  small-workspace RSS growth, and 128 MiB maximum RSS growth across 250 edits
  on one long-lived 64-module service. It also exercises the complete
  `tests/fixtures/pragtical` source tree through package-qualified imports,
  cross-module definition, a malformed plugin edit, and a repaired plugin
  transition. Use
  `--project-iterations`, `--scale-modules`, and `--endurance-edits` to
  reproduce or enlarge the workload; broader production-workspace validation
  remains.
- [x] Representative multi-module plugin workload with an editor facade,
	interface lifecycle, arrays/maps, callbacks, incremental body patching, and
	class-layout reload classification (`tests/hxml/plugin-test.hxml`).

### E. Self-hosting and release engineering

- [x] Keep compiler sources inside the implemented subset; the bootstrap
  dashboard lexes, parses, and compiles all 82 compiler source files.
- [x] Bootstrap compiler A with official Haxe.
- [x] Build compiler B using A; the resulting HLB is byte-for-byte identical.
- [x] Check in a reproducible `bootstrap/compiler.hl`; `bootstrap-compiler.sh
  --self` rebuilds it identically without invoking official Haxe.
- [x] Build/test in CI from the pinned HashLink fork and formatter version,
  including an exact self-hosted compiler rebuild.
- [~] Differential suite: four paired programs currently compare official HL
	and realtime HL behavior in the normal gate; broader collections, diagnostics,
	and reload-classification coverage remain.

## Feature order after the current milestone


1. Extend the first-class `Array<T>` and map runtime types with broader key/value
	operations and iterator compatibility; keep bounds checks in the HashLink
	operation contract.
2. Complete package/import resolution for nominal types, then migrate the
	fixture into a real Pragtical utility plugin.
3. Strengthen the compiler-owned editor snapshots, then finish semantic
	definition/references/rename on top of conservative identity checks.
4. Add structural reload domains and state migration, then move larger editor
	subsystems and finally the editor core.

## Definition of Pragtical-ready

The compiler is ready for a staged Pragtical conversion when a representative
plugin can be edited and saved while the editor keeps running; compatible
function edits patch in place; class-layout edits reload only that plugin
domain; diagnostics and completion come from the same compiler snapshot; a
clean build works from the checked-in bootstrap compiler; and the differential
suite covers every language feature used by the migrated code.

## Language-service production readiness

The semantic/editor subsystem is ready for production use when ordinary
incomplete source rarely breaks queries; completion is type-aware during
malformed edits; structural features track the current recovered source;
navigation is reliable only for authoritative identities; rename never edits
from speculative or stale identity; rapid edits remain responsive under
cancellation; realistic edit-sequence tests stay green; and large-workspace
latency and memory budgets are measured and met.

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
	together. Typed `throw` and catch-all `try`/`catch` are the first exception
	ABI milestones; finish typed filters and uncaught-exception diagnostics
	before migration.
- Keep exceptional state explicit at the typed-local boundary: values mutated
  in a protected region and observed by its handler use stable cells, while SSA
  remains responsible for ordinary control-flow merging.
- Finish the non-moving type arena and explicit reload domains in the fork.
- Add in-memory module load/patch APIs, failure recovery, and state migration
  hooks; preserve ordinary `.hl` compatibility for non-realtime builds.
- Make structural changes report a domain boundary before any native staging,
  so a failed patch cannot disturb the running editor.

### 3. Persistent compiler and language service

- Keep current-valid, current-recovered, and last-good editor snapshots
  separate, with recovery artifacts isolated from authoritative workspace
  declarations.
- Improve error-tolerant/incremental typing, expected-type propagation, and
  stable symbol resolution before relaxing conservative navigation policies.
- Measure edit-to-recovery, edit-to-completion, hover, navigation, background
  analysis, memory, and snapshot churn on representative workspaces.
- Add dependency-aware parallel work only after deterministic recovery and
  invalidation budgets are met; keep the protocol adapter thinner than the
  compiler service.

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
- Keep the exact compiler A/compiler B HLB comparison and broaden diagnostic
  and differential comparisons as the supported language surface grows.
- Use the checked-in bootstrap compiler for normal development; retain official
  Haxe as the reproducible bootstrap and differential oracle.

### 7. Production conversion

- Convert the remaining Pragtical services and editor core in dependency order,
  retaining a fallback build while each domain is validated.
- Freeze the runtime/compiler protocol versions, document extension points, and
  publish compatibility and rollback procedures.
- Treat optimization (SSA quality, JIT tuning, parallelism) as a measured
  follow-up after correctness, reload safety, and editor UX are stable.
