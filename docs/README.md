# Documentation

Where a document lives says what kind it is:

| Folder | Holds | Rule |
|---|---|---|
| top level | [ARCHITECTURE.md](ARCHITECTURE.md), [DEVELOPMENT.md](DEVELOPMENT.md) | Describe the tree as it is. |
| [reference/](reference/) | How to use something, or a contract the code implements | Kept in step with the code. |
| [design/](design/) | Design notes, proposals and plans | Starts with a `Status:` line. |
| [adr/](adr/) | Architecture decision records | Decisions and their status only. |
| [reports/](reports/) | Dated measurements, experiments and reviews, named `YYYY-MM-topic.md` | Not edited after acceptance. Describes the tree at that date. |
| [history/](history/) | Superseded plans and logs of finished work, named `topic-YYYY-MM.md` | Kept for the reasoning only. |

The project roadmap is [../ROADMAP.md](../ROADMAP.md). The UI package keeps its own documents in
[../packages/ui/docs/](../packages/ui/docs/).

## Reference

Using Haxeon:

- [CLI.md](reference/CLI.md): project CLI, manifests, dependencies, builds.
- [LANGUAGE_SUPPORT.md](reference/LANGUAGE_SUPPORT.md): the supported Haxe subset and what is not yet supported.
- [LIVE_PATCHING.md](reference/LIVE_PATCHING.md): how patching works and the reload rules.
- [WASM_BACKEND.md](reference/WASM_BACKEND.md): the Wasm32 and Wasm GC targets, host ABI and runtime-neutral profile.
- [ANDROID.md](reference/ANDROID.md): the Android host.
- [PROFILING.md](reference/PROFILING.md): profiling workflows.
- [BENCHMARKS.md](reference/BENCHMARKS.md): the edit-to-runtime benchmark.

Language:

- [ITERATION.md](reference/ITERATION.md): iterators and iterable parameters.
- [STRUCTURAL_EQUALITY.md](reference/STRUCTURAL_EQUALITY.md): declared value equality and `Hashable`.
- [KEY_PATHS.md](reference/KEY_PATHS.md): compiler-checked references to stored fields.
- [SCOPED_CLEANUP.md](reference/SCOPED_CLEANUP.md): `scoped` variables.
- [NATIVE_MEMORY.md](reference/NATIVE_MEMORY.md): native values and memory.
- [C_HEADER_FFI.md](reference/C_HEADER_FFI.md): importing C and C++ headers.
- [GENERIC_SPECIALIZATION.md](reference/GENERIC_SPECIALIZATION.md): how generic bodies are shared or specialized.
- [SEMANTIC_TYPE_CONTRACT.md](reference/SEMANTIC_TYPE_CONTRACT.md): nominal types, aliases and implicit conversions.

Libraries:

- [MESSAGEPACK.md](reference/MESSAGEPACK.md): the `haxeon.wire` MessagePack layer and descriptor sidecars.
- [JSON_WIRE.md](reference/JSON_WIRE.md): the generated JSON codec.
- [RPC.md](reference/RPC.md): the typed RPC runtime.
- [UTEST_UPSTREAM_COMPATIBILITY.md](reference/UTEST_UPSTREAM_COMPATIBILITY.md): upstream utest against Haxeon.

Formats and runtime contracts:

- [PATCH_TRANSACTIONS.md](reference/PATCH_TRANSACTIONS.md): the HashLink patch transaction.
- [HLB_DEBUG_SECTIONS.md](reference/HLB_DEBUG_SECTIONS.md): debug sections in HLB modules.
- [HLD3_DEBUG_PROTOCOL.md](reference/HLD3_DEBUG_PROTOCOL.md): the debugger handshake extension for patches.
- [METADATA_OWNERSHIP.md](reference/METADATA_OWNERSHIP.md): who owns runtime metadata across reloads.
- [HASHLINK_MODULE_RECLAMATION.md](reference/HASHLINK_MODULE_RECLAMATION.md): unloading a whole module.
- [JIT_NATIVE_PROPERTIES.md](reference/JIT_NATIVE_PROPERTIES.md): no-return natives and JIT intrinsics.
- [IR_ALLOCATION_REPORT.md](reference/IR_ALLOCATION_REPORT.md): listing what a function can allocate.

## Design

Language:

- [LANGUAGE_ROADMAP.md](design/LANGUAGE_ROADMAP.md): planned language and compiler features.
- [STRUCTS.md](design/STRUCTS.md): structs, inline enums, descriptors (in progress).
- [UI_LANGUAGE_FEATURES.md](design/UI_LANGUAGE_FEATURES.md): features the reactive UI model needs.
- [INLINING_AND_VALUE_TYPES.md](design/INLINING_AND_VALUE_TYPES.md): the inliner and scalar replacement.
- [INTERFACE_VALUES.md](design/INTERFACE_VALUES.md): one interface-value model on every backend.
- [STRUCTURE_VALUES.md](design/STRUCTURE_VALUES.md): open anonymous types, width subtyping, structures as
  the object itself (plan step 2.6).
- [TYPE_VALUES.md](design/TYPE_VALUES.md): classes and enums as runtime values (`Class<T>`, `Enum<T>`), the `Type` API's
  phases 2 and 3.
- [VALUE_CONSTRUCTOR_DESTINATION.md](design/VALUE_CONSTRUCTOR_DESTINATION.md): value constructors that return their value.
- [ERROR_MODEL.md](design/ERROR_MODEL.md): `Result` and error enums for expected failures, exceptions for bugs.
- [PURITY.md](design/PURITY.md), [SCOPED_PLACES.md](design/SCOPED_PLACES.md), [SHADERS.md](design/SHADERS.md): deferred.

Compiler (ADR 0003 and its follow-ups):

- [WARM_REBUILD_REUSE.md](design/WARM_REBUILD_REUSE.md): reusing work across warm builds.
- [IR_PASS_INVENTORY.md](design/IR_PASS_INVENTORY.md): the IR passes and the proposed pass interface.
- [REACHABILITY_WALK.md](design/REACHABILITY_WALK.md): the type-aware reachability walk and prune.
- [ENUM_PASS_PHASE_ORDER.md](design/ENUM_PASS_PHASE_ORDER.md): enum lowering order.
- [DYNAMIC_SITE_BOUNDARIES.md](design/DYNAMIC_SITE_BOUNDARIES.md): typed dynamic sites.
- [PROVIDER_INVENTORY.md](design/PROVIDER_INVENTORY.md): which generated functions serve which operation.
- [HELPER_OWNERSHIP.md](design/HELPER_OWNERSHIP.md): ownership of shared generated helpers.
- [INTERNED_NAMES.md](design/INTERNED_NAMES.md): interned names.
- [FRONTEND_RESTART.md](design/FRONTEND_RESTART.md): removing the frontend restart.
- [LAZY_DECLARATION_TYPING.md](design/LAZY_DECLARATION_TYPING.md): unannotated declaration types typed on demand
  (plan step 2.5).
- [GENERIC_TYPING_ONCE.md](design/GENERIC_TYPING_ONCE.md): typing a generic body once; elaboration per representation
  as a pass (plan step 2.7).

Runtime and tools:

- [WASM_LINEAR_RUNTIME.md](design/WASM_LINEAR_RUNTIME.md): the wasm32 runtime in C.
- [ANDROID_BUILD.md](design/ANDROID_BUILD.md): haxeon compiles the Android module, Gradle packages it.
- [PROFILER_DESIGN.md](design/PROFILER_DESIGN.md): the instrumenting profiler.
- [PROFILER_DESIGN_POSIX.md](design/PROFILER_DESIGN_POSIX.md): native instrumentation on Linux and macOS (proposal).

## Decisions

- [0001](adr/0001-instrumenting-profiler.md): instrumenting profiler.
- [0002](adr/0002-reactive-ui-model.md): reactive UI model.
- [0003](adr/0003-compiler-architecture.md): compiler architecture.
- [0004](adr/0004-runtime-library-and-backends.md): runtime library written once, thin backends (proposed).
- [0005](adr/0005-compilation-units.md): compilation units and the link step (proposed).

## Reports

Reviews and investigations:

- [2026-11-architecture-review.md](reports/2026-11-architecture-review.md), with its
  [evidence](reports/2026-11-architecture-review-evidence.md): the review and the agreed plan. It names documents by
  the paths they had before this folder was split.
- [2026-11-test-suite-cost.md](reports/2026-11-test-suite-cost.md): where test time goes.
- [2026-11-compiler-memory.md](reports/2026-11-compiler-memory.md): compiler worker memory census.
- [2026-11-binary-size.md](reports/2026-11-binary-size.md),
  [2026-11-bytecode-opportunities.md](reports/2026-11-bytecode-opportunities.md): UI and editor module size (unfinished).
- [2026-11-hashlink-driver-exit.md](reports/2026-11-hashlink-driver-exit.md): the test-driver crash at exit.

Runtime performance, October 2026. "Accepted" changes are in the tree; the others record why an idea was dropped:

| Report | Outcome |
|---|---|
| [gc-empty-page-retention](reports/2026-10-gc-empty-page-retention.md) | Accepted |
| [fasta-output-profile](reports/2026-10-fasta-output-profile.md) | Accepted (short-ASCII decoder) |
| [jit-register-allocation](reports/2026-10-jit-register-allocation.md), [phase0](reports/2026-10-jit-register-allocation-phase0.md), [results](reports/2026-10-jit-register-allocation-results.md) | Accepted, on by default on SysV x86-64 |
| [bump-allocation-plan](reports/2026-10-bump-allocation-plan.md), [profile](reports/2026-10-bump-allocation-profile.md), [jit-inline-allocation](reports/2026-10-jit-inline-allocation.md) | Stage 1 accepted, opt-in |
| [jit-allocation-initialization](reports/2026-10-jit-allocation-initialization.md) | Dropped (stage 2) |
| [jit-boxed-allocation](reports/2026-10-jit-boxed-allocation.md), [layout](reports/2026-10-jit-boxed-allocation-layout.md), [allocation-census](reports/2026-10-allocation-census.md) | Stage 3: see the reports |
| [compiler-gc-marking](reports/2026-10-compiler-gc-marking.md) | Opt-in candidate |
| [gc-profile](reports/2026-10-gc-profile.md), [gc-allocation-profile](reports/2026-10-gc-allocation-profile.md), [object-allocation-profile](reports/2026-10-object-allocation-profile.md), [array-allocation-profile](reports/2026-10-array-allocation-profile.md) | Profiles; no change accepted |
| [fasta-profile](reports/2026-10-fasta-profile.md), [bytes-access-profile](reports/2026-10-bytes-access-profile.md), [bounds-check-elimination](reports/2026-10-bounds-check-elimination.md) | Rejected |
| [optimization-next-results](reports/2026-10-optimization-next-results.md), [ir-opportunity-census](reports/2026-10-ir-opportunity-census.md) | Summary of that optimization round |

## History

- [provider-requests-2026-11.md](history/provider-requests-2026-11.md): helper requests as records, superseded by typed operations.
- [typer-metadata-merge-2026-11.md](history/typer-metadata-merge-2026-11.md): the typed metadata merge, landed 2026-11-08.
- [ir-pass-inventory-2026-11.md](history/ir-pass-inventory-2026-11.md): gate history of the IR pass work.
- [structs-measurements-2026-11.md](history/structs-measurements-2026-11.md): struct measurement history.
- [ui-value-types-2026-11.md](history/ui-value-types-2026-11.md): UI value-type checkpoint history.
