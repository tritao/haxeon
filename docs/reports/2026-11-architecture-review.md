# Haxeon architecture review (2026-11-16)

Status: review report with an agreed plan. Nothing here has been implemented. It is a dated snapshot, not a contract; the code is the
source of truth.

## How this was produced

Twelve read-only reviewers each studied one scope (eleven subsystems plus one cross-cutting pass over the import graph,
file sizes, churn, duplication, dead code and global state) and reported findings with file and line evidence. The
review started at commit `23800dca`; twelve commits landed on `main` while it ran, up to `c6cfd889`, so some line
numbers have shifted and one finding was fixed in the meantime (marked below).

Findings were ranked against the roadmap: Haxe-semantics parity, incremental compile and hot reload, compile speed, and
self-hosting.

What was checked afterwards: twelve of the high-severity claims were re-checked by hand against `c6cfd889` (listed in
[Verification](#verification)). Eleven held and one was already fixed. Every other finding is a reviewer's claim with
its own evidence, not independently confirmed. The full evidence, cost statements and the "leave alone" lists are in
[ARCHITECTURE_REVIEW_EVIDENCE.md](2026-11-architecture-review-evidence.md).

Each finding carries a kind (architecture, organization, overengineering), a severity, an effort (S, M, L) and the risk
of making the change.

## Overall judgment

The core design is sound. The data models are small (`Ir.hx` is 394 lines), the transaction and candidate machinery
that makes failed builds roll back is coherent, static mutable state is light (about 30 static variables), exact
duplicate code is small (23 groups, about 405 lines) and dead code is almost nil. The import graph mostly follows the
intended order by volume.

The debt is in four places:

1. **The build pipeline and session are HashLink-shaped.** Wasm runs after a HashLink assembly whose output it does not
   use, and the `Backend` interface is not on the production HashLink path.
2. **Nothing owns the IR pass order.** It is spread over six files in three packages, with target branches and
   correctness rescans.
3. **The typer has two structural limits.** Local inference has no unification variables, and all body typing writes
   into one shared session of about 55 mutable maps, which is what blocks parallel typing.
4. **Everything around the code is less disciplined than the code.** Tests that nothing runs, three different gate
   sets, duplicated launchers and scripts, and a flat `docs/` folder whose status lines contradict the code.

Churn confirms where it hurts: `src/compiler/ir` is touched by 133 of the last 500 commits, and the two files that
share the pass pipeline (`FrontendCompilation.hx`, `IrProgramAssembler.hx`) are the top two churn files in `src/` and
the top co-change pair.

## Main architectural issues and the target design

### 1. Make the backend a real session-level seam

- **Now:** `BackendAssembly.hx` keeps a HashLink assembly "even when the requested artifact is Wasm": it copies the IR,
  runs two extra rewrites, lowers and encodes HashLink bytes, and then `CompilerDriver` runs `WasmBackend` on the IR.
  `isWasmTarget()` is consulted at 21 sites. `HlBackend` (25 lines) has no reference in `src/`. Session fields and
  `CompileResult.module` are HashLink-typed. Shared Wasm lowering downcasts to the GC and linear representations 22
  times.
- **Target:** parse the target once into `BackendTarget` and carry it on `Compiler`. Put a session backend interface
  behind the compiler with two operations: prepare target IR, and assemble (IR plus changes to artifact plus ABI).
  HashLink and Wasm each implement it and own their caches; `CompileResult` carries a backend artifact. Wasm builds
  skip `HlModuleAssembler`, and Wasm gains the same candidate and rollback semantics as HashLink. Promote the 22
  downcasts to interface members.
- **Effort L, risk medium to high.** First confirm what the Wasm path still reads from the HashLink result.

### 2. One owner for the IR pass pipeline

- **Now:** `IrProgramAssembler.assemble` (about 590 lines, 16 parameters) runs about 20 passes inline;
  `FrontendCompilation.run` (about 850 lines) runs ten more behind `isWasmTarget()` branches; further calls sit in
  `BackendAssembly` and three Wasm builders. `IrEnumTagLowering.escapes` is called at five sites. Pass signatures
  differ.
- **Target:** one `compiler.ir.pipeline.IrPipeline` holding an ordered list of named stages per target (HashLink plain,
  HashLink live, Wasm32, Wasm GC). Each stage is `(IrProgram, PassContext) -> IrProgram`; the context carries profile,
  facts, tables, metering and check hooks. Land it first as a pure move. `IrProgramAssembler` keeps only typed-to-IR
  declaration building, and `FrontendCompilation.run` is cut into phase functions over a per-build record.
- This is the "framework commit" that `docs/IR_PASS_INVENTORY.md` already proposes; it is the precondition for
  per-pass caching on warm builds.
- **Effort L, risk medium.**

### 3. One session-state object

- **Now:** build-owned session state is enumerated by hand in five places (fields, create candidate, adopt, snapshot,
  and the 50-method `CompilationContext` forwarding facade). A missed copy is a rollback bug. `validate()` uses a
  second, cold fork path.
- **Target:** one `SessionState` class with `copyForCandidate()`; `Compiler` holds one reference, so adopt and restore
  are one assignment and the snapshot is that object. The pipeline takes `SessionState` directly and the forwarders
  go. `validate()` becomes "create candidate, then run". Extract the FFI registry (nine maps, about 180 lines) from
  `Compiler.hx` into `compiler.ffi.FfiRegistry`.
- This is also the roadmap's "shared snapshots and one-pass commit/rollback".
- **Effort M, risk medium.**

### 4. Move structural invalidation into the compiler

- **Now:** `CompilerSession.hasStructuralDeclaration` pre-scans edits and resets the whole session when a typedef,
  enum or abstract changes shape. It is a correctness workaround that lives outside the compiler.
- **Target:** finish shape invalidation with the alias, enum and abstract fingerprints `ModuleState` already holds,
  delete the pre-scan, and add a warm-edit test that changes a typedef's shape and compares against a cold build.
- **Effort M, risk medium.**

### 5. Typer: inference variables, error recovery, per-unit output

- **Inference.** Local inference is syntactic look-ahead plus speculative re-typing. Add an inference variable to
  `CompilerType` (a `TMono`), bind it in assignability and coercion, and add a post-body pass that defaults or rejects
  unbound ones. Migrate one case at a time, starting with the empty array literal, and delete the matching look-ahead
  walker each time. This is Haxe's own model, so it also serves semantics parity. Effort L, risk high.
- **Error recovery.** Typing aborts on the first error and the language service compensates with a second, approximate
  typer. Make the typer record the diagnostic, produce an error-typed node and continue; then delete the approximate
  typer. Effort L, risk medium.
- **Shared session.** `TypingSession` has about 55 public mutable maps, a body-context stack and order-dependent
  counters, written from 19 files. Split it into an immutable program view and a per-unit output record that
  `ProgramTyper` merges in sorted order. That gives deterministic helper names now and makes per-unit typing a pure
  function when parallelism is wanted. Scheduled as step 2.2. Effort L, risk high.
- **Callback wiring.** The body typer is five classes wired by 42 callback typedefs and about 62 forwarding closures,
  each with one implementation. Replace them with one narrow interface (or a package-private `BodyTyper` reference).
  Keep the file split. Effort M, risk medium.
- **A likely bug, fix now.** Hand-written `AstFunction` copies omit `isInline`, `isExtern` and `metadata` at four of
  nine sites (for example `SignatureInference.withResult`). One copy helper in `compiler.syntax` fixes all nine.
  Effort S, risk low.

### 6. One compiler service, one project-to-inputs translation

- **Now:** three persistent-compiler front doors (compiler server, LSP, editor service) each own a compiler instance
  and a wire format. LSP and build translate `haxeon.json` into compiler inputs independently, and the LSP version is
  incomplete. `HaxeonCli` has a third, legacy parser for wasm32 and Android with different manifest rules.
- **Target:** one `project.CompilerInputs.of(project, layout)` consumed by build, LSP and CLI; delete
  `HaxeonCli.loadConfig` and route wasm32 and Android through the structured build. Then one per-project service
  process owns the `Compiler`, and `LspProtocol` and `LanguageServiceProtocol` become thin adapters with one typed
  request and response definition.
- **Effort M for the inputs function, L and high risk for the single service.**

### 7. Layering: a leaf package and one home for HashLink

- **Now:** 18 mutually dependent package pairs. Most come from small leaf utilities living in high-level packages
  (`CancellationToken` in `service`, `AllocationMeter` and `IrPassMeter` in `compilation`, `LambdaName` in
  `semantic`), and from HashLink code spread over `compiler/hl`, `compiler/ir/hl` and `compiler/backend/hl`. The
  target-neutral `ir` package names the Wasm backend directly.
- **Target:** a `compiler/core` package for `Source`, `Diagnostic`, `QualifiedName`, `Provides`, `CancellationToken`
  and the meters. Move `compiler/ir/hl` under the HashLink backend so the dependency is one-way. Move the AST-only
  analyses out of `types/analysis`. Write the allowed dependency order in `ARCHITECTURE.md`. These are pure moves.
- **Effort M, risk low.**

### 8. Name runtime intrinsics and FFI descriptor codes once

- **Now:** runtime intrinsics are string literals repeated across the registry, the typer ABI and three backends;
  `WasmGcRepresentation.lowerRuntimeCall` is about 1,500 lines of sequential name comparisons, and a typo is a silent
  fallthrough. FFI native-call descriptor codes 0 to 15 are unnamed integer literals shared by convention between the
  emitter, `WasmCAbi` and `HlLower`.
- **Target:** one table of intrinsic records (id, symbol, aliases, signature, purity) resolved to an id once; backends
  switch on the id with exhaustiveness checking. One enum abstract plus one encoder and decoder for descriptor codes.
- **Effort M, risk medium.**

### 9. Runtime and platform boundaries

- **Core runtime depends on NativeKit.** `native/runtime/native_trace.c` includes `nativekit_trace.h` and
  `CMakeLists.txt:73` adds `vendor/nativekit/include` to `haxeon_runtime`. Move the trace unit to the NativeKit side.
  Effort S.
- **Android host re-lists HashLink sources by hand.** Have the fork's CMake export static embed targets, link those,
  and add a link-only NDK job to CI. Effort M.
- **Wasm runtime library is hand-emitted twice,** once per reference model. Write the representation-independent part
  (string operations, Int64 and number formatting, enum strings) once as Haxe stdlib code compiled through the normal
  pipeline. Effort L, risk high.
- **`stdlib/` holds frameworks and tooling next to Haxe std.** Keep `stdlib/` to Haxe's surface and move Haxeon-only
  libraries to a `haxeon.*` root.
- **Fixed during the review:** the finding that `sys.io.Process` and the file streams did not have Haxe's API was
  addressed by `028ce4fa`. `scripts/check-self-hosting.sh` still lists those gaps and should be re-checked.

## Where organization should improve

- **Large functions in the highest-churn files.** `IrGenerator.lowerExpressionAt` (about 1,400 lines),
  `WasmFunctionLower.lowerInstruction` (about 1,470), `HxiHaxeEmitter.sourceRaw` (860), `SemanticAssembly.run` (about
  800), `HlLower.lowerFunction` (about 640). Extract one family per method and keep the dispatching switch. No
  behaviour change; do it file by file when a feature touches them.
- **`src/compiler/ir` is one flat directory of over 100 files** distinguished only by name prefix. Group by family.
- **Entry points.** Sixteen mains in four locations. `src/Main.hx` is the test-program driver, not the product entry.
  Group tools by product and expose the FFI tools as `haxeon ffi import|audit`.
- **Names that collide.** `src/runtime` and `src/compiler/runtime`; `src/tools` and `src/compiler/tools`; `src/editor`
  and `packages/editor`.
- **The offline Clang importer (4.9k lines) sits in `compiler/ffi`,** so every FFI import action fingerprints all of
  `src/` and any compiler edit re-runs every header import. Move it to its own package and run it as a prebuilt tool
  artifact.
- **Tests and CI.**
  - 277 named test mains are each a separate stock-Haxe build of the whole compiler (about two thirds of driver time).
    Generate 8 to 16 shard entry points and still run each case as its own process.
  - `tests/driver/TestCatalog.hx` lists 279 mains by hand and is touched by 54 of the last 500 commits. Discover by
    directory with an exclusion list.
  - 28 integration scripts, 12 hxml files, 2 compiler mains and six packages' tests are run by nothing. Add a
    registration check.
  - CI, `test.sh` and `gate.sh full` run three different gate sets. Define the gates in one manifest.
  - `check-hxi.sh` overwrites the checked-in binding, so the audio CI job cannot detect ABI drift. Give every binding
    an `update-hxi.sh [--check]` that diffs against a temp file.
- **Docs.** 85 flat files mix references, design notes, experiment reports and handoffs with no index. Split into
  `docs/reference`, `docs/design` (mandatory status line), `docs/reports` and `docs/history`. Fix the ADR 0003 and
  0004 status lines, the HLP and HLB version numbers, and keep one list of Haxe-compatibility gaps.

## Where we overengineered, and where cutting code is worth it

Cutting lines is worth it where a mechanism exists twice or has no consumer. It is not worth it as a goal in the core
pipeline, where no reviewer found wholesale redundancy.

### Delete or move out

- **Packages with no in-repo consumer:** `agentkit`, `agentkit-nativekit`, `animation`, `credentials` (about 5k lines
  plus generated bindings). Decided: left as they are.
- **`vendor/format`** (119 files, 23k lines): nothing in this repo's scripts, tests or build references it. The
  HashLink debugger and `hlmem` submodules use a `format` haxelib, not this copy; its README says it served HashLink
  inspection tools, and the script that used it is gone. Decided: kept for now, because another application may
  use it.
- **Dead pieces:** `WasmRuntimeContract.hx`, `ProjectManifest.hx`, `haxeon.ui.lab`, `ViewportLook`, 15 uncalled
  primitives in `host_state.c`, unused FFI projection abstractions. Reject `wasm64` at argument parsing until it is
  implemented.
- **`packages/ui`** takes about a quarter of repo activity and is absent from the roadmap. Decided: it stays and
  becomes a roadmap gate (phase 4).

### Collapse duplicates

- The Wasm runtime library emitted once per reference model (see 9).
- The language service's approximate typer and the inference look-ahead walkers (see 5).
- The pre-SSA CFG: it duplicates the instruction set, verifier and builder for one producer and one consumer. Reduce
  it to `LoadLocal`, `StoreLocal` and `Op(IrInstruction)`.
- `HaxeonCli`'s legacy build path and manifest parser (see 6).
- Two content-hash caches for the same CLI plus a fake `haxe` shim; the self-hosting fixed point in both bash and
  Haxe; seven Haxe mains that only shell out to bash; 13 ffi-audit scripts; about 84 scripts that hand-roll the
  preamble `scripts/lib/env.sh` provides.
- Process capture implemented at least seven times, some of which never drain stderr. Keep `ProcessOutputCapture`,
  move it to a neutral package, delete the rest.
- Five IR type-equality implementations, with `Std.string(type)` used as identity although it prints differently
  under stock Haxe and Haxeon. Use `IrTypeIdentity` everywhere.
- JSON field readers (`requiredString` in 14 files) and `ensureDirectory` (11 files).
- In `packages/ui`: two component models (the new one is used by two library widgets) and two duplicated frame render
  paths in a 5,486-line `api.cpp`.

### Expected scale

With `vendor/format` and the four packages kept, outright deletions are small (dead files and unused pieces). Inside `src/` (168k lines) the
duplicate-collapsing work should remove a few thousand lines; that figure is an estimate, not a measurement. Splitting
large classes will not reduce line count and should be done for navigability only.

## Where reviewers disagreed

- **Wasm patch support** (`WasmBackend.compilePatch`, called only from tests). The backend reviewer says remove it
  until a host consumes it; the cross-cutting reviewer says keep it as the seam for Wasm live patching. Decided: Wasm
  hot reload is planned, so it stays.
- **Single-entry static caches** (`IrProgramIndex.cached`, `IrMethodResolution.cached`). The IR reviewer wants them
  owned by a pipeline context; the cross-cutting reviewer says they are validated on every use and fine while the
  pipeline is single-threaded. They can move when the pipeline context exists (issue 2); they are not urgent.
- **`HxiHaxeEmitter`** (3,081 lines). The FFI reviewer rates the split high; the cross-cutting reviewer notes the
  package is self-contained and low churn (9 of 500 commits) and would only split `sourceRaw`. Low priority.
- **What blocks parallel typing.** The subsystem reviewers point at static state; the cross-cutting reviewer shows
  static state is light and the real obstacle is `TypingSession`. The second reading has the better evidence.

## Decisions taken (2026-11-16)

- **`packages/ui` stays and goes on the roadmap.** Its cleanup is planned work (phase 4).
- **The four consumer-less packages** (`agentkit`, `agentkit-nativekit`, `animation`, `credentials`) **are left as
  they are.** No move and no new CI job.
- **`vendor/format` is kept for now;** another application may be using it.
- **Wasm hot reload is planned.** Wasm patch support stays as the seam and gets a proper owner in step 1.5.
- **The `TypingSession` split is scheduled now,** not deferred to the Pragtical measurement (step 2.2).

## Plan

Every step is one or more commits on `main` that leave the tree green. Pure moves are checked by the self-hosting fixed
point (the self-built compiler's output hash is unchanged) and `HAXEON_CHECK_REUSE`; behaviour changes get a targeted
test. The full suite is left to CI.

### Phase 0: small and safe

Independent of each other and of everything below; each is effort S.

| Step | Change | Done when |
|---|---|---|
| 0.1 | One `AstFunction` copy helper in `compiler.syntax`, used at all nine copy sites | A typer test with `inline` and `@:keep` functions with inferred return types, and an inline abstract method, passes |
| 0.2 | `update-hxi.sh [--check]` for every binding; test scripts and CI call `--check` | A deliberately stale `.hxi` fails the audio job; running tests no longer dirties the worktree |
| 0.3 | Move `native_trace.c` out of `haxeon_runtime`; drop `vendor/nativekit/include` from `CMakeLists.txt:73` | The runtime builds with the NativeKit submodule absent |
| 0.4 | Delete `WasmRuntimeContract.hx` and `ProjectManifest.hx`; reject `wasm64` at argument parsing | `wasm64` is an argument error, not a late throw |
| 0.5 | Docs: ADR 0003 and 0004 status lines, HLP 11 and HLB 8 in the format docs, re-check the gap list in `scripts/check-self-hosting.sh` after `028ce4fa` | Status lines match `ARCHITECTURE.md` and the code |
| 0.6 | Registration check: fail when a file under `tests/` is run by nothing; register or delete the 28 scripts, 12 hxml files and 2 mains found | The check runs in CI |
| 0.7 | Add `packages/ui` to `ROADMAP.md` as a gate, with the phase 4 items | Roadmap lists it |

### Phase 1: structural spine

In order; each step unblocks the next.

- **1.1 Leaf package.** Create `compiler/core` and move `Source`, `Diagnostic`, `QualifiedName`, `Provides`,
  `CancellationToken`, `AllocationMeter` and `IrPassMeter` into it. Pure move. Effort S.
- **1.2 One home for HashLink.** Move `compiler/ir/hl` under the HashLink backend; move the Wasm references out of
  `ir` (`IrVerifier.hx`, `IrOpportunityCensus.hx`). Write the allowed dependency order in `ARCHITECTURE.md`. Pure
  move. Effort M.
- **1.3 `IrPipeline`.** One ordered stage list per target; `IrProgramAssembler.assemble`, the tail of
  `FrontendCompilation.run`, `BackendAssembly` and the Wasm builders call it. Unported passes run as opaque stages.
  Pure move first, no reordering. Effort L.
- **1.4 Split `FrontendCompilation.run`** into phase functions over a per-build record, with one timing helper.
  Effort M.
- **1.5 Backend session.** Target parsed once into `BackendTarget`; a session backend interface with HashLink and
  Wasm implementations; Wasm builds skip `HlModuleAssembler`; `CompileResult` carries a backend artifact. The Wasm
  implementation owns its module cache and patch state, with identities from the same stable-ID source as HashLink.
  Promote the 22 downcasts in shared Wasm lowering to interface members. Before starting, list what the Wasm path
  still reads from the HashLink result. Effort L, the riskiest step of this phase.
- **1.6 `SessionState` and `FfiRegistry`.** One state object with `copyForCandidate()`; delete the
  `CompilationContext` forwarders; `validate()` becomes "create candidate, then run". Effort M.
- **1.7 Structural invalidation in the compiler.** Finish alias, enum and abstract shape invalidation; delete the
  pre-scan in `CompilerSession`. Gate: a warm-edit test that changes a typedef's shape matches a cold build.
  Effort M.

### Phase 2: typer

Can start alongside phase 1 (different packages), but 2.2 to 2.5 are in order. 2.6 runs beside 2.5 (see its note), and
2.7 beside 2.6.

- **2.1 Callback wiring.** Replace the 42 callback typedefs and forwarding closures with one narrow interface held by
  each sub-typer. Pure refactor. Effort M.
- **2.2 Per-unit typing output.** Split `TypingSession` into an immutable program view and a per-unit output record
  (requests, anonymous-type uses, lambda cache entries, dependencies, counters scoped by unit). `ProgramTyper` merges
  outputs in sorted unit order. Do it in three moves: group the fields into owned sub-objects, move the request
  queues, then the counters. Gate: output is byte-identical when bodies are typed in a different order. Effort L,
  high risk.
- **2.3 Inference variables.** Add `TMono` to `CompilerType`, bound in assignability and coercion, with a post-body
  pass that defaults or rejects unbound ones. Migrate one case per commit, starting with the empty array literal, and
  delete the matching look-ahead walker each time. Each case gets a differential test against Haxe. Effort L, high
  risk.
- **2.4 Error recovery.** The typer records the diagnostic, produces an error-typed node and continues. Then delete
  the language service's approximate typer. Effort L. Recovery landed on 2026-11-17 (`7baff2763`): a function body or
  field initializer that fails is dropped and typing continues, with one diagnostic per failed body. Deleting the
  approximate typer remains: a failed body has no typed information, so the language service still falls back to syntax
  inside it. Typing the parser's repaired syntax with the real typer is decided (2026-11-18) and queued for the service
  lane after 2.7's stage 2 items 1 to 3.
- **2.5 Lazy declaration typing** (added 2026-11-17, design in
  [LAZY_DECLARATION_TYPING.md](../design/LAZY_DECLARATION_TYPING.md)). An unannotated field's type and an unannotated
  function's return and argument types are those of its typed initializer or body, typed once, on demand, in its own
  unit, and closed when that unit ends. One query returns a declaration's resolved type. A cycle between units and a type
  left open are errors. Then delete `SignatureInference` and the inference half of `FieldInference`. A read of an
  inferred type is recorded, so an edit retypes the readers. This widens 2.3's scope, which kept signatures and field
  types syntactic. Six slices: the query, byte-identical; invalidation; fields; returns and arguments; deletion; early
  cutoff with ADR 0003 M4. Gate: differential tests against Haxe 4.3.7, warm-edit tests for inferred types, and
  `--reverse-typing-order` byte-identical. Effort L, high risk. Slices 1 to 5 landed on 2026-11-17 (`SignatureInference` and
  `FieldInference` are deleted); slice 6 waits for M4. Commits: slice 1 `0c85b037c`, `eb9ed3b52`; slice 2 `6a653ad61`;
  slice 3 `efdaf6da1`; slice 4 `a612f7495`, with the fix `60f3e8afd` and warm seeding `bb45eba08`; slice 5 `c64394dd5`,
  `9791f07f5`, `6c8da8ebc`, `5999d81e4`, `ce0f9ab00`.
- **2.6 Open anonymous types and structure values** (added 2026-11-18, design in
  [STRUCTURE_VALUES.md](../design/STRUCTURE_VALUES.md)). An object literal's structure stays open while its unit is
  typed and gains the optional fields of the structures it meets, as in Haxe; it is closed and named when the unit's
  frame is settled. Width subtyping (var and final fields, `Array` and function variance), class and interface to
  structure, and `Dynamic` to structure become retypes that keep identity: a structure value is the object itself, and a
  field access tests the object's exact class, with a generated dispatcher for other shapes (one model on HashLink,
  Wasm32 and Wasm GC; erased generic owners move onto the same dispatcher). Then delete `localExpectedTypes`. Replaces
  the reverted copy-based widening of `c618c16d8`. Two tracks: representation (haxeon-e4: census, `Structure(S)`,
  dispatchers, erased owners) and typing (open literals, then the deletion), joined by the relations slice. Gate:
  differential tests against Haxe 4.3.7, `--reverse-typing-order` byte-identical, warm and live structure edits, the
  self-compile no slower than noise and nbody within 3%. Effort L, high risk. The design and the user's decisions are
  recorded (`2b28b4c8e`, `6232eb09c`). Slice 0, the revert, landed on 2026-11-17 (`65810ae26`), and slice 5, open literal structures, on
  2026-11-18 (`5598a3dfc`, with `f9a9c84e5`), then slice 6, which deletes `localExpectedTypes`. The representation track
  (haxeon-e4) is in progress; slice 4 (relations) waits for its dispatchers. Decisions 4 and 5 were taken on
  2026-11-18: a `null` optional field reads as absent in reflection, and a structure used as a `Map` key compares by
  identity (slice 4a).
- **2.7 Typing generic code once** (added 2026-11-18, design in
  [GENERIC_TYPING_ONCE.md](../design/GENERIC_TYPING_ONCE.md)). A generic body is typed once with its own parameters,
  and each representation's code (erased, specialized, owner specialization) is produced from that typing by an
  elaboration pass instead of typing the body again. Stage 1, typer only, landed on 2026-11-18 (design
  `9e1a245d4`; `a4e4ac0dd`, `0e4c8286a`). Stage 2, the elaboration pass, was approved by the user on 2026-11-18 under
  haxeon-e4's contract: the pass runs on the typed AST before `IrGenerator` and its output is today's typed code, checked
  by a permanent equivalence test; every inserted boundary keeps its semantic source type; owner and specialization
  names come from one function shared with the IR lane; lambdas get structured names. Items 1 to 3 (boundaries, layout
  constants, helper choice; byte-identical) go to the service lane now, beside 2.6 slice 2a. Items 4 and 5 (nested
  calls and lambda names, then the pass replacing paths 6 to 8 and deleting check units) wait until the naming and the
  boundary contract are agreed with haxeon-e4. Effort L, high risk.

### Phase 3: service

- **3.1 `project.CompilerInputs.of(project, layout)`** consumed by build and LSP; the LSP resolves with the lockfile
  in no-network mode. Effort M. Landed on 2026-11-17 (`7a495d9c9`).
- **3.2 Remove the legacy CLI path.** Delete `HaxeonCli.loadConfig`; route wasm32 and Android through the structured
  build. Depends on 1.5. Effort M. Landed on 2026-11-17: wasm32 in `f2e1ac922`, Android in `ce88bb128`
  ([ANDROID_BUILD.md](../design/ANDROID_BUILD.md)).
- **3.3 Shared protocol types.** One module of typed request and response definitions used by `CompilerClient` and
  `CompilerServer`. Effort S. Landed on 2026-11-17 (`2326504cc`, `CompilerServerProtocol`). The single service process
  per project follows later, after 1.6, with its own design.

### Phase 4: `packages/ui`

Independent of phases 1 to 3.

- **4.1** Finish the component-model migration as a bounded port list (the 8 self-updating widgets, the 4
  retained-edit widgets, then the `context.state` callers), deleting each old mechanism with its last caller.
- **4.2** Merge the two duplicated frame render paths in `api.cpp`.
- **4.3** Break up `UiContext` and `BuildContext`; replace the 12 parallel custom-paint maps with one record.
- **4.4** Remove the upward dependencies from `core`; delete `haxeon.ui.lab` and the seven compatibility shims.
- **4.5** Split `FrameworkSmoke.hx` (7,457 lines) and settle on one test harness style.

### Phase 5: opportunistic

Done when a feature touches the area, or as filler; none blocks the phases above.

- Intrinsic table and FFI descriptor codes defined once (issue 8).
- `ProcessOutputCapture` as the single process-capture primitive.
- Move the Clang importer out of `compiler/ffi` and run it as a prebuilt tool artifact.
- Test shards instead of 277 compiler builds; `TestCatalog` discovery by directory; one gate manifest for CI,
  `test.sh` and `gate.sh`.
- Script and launcher consolidation (one launcher and cache, `env.sh` preamble, one ffi-binding script).
- Docs layout (`reference`, `design`, `reports`, `history`) with an index.
- Large-function extraction in `IrGenerator`, `WasmFunctionLower`, `HlLower`, `SemanticAssembly`.
- Wasm runtime library written once in Haxe; Android linking the fork's CMake targets; the reduced pre-SSA CFG;
  `IrTypeIdentity` as the only type equality.

### Design decisions for the high-risk steps (2026-11-16)

These were settled before implementation so the steps can run without further input.

**1.5 Backend session**

- A Wasm build runs no HashLink assembly. In `CompilerDriver` the Wasm path reads only the IR, the module names and
  the metrics of a `CompileResult`; function IDs, runtime identity and patch bytes are read only on the HashLink path.
- `CompileResult.module:HlCode` becomes a backend artifact with a HashLink case (module, function indices and IDs,
  runtime identity, patch bytes) and a Wasm case (bytes). The driver and the Android tools switch on it.
- The Wasm module cache (`CompilerSession.wasmModule`) moves into the Wasm session backend and is copied and rolled
  back with the candidate.
- The Wasm session backend takes ownership of the existing patch state unchanged. Unifying Wasm patch identities with
  HashLink's stable function IDs is a separate later step, done when a Wasm host exists to test it.
- `HlBackend` (used only by tests) is rebuilt on the production assembler path.

**2.2 Per-unit typing output**

- The unit is one function body or field initializer, matching the body fingerprints.
- Generated helper names are scoped by unit name plus a local index instead of counters that depend on typing order.
  This renames helpers once; live sessions need a restart after that commit.
- No threads are added. The step makes per-unit typing a pure function of the program view and the unit.

**2.3 Inference variables**

- A monomorph exists only while a body is typed. A post-body pass replaces each with its bound type, and a verifier
  asserts none escapes into the typed AST, IR, caches or fingerprints.
- A local whose type is never determined becomes `Dynamic`, as in Haxe. Haxe gives no warning for it, so neither does
  Haxeon. A `new Map()` whose key and value are never determined stays an error, as in Haxe.
- Scope is locals and the parameters and returns of lambdas inside a body. Function signatures and field types keep
  `SignatureInference` and `FieldInference`.
- Open structural constraints are out of scope.
- `BodyTyper.inferBodyLocalTypes` (`localExpectedTypes`), the last look-ahead pass, stays until object literals get
  Haxe's model. It gives an object literal that fills an empty array or a `null` local the structure a later use
  expects, optional fields included (`arguments.push({name, type, span, optional, defaultValue})` in `Parser.hx`,
  passed on as `Array<AstArgument>`). Haxe needs no look-ahead for this: an object literal's structure may gain the
  optional fields of a structure it is unified with, in place, so the array's element type becomes the later use's
  (`var c = {name: "y"}; var d:{name:String, ?optional:Bool} = c;` passes in Haxe and fails in Haxeon). Replacing the
  pass means giving each literal its own field list, open to optional fields until its body is settled and named only
  then, with the post-body pass rewriting the literal and every value of its type. That changes how anonymous types are
  registered and named for their HashLink layouts, so it is a step of its own. The pass also fills a local with its
  hint when a value widens to it (`values.push(1)` into an array returned as `Array<Float>`), which Haxe rejects with
  `Int should be Float`; that divergence goes with the pass.

**2.4 Error recovery**

- The function is the unit of recovery: one diagnostic per failed function. Its signature is kept; its body is marked
  errored and is neither cached nor lowered. The build fails afterwards if any diagnostic was recorded.
- Declaration-level errors still abort.
- The error codes move into one enum abstract first, as a pure refactor.

**3.3 Single service**

- Only the first part is planned now: one module of typed request and response definitions used by both
  `CompilerClient` and `CompilerServer`, with no change to process topology.
- The single per-project process is designed after `SessionState` (1.6) lands and query latency during a compile can
  be measured.

### Not planned

- Deleting `vendor/format`.
- Moving or adding CI for `agentkit`, `agentkit-nativekit`, `animation` and `credentials`.
- Splitting `HxiHaxeEmitter` beyond `sourceRaw`.
- Moving the single-entry static IR caches before the pipeline context exists.

## Verification

Re-checked by hand at `c6cfd889`:

| Claim | Result |
|---|---|
| Wasm builds run a HashLink assembly (`BackendAssembly.hx`, comment and `ir.copy()`) | Holds |
| `HlBackend` has no reference in `src/` | Holds |
| `check-hxi.sh` defaults its output to the tracked binding and the audio test calls it with no argument | Holds |
| `CompilerSession.hasStructuralDeclaration` pre-scan exists | Holds |
| `haxeon_runtime` includes `vendor/nativekit/include`; `native_trace.c` includes `nativekit_trace.h` | Holds |
| ADR 0003 says "nothing here is implemented" while `ARCHITECTURE.md` records M0 and M1 as landed | Holds |
| File sizes: `IrGenerator` 4,271, `HxiHaxeEmitter` 3,081, `BodyTyper` 2,858, `LspProtocol` 1,562, `Compiler` 1,156 | Holds |
| 42 callback typedefs in `types/typing` | Holds |
| HLP is version 11 and HLB version 8 in code; the two docs say 7 | Holds |
| `WasmRuntimeContract.hx` and `ProjectManifest.hx` have no references | Holds |
| `SignatureInference.withResult` omits `isInline`, `isExtern`, `metadata` | Holds (the omission; the user-visible effect was not reproduced) |
| `sys.io.Process` lacks Haxe's API | Fixed by `028ce4fa` during the review |
| `vendor/format` has no consumer | Holds for this repo's own build, scripts and tests; two submodules use a `format` haxelib |

`WasmGcRepresentation.hx` is 6,625 lines at `c6cfd889`, not the 7,383 one reviewer reported.

## Findings by subsystem

Each list is in the reviewer's order, most important first.

### Cross-cutting (whole repo)

Cross-cutting view of /home/joao/dev/haxeon/src: 592 .hx files, ~168k lines; src/compiler is 455 files / 149.5k lines, dominated by ir (128 files, 39.3k), backend/wasm (71 files, 38.2k), types (85 files, 27.2k) and ffi (35 files, 11.8k). stdlib is 12.8k lines, packages 91k. Churn is extreme: the last 500 commits span 2026-11-07..16; src/compiler/ir is touched in 133 of them, types in 67, compilation in 46. Per-file hotspots: FrontendCompilation.hx (31), IrProgramAssembler.hx (28), IrVerifier.hx (23), HlLower.hx (22), IrGenerator.hx (20), plus tests/driver/TestCatalog.hx (54).

Import graph (grep of import/using plus fully-qualified references): the intended order syntax -> semantic/types -> ir -> hl/backend -> compilation -> service/tools mostly holds by volume (types->syntax 153 imports, backend->ir 223, 0 reverse imports), but there are 18 mutually dependent package pairs. The genuine ones are semantic<->types (12/28 files), ir<->hl (4/9 files), compilation<->Compiler root, and a handful of single-file upward edges caused by small leaf utilities living in high-level packages.

Health: the incremental/transaction design (candidate, adopt, snapshots, check mode) is coherent and static mutable state is light (30 static vars, mostly caches and diagnostics switches). The structural debts are (a) the build pipeline and session are HashLink-shaped, with Wasm bolted on after a discarded HL assembly; (b) pass ordering and backend code for HL are scattered over three packages; (c) a few god functions (1.4-1.5k-line switch/if-chains) and one 55-map typing blackboard that is the real obstacle to parallel typing; (d) a typer split wired by 42 callback typedefs. Exact-duplicate code is small (23 groups, ~405 lines); dead code is almost nil.

- **Wasm builds run a full HashLink assembly that is thrown away; the Backend seam is not on the production HL path** (architecture; severity high, effort L, risk medium). Make the target a session-level backend object: move HL assembly/patch planning (BackendAssembly.assemble body, assembler, loweredCache, publishedAbi-by-HL) behind a session backend interface with an HL implementation and a Wasm implementation (which owns its module cache and WasmPatchState). CompilationPipeline calls backend.assemble(ir, changes); CompileResult carries a backend artifact instead of HlCode. Then delete the Wasm branch in BackendAssembly and fold HlBackend into the HL implementation's stateless entry (tests keep a one-line helper).
- **IR pass pipeline is split between IrProgramAssembler.assemble and the tail of FrontendCompilation.run** (architecture; severity high, effort M, risk medium). Introduce compiler/ir/pipeline/IrPipeline.hx that owns the ordered pass list (name, run, enabled-predicate on TargetProfile/live) and is the single caller of IrPassMeter; IrProgramAssembler keeps only typed->IR declaration building; FrontendCompilation.run is cut into parse/semantic, type, generate, and a call to IrPipeline.run, each returning its own timing record. Move IrPassMeter and AllocationMeter (47 and 61 lines, no compiler imports) to a leaf package so ir/hl/types stop importing compilation.
- **TypingSession is a 55-map shared blackboard with a body-context stack and order-dependent counters** (architecture; severity high, effort L, risk high). Split the session into (1) an immutable program view (decls, relations, representation, externals) and (2) a per-unit TypingOutput record (requests, anonymous uses, lambda cache entries, dependencies, counters scoped by unit name). BodyTyper writes only to the current unit's output; ProgramTyper merges outputs in sorted unit order. That gives deterministic assembly today and makes per-unit typing a pure function of (view, unit) when parallelism is wanted. Do it before the Pragtical measurement only if the measurement asks for it, but stop adding new session-level maps now.
- **Body typer split into 5 classes wired back together with 42 callback typedefs** (overengineering; severity medium, effort M, risk medium). Replace the callback typedefs with one small interface (e.g. BodyTyping with typeExpression, coerce, lowerType, arrayElementType, typedMember, findFieldType, ...) implemented by BodyTyper and passed once to each collaborator, or simply give collaborators a `final body:BodyTyper` reference inside the package. Keep the file split; delete the 42 typedefs and the 62 forwarding closures.
- **HashLink backend code lives in three packages with an ir<->hl import cycle; Wasm lives in one** (organization; severity medium, effort M, risk low). Move compiler/ir/hl/* to compiler/backend/hl/ (or compiler/hl/lower/) so the dependency is one-way backend->ir; keep compiler/hl as the bytecode-format package or nest it as backend/hl/format. Move the Wasm check field constant into an ir-level constant the Wasm backend references, and move IrOpportunityCensus.reportWasm into backend/wasm.
- **Runtime intrinsics are identified by string literals repeated across registry, typer ABI and three backends** (architecture; severity medium, effort M, risk medium). Define intrinsics once as an enum abstract (or a table of records: id, symbol, aliases, signature, pure) in compiler/runtime; NativeRegistry resolves a call's name to the id once. Backends switch on the id (exhaustiveness-checked) and lowerRuntimeCall becomes a dispatch to per-family methods (bytes, math, reflect, struct, string) of ~100 lines each.
- **God functions: four 800-1500-line switch/if bodies concentrate most of the churn** (organization; severity medium, effort M, risk low). Mechanical extraction, one family per method, keeping the dispatching switch: IrGenerator.lowerExpressionAt -> lowerCall/lowerField/lowerSwitch/lowerLiteral...; WasmFunctionLower.lowerInstruction -> per-instruction-group methods and reformat the file to tabs; SemanticAssembly.run and FrontendCompilation.run -> phase methods returning a result record. No behaviour change, do it file by file.
- **Leaf utilities placed in high-level packages create upward imports and the compiler-root grab bag** (organization; severity medium, effort S, risk low). Create compiler/core (or compiler/base) for Source, Diagnostic, QualifiedName, Provides, Arrays, CancellationToken, AllocationMeter, IrPassMeter; move the AST-only analyses to compiler/syntax/analysis (or compiler/semantic); move LambdaName next to abi's naming code; move CompileResult/AnalysisResult/Ffi* typedefs out of Compiler.hx into compilation/ and ffi/. Pure moves plus import rewrites.
- **CompilationContext is a 50-method forwarding facade over Compiler, and Compiler still carries the FFI registry** (overengineering; severity low, effort M, risk medium). Extract the build-scoped state (modules, graph, caches, assembler, publishedAbi, pipelineSnapshot, verifyMemo ...) into one SessionState class with copy()/adopt() so candidate/snapshot logic is one method; pass SessionState to the pipeline directly and delete the forwarders. Move the FFI block into compiler/ffi/FfiRegistry owned by the session. Unfinished-seam caveat: keep the transaction classes as they are.
- **JSON field readers and small filesystem helpers are re-implemented per file** (organization; severity low, effort S, risk low). One `project.JsonFields` (required/optional string, int, array, with a path-aware error) used by project, tools and editor; one `Directories.ensure` (src/build/execution/Directories.hx already exists) used by the 11 sites; fold the typer triplicates into TypingSession/TypeRepresentation statics.
- **Entry points and names that mislead: src/Main.hx, two `runtime` and two `tools` packages, hand-maintained TestCatalog** (organization; severity low, effort S, risk low). Rename src/Main.hx to tests-oriented `ProgramSuiteMain` (or move under src/tools/dev); rename compiler/runtime to compiler/intrinsics and compiler/tools to compiler/driver; move build.Target and ProcessRunner to a shared leaf used by project and build; have TestCatalog discover tests/<suite>/*Main.hx by directory with an explicit exclusion list.
- **Small dead or speculative pieces** (overengineering; severity low, effort S, risk low). Delete WasmRuntimeContract.hx and ProjectManifest.hx; reject wasm64 in CompilerArguments until implemented (keep the enum case); gather the HAXEON_* reads into one CompilerSwitches record built per request and passed through CompilationContext, documented in one table. Leave the Wasm patch API: it is the seam for Wasm live patching.

### IR (`src/compiler/ir`)

Scope: /home/joao/dev/haxeon/src/compiler/ir (128 files, 39.3k lines; all paths below are relative to /home/joao/dev/haxeon). The data model is small and sound: Ir.hx (394 lines: IrType, IrInstruction with about 60 constructors, IrProgram) and IrFunction.hx (a required `kind`, with providers as typed rows). Lowering goes TypedAst -> IrGenerator (4,272 lines) -> cfg/ (mutable-local CFG, SsaBuilder) -> IrFunction. About 45 whole-program representation passes follow (enum tag and inline enum, value arrays, optional and nullable scalars, scalar arguments and closures, dispatch helpers), then IrInliner (which also runs the scalar optimizations), IrVerifier (1,817 lines), codec/ and hl/HlLower (2,220 lines).

Health: the model and the per-function machinery (copy-on-write IrFunctionRewrite, IrOperands, verify memo, inline memo) are good and deliberately tuned. The weak part is everything around the passes:
- No pipeline object exists. Ordering is hand-written inside a 590-line `IrProgramAssembler.assemble`, `FrontendCompilation`, `BackendAssembly` and three Wasm builders, with correctness rescans between them.
- Passes have heterogeneous signatures and each rebuilds its own name maps.
- "Neutral" IR code reaches into the HashLink and Wasm backends.
- Type equality has five implementations, and `Std.string(type)` is used as identity.
- Two process-global single-entry caches sit under a compiler that is meant to be a persistent service.

Much of the name-marker and enum-rescan debt is already tracked in docs/IR_PASS_INVENTORY.md and docs/ENUM_PASS_PHASE_ORDER.md. Those plans are sound but mostly "proposal, no code". The findings below concentrate on what the plans do not cover or what blocks them. The largest and most-churned files are IrGenerator (96 of the last 400 commits), IrProgramAssembler (74), HlLower (69) and IrInliner (67).

- **The pass pipeline has no owner: ordering is spread over six files with target branches and repeated rescans** (architecture; severity high, effort L, risk medium). Land the inventory's 'framework commit' as a pure move first. Add one `compiler.ir.pipeline.IrPipeline` holding an ordered list of named stages per target (HashLink plain, HashLink live, Wasm32, WasmGc). Each stage is `(IrProgram, PassContext) -> IrProgram`, where the context carries profile, facts, tables, meter and check hooks. Have `assemble`, the FrontendCompilation.hx:803-856 block and the BackendAssembly/Wasm tail call it. Metering (`IrPassMeter.measure`), the `IrEntryPrune.checkRemoved` hook and the enum-escape resolution boundary become properties of the stage list instead of hand-placed calls. Unported passes run as opaque stages, as the inventory's rule 6 already says.
- **IrGenerator is a 4,272-line class with two functions of about 650 and 1,190 lines that hold every feature's lowering** (organization; severity high, effort L, risk medium). Keep IrGenerator as the per-function driver (scratch state, `generateFunction`, the statement/expression dispatch) and move feature groups into collaborator classes that take the generator and builder: `IrMapLowering`, `IrFlatValueLowering`, `IrOptionalPlaceLowering`, `IrObservableLowering`, `IrSwitchLowering`, `IrArrayLowering` (sort, indexOf, remove), with `lowerType` in an `IrTypeLowering` that IrProgramAssembler also uses. Make each `case` of the two big switches a one-line call. This is mechanical and can go one group per commit, each checked by self-hosted hash equality.
- **IR type equality has five implementations, and `Std.string(type)` is used as identity although the code documents it as runtime-dependent** (architecture; severity medium, effort M, risk low). Make `IrTypeIdentity.same` and `IrTypeIdentity.text` the only equality and text. Turn `IrVerifier.sameType` into a forwarding inline and then replace its 95 uses mechanically. Delete the CfgVerifier, IrGenerator and HlModuleAssembler copies. Replace the 8 `Std.string(type)` name/key sites with `IrTypeIdentity.text`. Add a grep check to scripts/ that fails on `Std.string(` applied to an IrType and on `Type.enumEq(` in src/compiler/ir.
- **Target-neutral IR code depends on the HashLink and Wasm backends, and HashLink lowering lives inside the ir package** (architecture; severity medium, effort M, risk low). (1) Move src/compiler/ir/hl/* to src/compiler/backend/hl/ next to HlBackend, and move `PhiEdges` to src/compiler/ir/cfg or the ir root. (2) Extract the eligibility predicate `IrScalarArguments` needs from `HlScalarValueLocals` into a neutral `IrScalarValuePlaces` analysis that both IrScalarArguments and HlLower consume. (3) Declare `CHECK_FIELD` and `LIVE_INITIALIZER` in ir (the backend reads them, not the reverse). (4) Split the HashLink and Wasm size reporters out of IrOpportunityCensus into their backends. (5) Move IrPassMeter/AllocationMeter below ir, or inject them via the pipeline context. (6) Fold `IrValueLaneTarget` and pointer width into `TargetProfile` so passes take one descriptor.
- **IrInliner.run is really the function optimizer, change detector and report driver; IrInlineCache is the session's IR cache** (architecture; severity medium, effort M, risk medium). Split into three units without changing behaviour. (a) `IrInliner`: inlining and its memo only. (b) `IrFunctionOptimizer`: the per-function sequence (scalar replacement, load/store forwarding, strength reduction, dead values, receiver checks, jump threading) with the `cleaned` memo. (c) `IrPublication`: `published`/`publishedBytes`/`relocated` and the changed-set computation, called by FrontendCompilation. Rename `IrInlineCache` to `IrSessionCache`, composed of those three plus the static-check and positional-fingerprint caches, each with its own `copy()`. Move `remap`/`substitute` to an `IrRemap` class next to `IrOperands`. Call the census and allocation reports from the pipeline, not from the inliner.
- **Process-global single-entry caches and a global check-mode side channel under a compiler that is meant to be a persistent service** (architecture; severity medium, effort M, risk low). Give builds an explicit `IrAnalyses` holder, owned by the pipeline context, that hands out `IrProgramIndex`, `IrMethodResolution` and the object table for the current program and is invalidated by the stage that replaces functions or objects (a version counter bumped on assignment, not a length heuristic). Delete both `static var cached`. Move the prune watch into that context so it dies with the build. Move the three `enabled` flags and `HAXEON_CHECK_REUSE` (read at 5 sites in ir) into one immutable `IrOptions` read once and included in `TargetProfile.key()`-style cache keys.
- **IrProgramAssembler does three jobs; about 570 of its lines are a hand-written runtime-native table keyed by name prefixes** (organization; severity medium, effort M, risk low). Split into `IrDeclarations` (the typed-to-IR `*From` functions, the only part that needs compiler.types), the pipeline (see the first finding) and `IrRuntimeSurface`. For the last one, replace the if-chain and 59 literals with one table in compiler.runtime, next to NativeRegistry: name or prefix rule, library, symbol, argument and result types. The assembler filters it by the calls it sees, and the Wasm builders and interpreter consult it instead of repeating name lists. Build the input IrProgram once. This is also the natural home for the 'native roles' that docs/IR_PASS_INVENTORY.md lists as a1 debt.
- **The pre-SSA CFG duplicates the whole instruction set, verifier and builder for one producer and one consumer** (overengineering; severity medium, effort L, risk medium). Define `enum CfgInstruction { LoadLocal(output, name); StoreLocal(name, value); Op(instruction:IrInstruction); }` over `IrValue`. SsaBuilder then renames operands with the existing generic remap (IrInliner.remap, 1153) instead of the 190-line switch. Reduce CfgVerifier to what is CFG-specific (locals declared and typed, terminators present, definitions before uses) and leave the type rules to IrVerifier. Have CfgBuilder delegate value construction to IrBuilder's emitters. Do it behind self-hosted hash equality; the generated IR should be identical.
- **Every pass rebuilds its own name maps: four index classes plus about 34 ad-hoc maps** (architecture; severity medium, effort M, risk low). One `IrTables` value per program state (objects by name, children, interfaces, functions by name), built once by the pipeline and passed to stages. A stage that changes a table returns a new `IrTables`. Read recording (IrObjectTable.consulted, IrVerifyTable) and the prune check (IrFunctionIndex) become optional wrappers over it. IrMethodResolution and the subtype/implementor memo of IrProgramIndex become lazily computed members. This is step 0 of the inventory's port order and needs no pass interface.
- **IR is immutable by convention only, and the assembler mutates cached functions in place** (architecture; severity medium, effort S, risk low). Do the C-native rewrite through `IrFunctionRewrite.instructions` (src/compiler/ir/passes/IrFunctionRewrite.hx:18), which returns the same object when nothing changes and a copy otherwise. Better, have IrGenerator emit `CNativeCall` for every C native (it already does for `TCNativeCall`, IrGenerator.hx:2260) so the assembler step disappears. Then remove the positional-fingerprint special case. Expose `IrBlock.instructions` as `haxe.ds.ReadOnlyArray` outside builders, so the three intentional in-place sites (IrInliner.hx:978 and 1146, IrLoadStoreForwarding.hx:144, all on private clones) are the only ones that compile. Fix the `withBlocks` message to include `this.name`.
- **src/compiler/ir is one flat directory of 111 files where families are distinguished only by name prefix** (organization; severity low, effort M, risk low). Use sub-packages that match the pipeline phases: `ir/` (Ir, IrFunction, IrBuilder, IrOperands, IrGraph, IrTypeIdentity, IrTypeTools, TypeKey, IrProviders), `ir/lower/` (IrGenerator and its collaborators, ProgramFacts, declarations), `ir/analysis/` (reachability, type-aware walk, non-null facts, loop bounds, method resolution, escape reach), `ir/repr/enums/`, `ir/repr/valuearray/`, `ir/repr/optional/`, `ir/repr/scalar/`, `ir/dispatch/`, `ir/opt/` (inliner, load/store forwarding, strength reduction, dead values, jump threading, copy elision, scalar replacement), `ir/verify/`, `ir/report/` (census, allocation report, instrumentation) and `ir/interp/`. A pure move with import updates, done one family at a time.
- **Two reachability walkers coexist while IrReachability still documents itself as 'the one walker'** (architecture; severity low, effort M, risk medium). This is a tracked transition, so the change is to finish it rather than redesign. Once the 3b items in docs/REACHABILITY_WALK.md land, make `IrReachabilityWalk` a configuration of `IrTypeAwareWalk` (roots plus `keepLiveClasses`), keep `IrReachability` only for `prune`/`trimTables`/`natives`, and delete `HAXEON_EARLY_PRUNE`. Until then, fix the IrReachability header so it stops claiming to be the only walker, and add a check-mode assertion that the final walk's reached set is a subset of the early walk's.

### Backends (`src/compiler/backend`, `hl`, `abi`)

The scope is about 46k lines in three areas. (1) Wasm lives entirely in src/compiler/backend/wasm (about 36k lines): a shared core (WasmFunctionLower 3,236 lines, encoder, validator, CFG structuring, scalar ABI passes) plus gc/ (WasmGcRepresentation 7,410 lines, module builder, maps, arrays, interop) and linear/ (WasmLinearRuntime 4,833 lines, arrays, GC, module builder). The two reference models plug into shared lowering through the four WasmRepresentation interfaces. (2) HashLink is spread over three packages: lowering in src/compiler/ir/hl (HlLower, 2,220 lines, outside the assigned folders), encoding, incremental assembly, HLP patch and persistence in src/compiler/hl, and a 25-line adapter in src/compiler/backend/hl. (3) src/compiler/abi (9 files, about 1.2k lines) holds the semantic ABI descriptor, the patch planner and lambda-name alignment.

Data flow in production: HashLink goes CompilationPipeline -> BackendAssembly -> HlModuleAssembler -> HlLower -> HlWriter/HlPatchWriter. Wasm goes CompilerDriver -> WasmBackend -> Gc/Linear module builder -> WasmEncoder, after the HashLink assembly has already run.

Health: the HashLink incremental and patch machinery is carefully reasoned and well documented (relocatable lowering, append-only tables, check mode), but its responsibilities sit in one 952-line assembler and the reload decision is spread across three places. The Wasm side is the weaker part: the representation abstraction leaks (22 concrete downcasts in shared lowering), the Haxe runtime library is hand-emitted twice (239 intrinsic names shared by both models), and a few very large functions dominate. The `Backend` interface is nominal: neither production path is shaped by it. Backends do not reach into the AST or typer; the only frontend coupling is the lambda naming convention (compiler.semantic.LambdaName, 5 files). The reverse direction is the problem: compiler.ir imports backend classes in four places.

- **The Backend interface is not the real seam: HashLink production bypasses it and Wasm builds still run the full HashLink assembly** (architecture; severity high, effort L, risk medium). Make the seam match reality. Give the compilation context one target-backend object selected once, with two operations the pipeline calls: prepare target IR (the passes now guarded by isWasmTarget) and assemble (incremental HashLink assembly, or Wasm module build). Move the Wasm call out of CompilerDriver into that dispatch and skip HlModuleAssembler for Wasm targets (or make the retained HashLink copy an explicit opt-in if something needs it). Reimplement HlBackend on top of the production assembler path so tests cover it, and split BackendOptions into shared fields plus a Wasm options struct.
- **Shared Wasm lowering downcasts to the concrete GC and linear representations 22 times** (architecture; severity high, effort M, risk medium). Promote the downcast uses into interface members: null test, reference equality, scalar local/scalar call hooks, exception wrapper, post-lowering local compaction and function signature override. Where the two models genuinely differ in algorithm, return `UseDefault` from one of them as the interfaces already allow. Move WasmSafepoint/WasmGcRoots (used by both models) out of gc/ into the shared package so shared code no longer imports gc/ or linear/.
- **The Haxe runtime library is hand-emitted as Wasm instructions twice, once per reference model** (architecture; severity high, effort L, risk high). Keep the documented C-runtime direction for wasm32, and add a plan for the model-independent part of the GC copy: implement the operations that do not depend on object representation (string compare/split/case, Int64 parse/format, number formatting, enum string building) once, either as Haxe stdlib code compiled through the normal pipeline (as the docs already do for Regex and MemoryFileSystem) or as one emitter parameterised over a small accessor interface (load char, length, allocate string). Start with the 239 shared names and migrate by family.
- **The HashLink backend is spread over three packages with import cycles, and compiler.ir imports backend classes** (organization; severity medium, effort M, risk low). Move src/compiler/ir/hl and src/compiler/hl under src/compiler/backend/hl with subpackages lower/, encode/, incremental/, patch/, persistence/. Move PhiEdges to compiler.ir. Move the two shared constants (LIVE_INITIALIZER, CHECK_FIELD) to an IR-level names module that both sides import, and move IrOpportunityCensus.reportHashLink/reportWasm next to the respective writers.
- **The patch-or-reload decision is made in three places and re-parses string-encoded ABI descriptors** (architecture; severity medium, effort M, risk medium). Make RuntimeAbiDescriptor structured for objects (kind, base, interfaces, fields[], methods[{name, function}]) and keep the string only as the comparison/persistence key, so `frame` and `dispatchedFunctions` read fields rather than parse. Have the assembler return all of its reasons as AbiChange values (replace `layoutReasons:Array<String>`), and let one function in compiler.abi combine planner and assembler reasons into the final decision. Carry an `isGenerated`/kind flag on IrObject in the descriptor instead of matching `$lambda-env:` style prefixes.
- **HlModuleAssembler is a 952-line object that mixes policy, IR synthesis, layout planning, state persistence and timing** (architecture; severity medium, effort M, risk medium). Split into: (a) SignatureAdapters in compiler.abi or compiler.ir (pure IR in, IR out); (b) HlObjectPatchPlan (planObjects and helpers) returning reasons plus HlObjectLayout; (c) a slot-layout step that computes natives/dispatch/slots once and reports all layout reasons before a single fresh-layout decision; (d) the remaining assembler holding state and calling HlLower. Pass configuration as one immutable options value to `assemble`.
- **Long positional parameter lists on the two central backend entry points** (architecture; severity medium, effort S, risk low). Introduce `HlLowerOptions` and `HlPatchRequest` structures (or have HlPatchWriter.encode accept the HlAssemblyResult plus moduleId, stable ids and guards). Replace developmentOptions with a structural copy that overrides one field.
- **Runtime calls are dispatched through very long name-comparison chains inside giant functions** (organization; severity medium, effort M, risk low). Register intrinsics in a per-model table built once (name -> handler with a declared signature that is checked generically), split by family into files that already exist as a pattern (strings, bytes input/output, Int64, arrays, maps, enum strings). Keep `lowerRuntimeCall` as a table lookup. Split lowerInstruction by instruction family (calls, closures, aggregates, control) into helper classes sharing WasmFunctionLowerContext.
- **Per-module state held in static variables in the Wasm linear runtime and module support** (architecture; severity medium, effort S, risk low). Move the four WasmLinearRuntime fields onto WasmLinearContext (which `register` already receives and which already holds pendingExceptionFlag/Value) and pass the context to `runtimeFailure`. Hang the host C-native index on the module builder. Keep the read-only runtime byte caches.
- **Wasm patch support is a parallel mechanism with no production caller** (overengineering; severity medium, effort S, risk low). Either mark it explicitly as an experiment in docs/WASM_BACKEND.md and keep only the custom-section writer, or remove compilePatch/compilePatchBase, the readers and `patchChanged` until a host consumes them. If Wasm hot reload becomes a goal, derive identities from the same stable-id source as HashLink.
- **Declared but unimplemented or unused surface: Wasm64, WasmRuntimeAbi, PatchDecision.Reject** (overengineering; severity low, effort S, risk low). Reject wasm64 at argument parsing with a diagnostic and drop the enum cases until implemented; delete WasmRuntimeAbi and its test line; remove `Reject` (or produce it where the code now throws strings); drop `simd`/`threads` from the config.
- **HlTypeDef is serialized or walked by five independent switch statements** (architecture; severity low, effort S, risk low). Have HlPatchWriter reuse HlWriter's type encoder for the kinds a patch allows (it already reuses HlWriter.encodeIndex and encodeFunction), and compute `hashTypes` over those encoded bytes instead of a parallel walk, if the runtime's hash definition allows; otherwise generate both from one field visitor on HlTypeDef.

### Type system and semantic analysis (`src/compiler/types`, `semantic`)

Scope is 108 files / ~34k lines. `src/compiler/types/` has three layers: root (type model `Type.hx` 62 lines, `TypedAst.hx` 513, `DeclarationIndex.hx` 1164, `TypeRelations.hx` 763, AST-level `SignatureInference.hx` 716 / `FieldInference.hx` 477), `typing/` (the typer: `BodyTyper` 2859, `ExpressionTyper` 2551, `CallResolver` 2403, `ProgramTyper` 1313, plus ~3.5k lines of helper generators such as `WireCodecGenerator` 1255 and `TypeRepresentation` 762) and `analysis/` (24 files; 17 are AST-only). `src/compiler/semantic/` holds three unrelated things: whole-program canonicalization and incremental invalidation (`SemanticAssembly` 1100, `ModuleCanonicalizer`, `ModuleAnalyzer`, `ModuleChangeAnalyzer`), the language-service index (`SemanticIndex` 1272, `SemanticWorkspace` 606), and core typer inputs (`SemanticProgram`, `SemanticSignature`, generic specialization policy).

Data flow: per-module AST -> `SemanticAssembly.run` (canonical whole-program AST + selected functions + purity facts) -> `SemanticProgram.analyze` (`SignatureInference`, `DeclarationIndex`) -> `ProgramTyper`/`BodyTyper` over one mutable `TypingSession` -> `TypedProgram` -> IR.

Health: the type model and typed AST are small, explicit and well documented, static mutable state is nearly absent (2 `static var`), and incremental bookkeeping (purity queries, anonymous units, retained specializations) is carefully reasoned. The typer itself is the weak point: local inference is syntactic look-ahead plus speculative re-typing with no unification variables, the sub-typers are wired together by 71 closures around a 53-field session, typing aborts on the first error, and `types` and `semantic` import each other freely. The typer also does lowering work (physical representation, closure cells, codec/equality generation), so IR and the driver reach into `types.typing` internals. One likely defect was found by reading only (not executed): AST copy sites that drop `inline`/metadata.

- **Local type inference is syntactic look-ahead plus speculative re-typing; there are no unification variables** (architecture; severity high, effort L, risk high). Add an inference variable to `CompilerType` (e.g. `TMono(ref)`), bind it in `TypeRelations` assignability/`coerce`, and let `var a = []` produce `TArray(TMono)` resolved at first use, with a post-body pass that defaults or rejects unbound variables. Migrate one case at a time (empty array literal first), deleting the matching look-ahead walker each time; keep `SignatureInference` only for what must be known before bodies are typed. Until then, make `speculativeValueType` catch `CompileError` only.
- **BodyTyper is a hub wiring five sub-typers through 71 closures over a 53-field mutable TypingSession** (architecture; severity high, effort L, risk medium). Replace the closures with one shared interface (or pass the `BodyTyper` itself typed as a narrow `TypingCore` interface with typeExpression/coerce/lowerType/findFieldType/arrayElementType) held by every sub-typer; delete the per-consumer callback typedefs. Move the duplicated type predicates to static functions on one `TypeShapes` class next to `TypeRelations` and a single `TypingErrors.fail`. Group `TypingSession` fields into owned sub-objects (helper requests, inline constants, key paths, incremental query records) with methods instead of public maps.
- **Hand-written AstFunction copies drop isInline / isExtern / metadata on 4 of 9 sites** (architecture; severity high, effort S, risk low). Add one helper in `compiler.syntax` (e.g. `AstCopy.functionWith(fn, {?name, ?arguments, ?result, ?statements, ?typeParameters, ?span, ?metadata})`) that copies every field, and use it at all nine sites and in `replaceBodies`/`withBody`/`copyWithMethods` instead of Reflect. Add a typer test with `inline`/`@:keep` functions that have inferred return types and an inline abstract method.
- **Typing aborts on the first error, and the language service compensates with a second approximate typer** (architecture; severity medium, effort L, risk medium). Give `TypingSession` a diagnostics sink and make the function the unit of recovery: `ProgramTyper` catches `CompileError` per `typeFunction`/field initializer, records it, and emits the function with an error body (or omits it) so the rest of the program is still typed; the build fails afterwards if the sink is non-empty. Then `indexRecoveredSyntax` only needs to cover functions that failed. Put the 30 codes in one enum abstract so messages and codes are listed in one place.
- **types/ and semantic/ depend on each other; semantic/ mixes three unrelated concerns** (architecture; severity medium, effort M, risk low). Move group (a) into `compiler.types` (`SemanticSignature` -> `types/TypeSignature`, `SemanticProgram` next to `DeclarationIndex`), and `astTypeName` to `compiler.syntax`. Split the rest into `compiler.assembly` (or `incremental`) for group (b) and `compiler.index` for group (c). Resulting order: syntax -> types -> assembly -> index/service, with no back edges.
- **ProgramTyper.typeProgramMeasured is a 430-line method with nine parallel helper-request queues and 16 cache branches** (architecture; severity medium, effort M, risk medium). Define one `HelperGenerator` interface (`pending():Int`, `generate(sink)`), register the generators in a fixed array, and replace the loop and the seven ordering blocks with one drain that runs until no generator reports pending work, emitting in registry order then name order. Split the method into `typeDeclarations` (fresh) / `reuseDeclarations` (cached), `typeBodies`, `drainGenerated`, `assemble`, with a small phase-timer object instead of 20 local timestamp variables.
- **IR generation and the driver depend on typer implementation classes for naming contracts** (architecture; severity medium, effort S, risk low). Collect the shared name functions and prefixes into one small module in `compiler.types` (e.g. `GeneratedNames`: enum runtime name/declaration, equals/hash names, key-path literal prefix, type-origin prefix) and move `nullableMapValue` to `TypeRelations`; IR and `FrontendCompilation` import only that. Move `FinalLocalChecker`, `BindingWalker`, `FreeVariables` and `AstScan` (AST-only) to `compiler.syntax` so the parser no longer imports types.
- **SemanticAssembly.run is one 806-line static function doing canonicalization, invalidation and purity drift** (organization; severity medium, effort M, risk medium). Split into three steps with explicit data between them: `CanonicalProgramBuilder.build(modules, names) -> {program, owners, generatedByModule, genericOrigins, reverseCalls}`, `ProgramFactsDrift.compute(program, cached) -> {facts, driftedFunctions}`, and `InvalidationSelector.select(changes, graph, drift) -> {selected, invalidations}`; `run` becomes the 30-line composition and keeps the timing fields.
- **types/analysis is mostly pre-typing AST passes, and several root files are not type-system code** (organization; severity low, effort S, risk low). Split `types/analysis` into `types/flow` (the 7 typed files) and `types/prepass` or `syntax/analysis` (AST-only). Rename `TypeRegistry` to `StableTypeIds`/`ClassLayoutRegistry` and move it next to `compiler.modules`; move `NativeTypeDescriptor*` to `compiler.ffi` or `compiler.runtime`. Rename `semantic.ProgramFacts` to `EffectFacts`.
- **Small unused or single-purpose surfaces: DeclarationLifecycle per-declaration state, Typer.typeSelected, AnonymousTypeRegistry instances** (overengineering; severity low, effort S, risk low). Reduce `DeclarationLifecycle` to a single program-level stage field on `SemanticProgram` (keep the ordered-transition check) until per-declaration stages are actually driven by the typer; remove `Typer.typeSelected`; make anonymous-type registration a method on `TypingSession` (`session.registerAnonymous(type)`) and delete the wrapper class.

### Frontend, driver and compiler service

Scope is about 18,000 lines. The centre is `src/compiler/Compiler.hx` (1,156 lines): the persistent incremental compiler that owns modules, type registry, FFI models, HashLink assembler, publication state and every session cache. A build runs `CompilationTransaction` -> `CompilationPipeline.compile` -> `FrontendCompilation.run` (1,648-line file) -> `BackendAssembly.assemble`, working on a copy-on-write candidate (`createCandidate` / `writableState` / `adoptCandidate`) reached through `CompilationContext`. `modules/` holds `ModuleState` (57 mutable fields per module), the reverse dependency graph, reachability, the source loader and the generated identity table. `syntax/` is a clean leaf with no upward imports: Lexer 421 lines, Parser 3,146 lines, ConditionalCompilation. `service/LanguageService.hx` (2,129 lines, 109 functions) wraps up to three `Compiler` instances for editor queries. `tools/` holds the product build path (`CompilerArguments` -> `CompilerRequest` -> `CompilerDriver` -> `CompilerSession`, with `CompilerServer` as the loopback worker) plus memory diagnostics. `formatter/` is a self-contained token formatter with a parser and token-preservation guard. Entry points are thin, except `src/Main.hx`, which is the test-program compiler.

Health: the transactional design is sound and unusually well documented, and `syntax/` and `formatter/` are in good shape. The weak spots are concentrated in orchestration:
- `FrontendCompilation.run` is one ~830-line function that also owns the IR pass order.
- `Compiler` state is enumerated by hand in five places, with a second, slower fork path used by `validate`.
- The driver is HashLink-centric, so Wasm builds still assemble a HashLink module.
- Target and define handling is stringly and copied across entry points, and has already diverged.
- A correctness workaround for incomplete shape invalidation lives in the CLI session and does not cover the language service.

Nothing was built or run; all claims come from reading and grep.

- **Compiler session state is enumerated by hand in five places, and validate() uses a second, cold fork path** (architecture; severity high, effort M, risk medium). Move the build-owned state into one SessionState object (modules, types, object caches, typed program, semantic program, ABI, inline/pipeline/lowered/reachability caches, declarationOwners, genericSpecializations, assembler). Give it copyForCandidate(), and make the Compiler hold a single reference, so adopt and restore become one assignment and the snapshot is that object. Reimplement validate() as createCandidate + FrontendCompilation.run(lowerToIr=false) without adopt, then delete fork().
- **FrontendCompilation.run is one ~830-line function that also owns the IR pass pipeline** (architecture; severity high, effort L, risk medium). Split run() into phase functions over an explicit per-build record: resolveGraph, assembleSemantics, typeProgram, publishModuleArtifacts, assembleIrInputs. Move lines 768-857 into an IrPipeline class in compiler.ir with one run(ir, profile, options) whose target differences come from TargetProfile. Record timings and allocation through one phase-scope helper instead of paired locals, and build FrontendResult once.
- **The build driver is HashLink-centric: Wasm builds still run a full HashLink assembly, and the Wasm backend runs outside the Compiler** (architecture; severity high, effort L, risk high). Parse the target once into the existing BackendTarget enum (compiler.backend.Backend) at CompilerArguments, and carry it on Compiler in place of defines.get("target"). Put a backend-session interface behind Compiler (assemble(ir, changes) -> artifact + ABI) with HashLink and Wasm implementations, so BackendAssembly is the HashLink one and Wasm builds skip it. Make CompileResult.module optional or backend-typed. First confirm what the Wasm path still reads from the HashLink assembly (functionIds and runtimeIdentity are used in the result) and supply those from the IR.
- **CompilerSession resets the whole session on typedef/enum/abstract edits, a correctness workaround outside the compiler** (architecture; severity high, effort M, risk medium). Move the decision into the compiler. Either finish alias/enum/abstract shape invalidation (ModuleState already has aliasFingerprints, enumFingerprints and abstractFingerprints) or, as an interim, have Compiler detect a structural fingerprint change during parse and invalidate dependents itself. Then delete hasStructuralDeclaration/structuralDeclarations and the two pre-scan loops. Add a warm-edit test that changes a typedef's shape and compares bytes with a fresh build, as Main --warm-edit already does for functions.
- **Source-to-AST preparation is hand-assembled at seven sites with different defines; LanguageService parses defines differently from Compiler** (architecture; severity medium, effort S, risk low). Add one syntax-level entry, e.g. SourceParser.parse(file, defines, recovering) returning {tokens, program, conditionalDefines, diagnostics}, and use it at all sites. Expose the compiler's active define map read-only (Compiler.defines is private) and delete LanguageService.editorDefines.
- **CompileMetrics is a flat 62-field record spelled out in five places** (overengineering; severity medium, effort S, risk low). Keep the counts and reuse fields as named fields; replace the 44 timing fields with phases:Array<{name:String, ms:Float}>, or extend PhaseAllocation with ms. Fill it from a phase-scope helper and have phaseReport iterate it; the cached-result path then returns an empty list.
- **src/Main.hx is the test-program compiler, wired differently from the product path** (organization; severity medium, effort M, risk medium). Rename and move it (e.g. tests/driver/ProgramCompilerMain or tools.dev) and have it build a CompilerRequest and go through CompilerSession/CompilerDriver with a plain or live flag. Keep --batch and --warm-edit as harness modes on top. If full driver output is too slow for the suite, at least share a single function that creates and configures the Compiler (target defines, stdlib root, intrinsics); that same setup is repeated in Main.hx:81-89, CompilerSession.hx:165-188, LanguageService.hx:220-223 and 259-262, and tools/AndroidBuild.hx:71-76.
- **Compiler embeds the FFI registry: 9 fields and about 180 lines unrelated to compilation state** (architecture; severity medium, effort S, risk low). Extract compiler.ffi.FfiRegistry, owning the nine maps, register/compose/abi/cNatives/sourceOrigin and a clone(). Compiler keeps `final ffi:FfiRegistry`, the two public add* methods with the compiledOnce freeze check, and the update() call for projected modules via a callback.
- **CompilationContext is a wide forwarding layer, and compilation/semantic/modules/service form import cycles** (architecture; severity medium, effort M, risk low). Once session state is one object (first finding), pass it directly and delete the property forwarders. Keep on the context only derived per-build services: ModuleAnalyzer, target profile, parse metering. Move CancellationToken/CancellationError to the compiler root package, where Diagnostic already lives. Give SemanticAssembly and CodeIdentityTable a small interface (writableState, parse, addTypeDependencies, identitySalt) declared in modules. Delete the dead explicitFunctionSignatures pair and prune CompilationPipeline's imports.
- **Debug and check switches are process-global state read mid-pipeline** (architecture; severity medium, effort S, risk low). Read the switches once into an immutable CompilerOptions/DebugOptions value at Compiler construction (checkReuse, explainInvalidation, earlyPrune, identityGraphPath, liveFieldReserve). Pass it through the context and include the relevant ones in environmentKey. Make IrPassMeter an instance owned by the build and returned in the metrics.
- **Package names in scope do not say what they hold; several files are dead or test-only** (organization; severity low, effort S, risk low). Rename compiler/tools -> compiler/driver (Arguments, Request, Driver, Session, Server, SourceManifestLoader) and gather the meters and censuses in compiler/diagnostics. Move ImportOrder/UnusedImports to a lint package or beside LintCommand. Rename compiler/runtime to something like compiler/runtimecontract, or fold it into abi. Delete WasmRuntimeContract. Delete BootstrapStatus and its script, or confirm someone still runs it. Have LanguageService call Formatter directly and point the tests at it. Keep Repl only if a REPL is planned; otherwise move it to tests.
- **ModuleState is a 57-field mutable record shared by every phase, and its commit steps are duplicated** (architecture; severity low, effort M, risk medium). Group the fields into per-phase immutable-by-replacement records (ParsedModule, ModuleFingerprints, TypedModuleCache, IrModuleCache, CanonicalModule), so copy() becomes five reference copies and a phase replaces its own record. Move markLastGood() onto ModuleState and the diagnostic copy-back into one shared helper used by both transactions.

### FFI and tools (`src/compiler/ffi`, `src/tools`, `lib`)

Scope: src/compiler/ffi (35 files, 11,790 lines), src/tools (20 files, 4,758 lines), two root mains (250 lines), lib/haxeon-io (2 classes, 249 lines), docs/C_HEADER_FFI.md (891 lines).

compiler/ffi holds two different products in one flat package. (1) The HXI consumer the compiler needs on every compile: HxiLexer/Parser/Model/Validator/Abi/Semantics, the projection planner/profile/emitter and NativeLayout (about 6.7k lines). Compiler.hx parses .hxi text, validates it, and HxiHaxeEmitter generates Haxe source modules plus IrCNative records; the typer uses NativeLayout and IrProgramAssembler uses HxiAbi. (2) An offline Clang-driven header importer and auditor (CHeaderImporter, Cxx*, Clang*, ProcessOutputCapture, HxiWriter, HxiAudit: 4,942 lines) reachable only from FfiImportMain/FfiAuditMain, which the build runs as `haxe --run FfiImportMain` via build/provider/FfiProvider. CHeaderEmitter is a third, unrelated thing (IR natives to an HL C header).

src/tools is HaxeonCli (1,590 lines, 19 subcommands), its helpers, a dev/ subfolder (format, suites, tool artifacts), and five more standalone entry points (Android*, LiveHost, FormatterTokenGuard).

Health: the HXI format, ABI classifier and validator are reasonably layered and well tested. The weak spots are concentrated: HxiHaxeEmitter is a 3,081-line god file with an 860-line function and a half-adopted planner; the C and C++ importers share a Clang front end but not AST helpers; the importer API is positional-argument sprawl; Compiler.hx carries the FFI registry inline; HaxeonCli has a second, legacy build path with its own haxeon.json parser; process capture is reimplemented at least seven times. The importer's size is proportionate to its feature list (C++ virtual dispatch, thunks, ownership), but it is in the wrong place and inflates the compiler's fingerprint.

- **HxiHaxeEmitter is a 3,081-line god class: source printer, IR native builder, naming policy and ABI descriptor encoder in one, with a planner it only half uses** (architecture; severity high, effort L, risk medium). Split along the seams that already exist: (a) HxiNaming (lines 51-170 and 2295-2490: identifier validation, projected names, enum prefixing) with no emitter dependency, so planner/validator/CxxProjection depend on it rather than on the emitter; (b) HxiAbiDescriptor (abiDescriptor/aggregateDescriptor/fieldDescriptors/project/irType, lines 2491-2605 and 2826-3081); (c) HxiCNatives for the IrCNative builder, driven from the same plan; (d) the emitter proper, split per declaration kind (structs, handles, enums, callbacks, function wrappers) and iterating plan.* instead of model.declarations. Make the plan carry the supported/unsupported decision and the signature string once so both outputs read it.
- **The offline Clang importer (4.9k lines) lives inside the compiler package and is fingerprinted and interpreted with the whole compiler source tree** (architecture; severity high, effort M, risk low). Move the importer side to its own package and root-level folder (e.g. src/ffiimport/ or src/tools/ffi/ with package tools.ffi), leaving compiler.ffi as the HXI consumer only (Hxi*, NativeLayout, NativeCallPlan). Have FfiProvider depend on a prebuilt importer artifact (the same tools.dev.ToolArtifacts mechanism the CLI already uses for HL-bytecode tools) or at least on the importer's own roots plus compiler/ffi, not on all of src. Move CHeaderEmitter (IrNative to hl.h header, used only by compiler/tools/CompilerDriver.hx) next to the HL backend or driver, since it is not FFI import.
- **The C importer duplicates the Clang AST helpers the C++ importer shares, and the two copies have diverged** (architecture; severity medium, effort M, risk medium). Make CHeaderImporter use ClangAstTools for all node/location/annotation helpers and delete its private copies, deciding explicitly (with a test) which isUserDeclaration and root policy is correct for both languages. Move the source cache into an instance owned by one import run.
- **Importer entry points take 10-17 positional parameters, and the CLI/manifest merge is a 170-line main with silently ignored options** (organization; severity medium, effort S, risk low). Introduce one FfiImportOptions structure (header, target, language, standard, clang, includes, defines, compileCommands, library, interfaceName, dependencies, excludedHeaders, cxx:{profile, trivialValues, lifetimes, virtualDispatch, thunks, selections, ownership}). Build it in one place from project.FfiManifest plus flag overrides, validate it there (the cross-option checks at FfiImportMain.hx:97-121), and pass it to both importers and HxiAudit. Either pass `standard` to the C frontend or reject --std for C.
- **FFI interface registry (9 maps, ~180 lines) is implemented inline in Compiler.hx, and interfaces are parsed twice** (architecture; severity medium, effort M, risk low). Extract compiler.ffi.FfiRegistry owning the nine maps, composition and ABI caches, exposing register/projections/cNatives/sourceOrigin; Compiler keeps one field and the two freeze checks. Give it a composed-interface value (model + omitted + visible declarations + abi + profile) that HxiProjection takes as one argument. Let the registry keep the parsed model from ordering so text is parsed once, move FfiInterfaceSource into compiler.ffi, and put a single `name` accessor in HxiModel.
- **The native-call descriptor wire format uses unnamed numeric type codes shared by string convention between the emitter and three backends** (architecture; severity medium, effort M, risk medium). Define the codes once as an enum abstract (e.g. compiler.ir.CNativeScalar with Void, I8, U8, ... Pointer, Bytes, Utf8, Bool) with helpers (size, isWide, wasmLetter) and one encoder/decoder for the descriptor string. Use it in HxiHaxeEmitter, WasmCAbi and HlLower, and replace the string-prefix check with a decoded result kind (ideally carried as a field on IrCNative rather than re-parsed from the signature).
- **HaxeonCli keeps a second, legacy build path with its own haxeon.json parser for wasm32 and Android** (architecture; severity medium, effort M, risk medium). Delete loadConfig/ProjectConfig and read everything from project.manifest (already resolved at line 633). Route wasm32 and the Android HLB compile through the structured build (BuildPlanner/HaxeonProjectBuild with a target), keeping only packaging/launch per target in the CLI. Compute `structuredHost` once. Split build() into parse/validate, per-target build, and launch; move Android packaging helpers (939-1068) to a tools.android module beside AndroidBuild/Patch/Reload.
- **Run-a-process-and-capture is reimplemented at least seven times, some with the classic pipe deadlock** (architecture; severity medium, effort S, risk low). Move ProcessOutputCapture out of compiler.ffi into a neutral package (e.g. build.execution or a small `host` package) as the single capture primitive, and replace the six ad hoc helpers with it (keeping ProcessRunner.run for streamed, environment-controlled execution). That also leaves exactly one place to adapt for the Haxeon stdlib's Process API.
- **Sixteen entry points are spread over four locations with no rule, and the FFI tools are not CLI subcommands** (organization; severity low, effort S, risk low). Group by product: tools/cli (HaxeonCli + its command and helper modules), tools/android, tools/live, tools/dev, and tools/ffi holding the two FFI mains as package-qualified classes. Expose them as `haxeon ffi import|audit` (thin delegation) so FfiProvider can invoke one launcher on every OS. Keep root-level mains to the long-lived services (Main, LspMain, EditorServiceMain).
- **Dead or single-valued projection abstractions: unused facade methods, an unused dispatch case, a two-case 'strategy' enum** (overengineering; severity low, effort S, risk low). Delete HxiHaxeEmitter.emit and NativeDispatch.IndirectPointer; drop ProjectedOutputStrategy in favour of hasOutputParameters; pick one name for NativeCallPlan/HxiFunctionAbi; make moduleKind an enum. Keep HxiProjection only if it becomes the real boundary (taking the composed-interface value proposed above); otherwise let Compiler call the planner/emitter directly and move `source` to a test helper.
- **docs/C_HEADER_FFI.md is 891 lines under four headings and opens with the C++ path** (organization; severity low, effort S, risk low). Reorder and add headings: Overview and pipeline (header -> HXI -> projection -> cNative), C import and annotations, HXI format, projection profiles (.hxmap), audit, project manifest recipes, C++ import (profiles, lifetimes, virtual, thunks, views), runtime/descriptor reference. Consider splitting C++ into docs/CXX_HEADER_FFI.md.

### Build, project, editor and LSP

Scope is about 14,000 lines: src/build (50 files, 5,330), src/project (25, 2,045), src/runtime (19, 1,239), src/editor (8, 3,720), src/profiler (6, 1,665) and a thin VS Code extension (2 TS files, 212 lines). Review was by reading only; nothing was built or run.

Build is a three-stage pipeline: BuildPlanner turns a ResolvedProject into a BuildPlan of artifacts, PlanLowerer plus providers (Compiler, Ffi, Runtime, NativeSources, NativeCMake) turn that into an ExecutionPlan, and Executor runs it with fingerprints, an artifact cache and a jobserver. The compile action talks to a resident per-project worker through CompilerClient (507 lines). src/project resolves haxeon.json into a package graph through pluggable source acquirers. src/runtime is the host API over the forked HashLink (Runtime, LoadedModule, PatchSet, RuntimeDomain) plus a C ABI bridge. src/editor holds two adapters over compiler.service.LanguageService: LSP (LspProtocol 1,562 lines, LspDispatcher, ProjectWorkspace) and a JSON-lines protocol. src/profiler is an HLDI client used only by editor/profiler, which is reached through LSP executeCommand.

Health: the execution layer and package resolver are solid and well commented. The weak points are structural:
- Three unrelated persistent-compiler front doors, with no shared snapshot between build/hot reload and the editor.
- Two independent translations of a project into compiler inputs, so LSP and build can disagree.
- A BuildPlan abstraction that lowering half-bypasses, with a ring of never-used enum values and seams around it.
- A build/project import cycle and an overloaded `runtime` package name.
- Long positional-boolean APIs and one god class (LspProtocol).

None of this blocks today's CLI workflow. The first two directly affect the roadmap's "diagnostics and completion come from the same compiler snapshot" goal for Pragtical.

- **Three persistent-compiler front doors with separate compiler instances and wire formats** (architecture; severity high, effort L, risk high). Make one per-project service process the owner of the Compiler: extend CompilerServer to host LanguageService queries alongside compile requests. Turn LspProtocol and LanguageServiceProtocol into thin adapters that connect to it, in-process for tests and over the socket otherwise. Keep one publication handshake (acknowledge/reject) and have LiveHost use it instead of the .live.refused file. As a first step, define the worker request and response types in one module imported by both CompilerClient and CompilerServer.
- **LSP and build translate a haxeon.json project into compiler inputs independently, and the LSP version is incomplete** (architecture; severity high, effort M, risk medium). Add a single function, for example `project.CompilerInputs.of(project, layout)`, that returns roots, package roots, FFI interface and projection paths, defines and target. CompilerProvider renders it to arguments and ProjectWorkspace feeds it to LanguageService.configure. Have the LSP resolve with ProjectSourceAcquirer and the lockfile in a no-network mode instead of PathSourceAcquirer.
- **BuildPlan is only half the source of truth; lowering goes back to the project and re-derives identities by string convention** (architecture; severity medium, effort M, risk medium). Give artifacts typed payloads (an enum per kind carrying the manifest data lowering needs) instead of a string map. Have PlanLowerer dispatch per artifact and return ActionIds through the existing artifactActions map; that map should be the only way to find another artifact's action, removing string reconstruction and the prefix match. Extract thunk compile and link into one helper used by both native providers.
- **Speculative values and seams in the build model that nothing uses** (overengineering; severity medium, effort S, risk low). Delete BuildIntent (or reduce it to what `haxeon check` will need, when it exists), HashLinkPatch, Executable, hashLinkPatchPath, BuildPlanner.module, ProjectManifest, ExecutionBackend with its factory and HAXEON_EXECUTOR, and build.native.NativeLibrary. Collapse NativeArtifactDemand to the Shared/Static cases actually requested. Re-add a case when a provider for it lands.
- **Long positional and boolean parameter lists on the build entry points** (architecture; severity medium, effort S, risk low). Replace these with option structs with defaults: a `ProjectBuildOptions` for build(), named fields or a builder for LoweringContext, and an `ActionPolicy` for ExecutionAction's flags. This is a mechanical refactor covered by tests/tooling/BuildSystemMain.hx.
- **build and project import each other; workspace manifest and Target live on the wrong side** (architecture; severity medium, effort M, risk low). Move Target, with its OS/arch/ABI enums, and a minimal process-capture helper into a leaf package that both import, so project no longer depends on build. Move WorkspaceManifest to project/ and rename one of the two concepts, for example package `members` versus build `workspace`.
- **`runtime` names three unrelated things, and src/runtime mixes host API, C ABI bridge and strays** (organization; severity medium, effort M, risk medium). Rename src/runtime to a host-specific package such as `haxeon.host`, keeping only the live-module API there. Move the C ABI bridge next to the FFI code or into a `nativecall` subpackage. Move ThreadName to a shared util package and LiveRefusal beside tools.LivePublication, or into the compiler's publication module. Do not let stdlib/runtime and src/runtime share a package name.
- **CompilerClient is a 507-line static class with five jobs and an untyped protocol duplicated on the server** (architecture; severity medium, effort M, risk medium). Split it into WorkerProtocol (typed request, response and state typedefs plus encode/decode, imported by both client and server), WorkerRegistry (state files, markUsed, retirement, stale cleanup; pure enough to unit-test) and WorkerLauncher (platform spawn). Keep CompilerClient.run as a short orchestration over them.
- **Two mechanisms for sharing a CMake tree, selected by nested ternaries in one provider** (architecture; severity medium, effort M, risk medium). Make the workspace build use NativeCache trees: same key, lock and publish into each project's native directory. Then delete `sharedNative`, sharedCMakeRoot, sharedName, sharedOutputDirectory and the ActionMerge.dedupe call, leaving two modes (cached, or per-package when the cache is off) behind a small `CMakeTree` value computed once.
- **LspProtocol is a 1,562-line class that owns every LSP feature and hosts the profiler** (organization; severity medium, effort M, risk low). Split by feature into handler classes that receive (service, documents, workspace): LspDiagnostics (push, pull and refresh state), LspSemanticTokens (snapshots), LspNavigation and LspEditing. LspProtocol keeps parse, dispatch and lifecycle. Register the profiler as a separate command provider on the dispatcher; longer term give it its own stdio endpoint so the VS Code panel can run without the language server. Share one JSON-field helper.
- **Small mechanisms copied instead of shared: library-path env, JSON field readers, process capture** (organization; severity low, effort S, risk low). Add `HashLinkPath.runtimeLibraryEnvironment(home)` returning variable and value, and use it at all 6 sites. Add one `project.JsonFields` reader (required/optional string, bool, array and map, with a path for messages) used by all manifest parsers including WorkspaceManifest. Route short captures through one helper, either HostCommand or ProcessRunner.capture, and correct the doc comment.
- **Misplaced and misleadingly named files in build/ and project/** (organization; severity low, effort S, risk low). Move HaxeonBuild to src/tools/dev (for example dev.BootstrapCommand); this means updating scripts/bootstrap-compiler.sh, scripts/test-driver.sh, SuiteRunner.hx:151 and check-self-hosting.sh:72. Rename project/FfiManifest.hx to FfiImportManifest.hx, or move the nested FfiManifest class and rename it PackageFfiSection. Rename ProjectDiscovery to say what it is (local, offline resolution) and drop the "compatibility" wording.

### Native runtime, stdlib and platform

Scope: native/ (9,031 lines of C: native/runtime.c is a 68-line unity-build umbrella that #includes 25 domain files; native/wasm is 214 lines), stdlib/ (148 .hx files, 12,778 lines), android/ (one Gradle app, 354-line JNI host, 156-line CMake), embed/ (a manifest that re-exports src), bootstrap/ (checked-in 18.5 MB compiler.hl), and six vendor submodules. Data flow: stdlib declares natives with @:hlNative (242 to "haxeon_runtime", 59 straight to HashLink "std"); the C runtime implements them on top of the forked HashLink (390 commits and about 29.5k inserted lines over upstream); Wasm instead uses `#if wasm` Haxe implementations in stdlib (87 sites in 41 files), compiler-emitted runtime code, and two small C modules committed as .wasm.

Health: the C runtime is well split by domain and has good single-sourcing precedents (value_lane_policy.h generated from IR, shared/sha256.h). The weak points are at the boundaries:
- The core runtime library compile-depends on the NativeKit UI submodule, which bootstrap does not initialize.
- The Android host re-lists HashLink sources by hand and has fallen behind three additions. I did not build it; this is from reading the source lists.
- Haxe-named std types (sys.io.Process, FileOutput) have non-Haxe APIs, which the self-hosting script already records as the reason three entry points do not build.
- sys.io.File and sys.FileSystem call into a build-cache recorder that is switched on by the program's own argv.
- stdlib/ has become the home for everything: Haxe std, compiler marker interfaces, an RPC framework with no consumer, build tooling, a test framework, and a `runtime` package that shares its name with src/runtime.
- There is confirmed dead weight: vendor/format (23k lines, no consumer) and 15 host primitives with no caller.

None of this needs redesign; most fixes are moves, deletions and one build-list unification.

- **Haxe-named std types expose non-Haxe APIs (sys.io.Process, FileOutput), blocking self-hosted entry points** (architecture; severity high, effort M, risk medium). **Fixed during the review by `028ce4fa`.** Make sys.io.Process a class with Haxe's surface (`new(cmd, ?args, ?detached)`, `stdout`/`stderr:haxe.io.Input`, `stdin:haxe.io.Output`, `exitCode(block)`, `getPid`, `kill`, `close`) built on the existing __process_spawn/__child_* primitives, which already stream. Make FileOutput/FileInput extend haxe.io.Output/Input and add File.append. Move the Haxeon-only extras (ChildProcess, AtomicFile, the blocking run/capture helper, StructBufferStorage) to haxeon.io / haxeon.sys, then delete the `#if haxeon` branch in ProcessOutputCapture and cut the entry_gaps list.
- **Core language runtime compile-depends on the NativeKit UI submodule, which bootstrap never initializes** (architecture; severity high, effort S, risk low). Move native_trace.c out of haxeon_runtime into a NativeKit-side unit (packages/platform or a small haxeon_nativekit_trace hdll loaded with NativeKit), calling the already public hl_prof_span_begin/end from hlprof.h. If it must stay, guard the include with a HAXEON_WITH_NATIVEKIT define set only when the submodule is present. Either way drop vendor/nativekit/include from CMakeLists.txt:73.
- **Android host re-lists HashLink sources by hand and has fallen behind the fork (by inspection)** (architecture; severity high, effort M, risk low). Have the fork's CMake export the embeddable pieces once (an option such as HL_EMBED_VM that defines static targets libhl and hlvm from its own source variables) and make the Android CMake `add_subdirectory(vendor/hashlink)` and link those targets instead of listing files. Add a compile-and-link-only NDK job to CI. Fix the nativekit include as in the previous finding.
- **sys.io.File and sys.FileSystem call into a build-cache recorder that is activated by the program's own argv** (architecture; severity medium, effort S, risk low). Replace the hard dependency with an observer seam owned by the file layer: one nullable static (for example `haxeon.io.FileObserver.current`) that File/FileSystem test and call. Move InputFiles (244 lines) to the build tooling (src/build or a lib/ package), have it install itself explicitly from the tools that want recording, and parse the flag there instead of inside std.
- **vendor/format: 23k lines of vendored Haxe code with no consumer** (overengineering; severity medium, effort S, risk low). **Check first:** two submodules use a `format` haxelib. Delete vendor/format. If a HashLink bytecode reader in Haxe is wanted again, keep only format/hl (4 files) beside the tool that uses it, or use the fork's own tools/hldump.c, which already reads the v7 format.
- **haxeon_runtime mixes five roles in one library; host_state.c carries 15 primitives with no caller** (architecture; severity medium, effort M, risk medium). Either wire host_state.c to its intended consumer (the compiler server) or delete it; if an out-of-tree project uses it, move it to that project's hdll. Keep the unity build, but give it three umbrellas and libraries: haxeon_runtime (language core), haxeon_host (module_runtime plus host utilities, loaded only by embedders and the service) and haxeon_ffi (native_call plus libffi, loaded when a program declares FFI). Move the profile, thread and GC primitives out of files.c into system.c or a profile.c.
- **Native binding contract is declared in three styles and hand-expanded per arity** (organization; severity medium, effort M, risk low). Put each DEFINE_PRIM directly under its HL_PRIM (the HashLink convention, already used in regex.c and dir_watch.c) and delete bindings.c. Generate all seven arity families and the 12x10 typed-map primitives with one X-macro each. Bind stdlib directly to "std" where the wrapper adds nothing (socket send_char/listen/bind and similar) and keep wrappers only where they adapt (String marshalling, sockets init).
- **Every FFI call resolves its target by three strcmp over a spin-locked linked list** (architecture; severity medium, effort M, risk medium). Resolve once per call site: have lowering allocate a module global per FFI call site that holds the resolved haxeon_native_function abstract, and pass that handle to the invoke primitive, so the string-keyed lookup runs only on first use or after a library reload. As a smaller first step, replace the list with a hash table keyed on the three interned pointers and drop the per-call string copies.
- **stdlib/ has become the home for frameworks, tooling and internals next to Haxe std** (organization; severity medium, effort M, risk medium). Keep stdlib/ to Haxe std plus the compiler-coupled Haxeon core (wire codecs, reactive, markers). Move haxeon.rpc to packages/ (or delete it until it has a consumer), haxeon.build and haxeon.test to lib/ beside haxeon-io, and the Wasm host artifacts to a non-source directory such as native/wasm/dist. Rename the stdlib `runtime` package to `haxeon.internal` (updating the hard-coded names such as "runtime.Ryu.format" in WasmLinearRuntime.hx:4393 and WasmGcRepresentation.hx:2015). Consider moving the marker interfaces under `haxeon.` with root typedef aliases.
- **utest lives in three places: a stdlib reimplementation, a mandatory submodule used only by a manual probe, and a single-use compiler metadata** (organization; severity low, effort S, risk low). Move stdlib/utest to a package (packages/utest or lib/utest) that projects opt into. Drop vendor/utest from Bootstrap.cmake's init list; the probe script already checks for it and prints the init command. Keep @:discoverMethods as the documented stand-in for build macros, and note in the compiler that it is expected to be removed once macros exist.
- **stdlib provenance and behaviour docs are stale; runtime symbols still carry the old project name** (organization; severity low, effort S, risk low). Regenerate the UPSTREAM.md rows from the files that carry the Haxe Foundation header (a small check script can fail when a headered file has no row), fix the EReg and Math descriptions, and restore the upstream regex in haxe/xml/Printer.hx. Rename the internal `realtime_` C helpers to `haxeon_` in one mechanical pass; the exported primitive prefix can change at the next bootstrap refresh, since the compiler and runtime are rebuilt together.

### `packages/ui`

packages/ui has 911 tracked files (904 outside the 7 vendor submodules: harfbuzz, clay fork, nanovg fork, skribidi, sheenbidi, libunibreak, budouxc). It has three layers:

- **Native C++ (`src/`, 45 files, 20.8k lines):** text preparation, the Clay layout backend, display lists, compositor and renderer, exposed through `include/nativekit_ui*.h` and one 5,486-line `src/api.cpp`.
- **Bindings (`bindings/`):** generated `.hxi` FFI interfaces plus 64 hand-written wrappers in the flat `haxeon.ui` package (4.1k lines).
- **Haxe framework (`haxe/haxeon/ui/**`, 359 files, 44.4k lines):** core 10.2k, widgets 20.3k across 12 subfolders, style 3.9k, host 2.1k, and smaller model packages (docking, properties, settings, editing, semantics, animation, gestures, theme, debug, lab).

Around that sit 12.9k lines of Haxe tests, about 20 C++ test files, 50 scripts in `tools/`, a 7k-line showcase and 5.5k lines of docs. Data flows View -> `BuildContext` -> `RenderNode` tree -> `LayoutTransaction` -> native layout session -> render plan -> `nkgpu`.

Health is mixed. The widget layer is reasonably factored (shared `BinaryControl`, `SelectionPopup`, `Virtual*`), global mutable state is minimal, and verification is strong. The engine core is not in good shape: `UiContext` and `BuildContext` are god objects carrying two component models mid-migration (ADR 0002), `api.cpp` has two largely duplicated frame paths, core imports upward into debug, widgets and editing, and the test harness is a 7.5k-line monolith plus hand-rolled scripts.

The package took 345 of 1,294 repo commits since 2026-10-15, yet ROADMAP.md and docs/ARCHITECTURE.md never mention it. About 7k lines of application kits have no consumer in the repo besides tests. It is useful as a large Haxeon-only dogfood program, but it competes with the compiler roadmap for attention.

- **UiContext and BuildContext are god objects; the custom-paint cache is 12 parallel maps** (architecture; severity high, effort L, risk medium). Extract a CustomPaintCache with one record object per node id (canvas, list, geometry, key, revision, bound flags, composite sub-record) in a single Map<Int, PaintEntry>. Move verifyRetention, fingerprints and checkUnannouncedEdits to a RetentionVerifier. Move timing and allocation bookkeeping to a FrameMetricsRecorder with begin/phase/end calls. Split submitFrame into named phases (decide reuse/patch, build, diff, native layout, collect). In BuildContext, separate identity and key scopes from the update scheduler.
- **Two component models coexist; the new one is used by only two library widgets** (architecture; severity high, effort L, risk medium). Treat the migration as a bounded task with an explicit port list: the 8 selfUpdating widgets, the 4 willEditRetained widgets, then the context.state callers. Delete each old mechanism in the same commit as its last caller. If the migration is to be paused for compiler work, record that in the ADR and stop adding scope features until the port resumes, so the dual state does not grow.
- **api.cpp is a 5,486-line translation unit with two largely duplicated frame render paths** (architecture; severity high, effort M, risk medium). Split api.cpp by family into api_resources.cpp (handle tables), api_text.cpp, api_layout_session.cpp (with hit testing in its own file) and api_renderer.cpp. Extract the shared frame frontend (command resource resolution, path/texture preparation, glyph binding, seal, submit) into one function in src/render/ that takes a plan source, and have both entry points call it.
- **Package consumes about a quarter of repo activity but is absent from the roadmap; app-level kits have no consumer here** (organization; severity high, effort M, risk medium). Decide and write down the package's role. Recommended: keep the engine (native, bindings, core, style, base widgets) in-repo as the large Haxeon dogfood and benchmark corpus, and add a ROADMAP section stating what UI work is allowed before the Pragtical gates. Move the application kits (docking, properties, settings, plotting, sidebar, lab) to a separate package or to the application repo that uses them. Replace the root tests' reach into packages/ui paths with small fixtures under tests/, or declare those files a stable test corpus.
- **core depends upward on debug, widgets, component and editing** (architecture; severity medium, effort M, risk low). Delete the dead imports. Move ScopeView into core (it is the core's mount contract). Move Utf8Text and TextInputWindow to a base text package below core, or into core. Have installHistoryCommands live in editing (taking a CommandRegistry) instead of CommandRegistry importing editing. Move FrameworkErrorView to widgets and inject it into core as a factory. Keep the metrics value types core needs in core and leave the inspector and audit in debug behind a hook.
- **FrameworkSmoke.hx is a 7,457-line test with a 3,795-line run() function** (organization; severity medium, effort M, risk low). Split by subsystem (typography/style, events/focus, commands/history, docking, scroll, semantics, sidebar, text input) into separate entry points using the tests/<name>/haxeon.json pattern that 18 directories already follow. Keep a thin aggregate runner for CI.
- **Three test harness styles; 18 scripts hand-assemble compiler command lines** (organization; severity medium, effort M, risk low). Add one tools/run-project.sh <test-name> to replace the 6+ identical scripts. Add one sourced helper (or a `haxeon build --project` target-matrix option) that yields the roots, FFI flags and memory contract for hl, wasm32 and wasm-gc, and have the parity scripts call it. Group tests/haxeon fixtures into subfolders by area (scope, retained, allocations).
- **Feature code is split inconsistently between model packages and widgets/, with name collisions and forwarding shims** (organization; severity medium, effort M, risk low). Use one folder per feature (docking/, properties/, settings/, plotting/, sidebar/, commands/) containing both model and view, and keep widgets/ for generic controls. Rename widgets/text/EditTransaction to TextEditTransaction. Delete the 6 alias files and import haxeon.editor directly; no consumer outside this package exists in the repo.
- **haxeon.ui.lab (ComponentLab) has no users; the showcase implements its own component explorer** (overengineering; severity low, effort S, risk low). Either delete haxeon.ui.lab and the README section, or rebase the showcase explorer and its visual cases on ComponentStoryRegistry so there is one catalog definition. With no in-repo consumer, deletion is the cheaper choice.
- **DesktopUiHost.open is one 650-line function built from closures over about 30 locals** (architecture; severity low, effort M, risk medium). Turn the locals into fields of a DesktopUiHostSession implementation class with methods (pump events, frame, finish), and move event/frame recording and scripted input into two small collaborator classes owned by it. UiHostRuntime stays as the part shared with the browser host.
- **Reference docs are mixed with measurement logs; README sections do not match their content** (organization; severity low, effort S, risk low). Reduce README to package integration plus a layer map with links. Move the layout bridge, custom paint and virtualization text into docs/LAYOUT.md and docs/RENDERING.md. Move dated measurement logs (VALUE_TYPES, RENDER_COST, LAYOUT_COST, text-editor-performance) into docs/history/, as the root docs/ already does.

### Other packages

Scope: nine packages under /home/joao/dev/haxeon/packages (ui excluded), about 44.7k tracked lines, of which about 21k are generated .hxi bindings. All of them date from 2026-10-05 or later.

Layering is a clean DAG: platform (52 managed files over NativeKit FFI, 14.5k lines of generated bindings) is the base; gpu, audio, credentials, filesystem and agentkit-nativekit depend on it; editor (1.4k lines of source), agentkit (1.1k) and animation (managed part) are headless and dependency-free; ui consumes platform, gpu and editor. Managed code is uniformly `haxeon.<name>.*` over generated `nativekit.ffi.*` modules. The individual packages are small and readable; agentkit and filesystem/credentials are tidy.

The weak part is everything around the code:
- **Tooling:** three test-layout conventions, three ways to provision the native library, and two binding-regeneration script styles. The script named `check-hxi.sh` overwrites the checked-in binding.
- **Test coverage:** the gpu and platform tests bypass the manifest system with hand-listed sources. Six of nine packages have tests that no CI job or script runs.
- **Consumers:** agentkit, agentkit-nativekit, animation, credentials and filesystem have no consumer in this repo. They serve external applications (Materia, Exosuit), not the Pragtical roadmap.
- **Layering leaks:** the base packages name upper-layer, example-app and out-of-repo classes in `@:allow`.
- **Docs:** packages/README.md omits credentials and filesystem.

Overlap with the rest of the repo is nominal. `src/editor` is the compiler's LSP/profiler service (package `editor`), unrelated to `haxeon.editor`'s text model. packages/filesystem is a root-confined capability API, not a duplicate of stdlib `sys.FileSystem`.

Overall: code health is good; build, test and packaging conventions are inconsistent, and several packages are unverified in CI.

- **check-hxi.sh regenerates the checked-in binding in place, so test runs hide ABI drift** (architecture; severity high, effort S, risk low). Give every binding one script with the platform contract: `update-hxi.sh [--check]`, where --check writes to mktemp and diffs. Have test scripts and CI call it with --check. Remove or rename the writing check-hxi.sh. Either check in a gpu -wasm.hxi and compare it, or drop the uncompared abi32 generation.
- **gpu and platform tests bypass haxeon.json and hand-list source files** (architecture; severity high, effort M, risk medium). Add packages/platform/tests/haxeon.json and packages/gpu/tests/haxeon.json that depend on the package manifests. Reduce each test-haxeon.sh to a native build plus `scripts/haxeon run --project` (keep the exit-code-42 check). Make audio's script use its existing tests/haxeon.json. Declare the vulkan interface in the platform manifest, or split it into an optional manifest.
- **Six of nine packages have tests that nothing runs** (organization; severity high, effort S, risk low). Add one CI job (or a scripts/test-packages.sh) that loops over packages/*/tests/haxeon.json and runs `scripts/haxeon build`. Run the headless ones (agentkit, editor; filesystem too, since it only needs its small native module) and build-only those that need devices or secrets. This depends on the manifest-based tests from the previous finding for platform and gpu.
- **Base packages grant @:allow to upper-layer, example-app and out-of-repo classes** (architecture; severity medium, effort M, risk medium). Replace the friend lists with explicit, documented low-level entry points: for example a `haxeon.platform.internal`/`interop` module exposing `GraphicsImageRef.fromBorrowedHandle`/`nativeHandle` and an `EventPump.createDetached()` for hosts that own their loop, and a public `TextDocument.storage()` accessor in an `internal` subpackage. Delete the RenderTarget and Showcase* entries.
- **Three native-provisioning conventions and three test layouts across nine packages** (organization; severity medium, effort M, risk low). Pick one convention and write it in packages/README.md: managed package plus optional sibling `native/` provider manifest (the audio/animation style, which allows shared providers), tests in `tests/` with a haxeon.json, import header in the package's `bindings/`. Add a platform native provider so platform and gpu are buildable from manifests. Migrate credentials and filesystem (2 files each).
- **13 near-identical ffi-audit wrapper scripts repeat the target matrix and flags** (overengineering; severity medium, effort M, risk low). Move the invocation into one shared script (for example scripts/haxeon-ffi-binding) driven by data: interface name, library, import header, dependency hxi, profile. Ideally read these from a small `ffi.audit` block in the package's haxeon.json, with `--check` and `--abi32` modes. Per-package scripts become one-liners or disappear.
- **haxeon.editor mixes a text-document model with 3D viewport lighting presets that nothing consumes** (organization; severity medium, effort S, risk low). Move ViewportLook to the repo that uses it (Materia/SceneKit), or to a `haxeon-viewport` package if it must live here. Rename packages/editor to `text` (`haxeon.text.*`) so it is distinguishable from src/editor. Keep typedef shims for one release, as ui already does for these types.
- **UI keeps seven compatibility shims over haxeon.editor types** (overengineering; severity low, effort S, risk low). Have ui code import haxeon.editor types directly and delete the six shim files. If external apps still use the old names, keep only typedefs (turn the TextOffsetMap subclass into a typedef) with a removal date.
- **Five packages have no in-repo consumer and their real tests live in other repositories** (architecture; severity medium, effort M, risk medium). Decide per package: (1) keep it as a compiler-conformance corpus, which means it must be in CI (see the test finding) and listed in packages/README.md; or (2) move application libraries (agentkit*, animation, and likely credentials) to the repos that consume and test them, depending on Haxeon by path. At minimum, add credentials and filesystem to the README table and state each package's owner and consumer.
- **Magic numbers duplicate generated FFI constants in the thin wrappers** (architecture; severity low, effort S, risk low). Use the generated constants and enum abstracts (NativeKitFilesystemConstants, FileSystemEntryKind, the HTTP client flag constant). Share one `FileSystemError.check(status, op)` helper within the package.

### Tests, scripts and build system

Scope: tests/ (about 1480 files), scripts/ (55), CMake, hxml, benchmarks/, examples/, .github/.

Test execution is layered: scripts/test.sh or gate.sh -> scripts/haxeon (bash; builds the CLI with stock Haxe) -> `haxeon dev test <mode>` (src/tools/dev/SuiteRunner.hx, 467 lines) reads tests/suites.txt (78 suites; groups quick/wave/ci; lanes and pools) and runs each as a bash command. The largest suite, scripts/test-driver.sh -> build.HaxeonBuild test -> interpreted tests/driver/TestDriver.hx, runs a second registry (tests/driver/TestCatalog.hx): 277 named mains, 86 executable cases, and 591 programs from tests/programs/expected-exits.tsv, each built live, plain and unpruned. Wasm coverage is two bash scripts of 1029 and 1196 lines. Native code is built by CMake presets (out/cmake/<preset>), located through cmake/hashlink-output-paths.txt.

Health: the newest layer is well designed and documented (suites.txt, the content-hashed tool cache, per-suite output directories, case sandboxes, the validated program manifest). The weak points are around it:
- The driver takes 1114 s in the one recorded gate run (out/gate/d0d554cd-quick-20261115-130125, exit 1 with 3 driver failures); 751 s of that is 277 separate stock-Haxe builds of the compiler.
- Only programs have a registration check. 28 integration scripts, 12 hxml files and 2 compiler mains are run by nothing, including the DAP, compiler-server and build-executor tests.
- CI, `test.sh` and `gate.sh full` each run a different set of gates, and CI runs three Wasm suites twice.
- About 84 scripts hand-roll the environment preamble that scripts/lib/env.sh already provides.
- The self-hosting procedure, the CLI cache and benchmark placement are each duplicated.

Nothing blocks the roadmap, but the unregistered tests and the gate mismatch weaken the incremental, hot-reload and self-hosting priorities.

- **Named test mains are 277 separate stock-Haxe builds of the whole compiler (two thirds of driver time)** (architecture; severity high, effort M, risk medium). Generate a small number of shard entry points (for example 8 to 16, grouped by the existing directory and topic) whose main dispatches on argv[0] to the named main. Build each shard once through ToolArtifacts (src/tools/dev/ToolArtifacts.hx) and keep running every case as its own process: `hl shard.hl <MainName>`. One process per case keeps the isolation TEST_SUITE_COST.md worried about, so only static initializers are shared; check that on a sample first. Unlike a compile server, the shards stay deterministic fresh builds. Move the HaxeMain executable cases onto the same shards.
- **No registration check outside tests/programs: 28 integration scripts, 12 hxml files and 2 compiler mains are run by nothing** (architecture; severity high, effort M, risk low). Add a registration check next to the program one: every tests/integration/test-*, tests/wasm/test-*, tests/hxml/*.hxml and tests/{compiler,runtime,tooling,profiler}/*Main.hx must be named in suites.txt, in TestCatalog, in another registered test, or in an explicit `tests/unregistered.txt` with a reason (manual, needs gdb or npx, known broken). Then triage the 28 scripts: register those that pass, list the manual ones with reasons, delete the dead ones.
- **CI, `test.sh` (ci mode) and `gate.sh full` run three different sets of gates; three Wasm suites run twice in CI** (architecture; severity high, effort S, risk low). Make suites.txt the only list. Add self-hosting-fixed-point, bootstrap-self, haxeon-cli, hot-reload, gdb-hot-reload (requires=gdb) and wasm-gc-chrome (requires=chrome) as suites, using the existing `requires=` mechanism. Delete the three duplicate Wasm steps and the standalone steps from ci.yml so that non-Windows CI is tool setup plus `scripts/test.sh`.
- **About 84 scripts hand-roll the root, HashLink path and library path preamble that scripts/lib/env.sh provides** (organization; severity medium, effort M, risk low). Extend env.sh into the single preamble (root, haxe, hl, library path, suite output, a `haxeon_tool MAIN` wrapper around tool-path, a free-port helper) and migrate tests/integration mechanically. Once the scripts write to haxeon_suite_out and take a port from the helper, put the 15 profiler suites and the python suites into pools.
- **The Wasm test scripts are monoliths with hand-kept fixture lists and a 700-line JavaScript heredoc** (organization; severity medium, effort M, risk medium). Move the JS host into checked-in modules under tests/wasm/host/ (tests/runtime/run-equality-guard.js and wasm-arena-host.js already set the pattern). Move the fixture, exports, flags and inline-mode table into a data file beside expected-exits.tsv. Have the test driver run the generic 'every manifest program on wasm32 and wasm-gc' loop as another program-run mode, so it shares batching, per-case reporting and filtering. Keep bash only for the backend-specific checks.
- **Seven Haxe mains exist only to shell out to bash scripts, because the driver catalog has no script case** (overengineering; severity medium, effort S, risk low). Delete the seven wrappers and list the scripts in tests/suites.txt in a `pool=gc` (their native builds already go to per-run temporary directories). If they must stay inside the driver for its sandbox, add a `Script(path)` CompileStep to TestCatalog instead of compiled forwarders.
- **The DAP and HLD3 scripts build HashLink through a second path and overwrite the CMake-built runtime in out/** (architecture; severity medium, effort M, risk low). Port the ten scripts to scripts/build-native.sh and hashlink-path.sh, and have them write nothing under out/ except their suite directory. For native probes, add an EXCLUDE_FROM_ALL `haxeon-test-probes` target to tests/native/CMakeLists.txt that builds the probes used by registered suites, so flags come from the preset; keep ad hoc `cc` only for one-off bench experiments.
- **The self-hosting fixed point is implemented twice, in bash and in Haxe, with different source sets** (architecture; severity medium, effort S, risk low). Keep one implementation in build.HaxeonBuild: add a `self-check` command that runs seed, stage 1 and stage 2 without touching bootstrap/compiler.hl, sharing bootstrap()'s loop and sourceManifest(). Reduce scripts/check-self-hosting.sh to a call to it. Move the entry-gap list and the equality guard into separate suites in suites.txt.
- **Two content-hash caches for the same CLI, plus a fake `haxe` shim to reach one of them** (overengineering; severity medium, effort M, risk medium). Have integration scripts call one launcher, `scripts/haxeon` (or `haxeon_cli` from env.sh, which honours the pinned CLI), instead of `haxe --run tools.HaxeonCli`. Then delete test-cli-launcher.sh, the `cli-launcher` option and HAXEON_REAL_HAXE. Let scripts/haxeon skip its hash when the runner has exported a pinned CLI, so the fingerprint is computed once per run.
- **Benchmarks are split across benchmarks/, tests/bench/, scripts/benchmark-* and tests/profiler with no rule** (organization; severity low, effort S, risk low). Move tests/bench/* and the scripts/benchmark-*, measure-cold.sh and benchmark-compare.py drivers into benchmarks/<topic>/ (driver next to template), and leave scripts/benchmark.sh as the one entry point. Merge the three interface-dispatch benchmarks into benchmarks/interface-dispatch.
- **CMake presets that the path table and scripts cannot find** (overengineering; severity low, effort S, risk low). Either make hashlink-path.sh and HashLinkPath read HAXEON_CMAKE_PRESET (falling back to the platform default) and list every preset in hashlink-output-paths.txt, or delete the dev and macos-arm64 presets together with the environment variable. In both cases write the default-preset choice once, in the txt file, and have the bash and Haxe lookups read it.

### Documentation

Scope: docs/ holds 85 top-level Markdown files (18,118 lines) in one flat ALL_CAPS folder, plus docs/adr (5 ADRs, 2,557 lines) and docs/history (3 files, 3,472 lines); README.md (203), ROADMAP.md (109), TODO.md (66) and NOTICE (6) sit at the root. There is no docs index; README links 11 documents and "More design notes -> docs/".

Classification, from each file's title, status line and opening (not every document was read in full):
- About 30 current references (CLI, DEVELOPMENT, LANGUAGE_SUPPORT, LIVE_PATCHING, WASM_BACKEND, C_HEADER_FFI, PROFILING, format specs).
- About 22 design notes, proposals and plans (STRUCTS, WARM_REBUILD_REUSE, REACHABILITY_WALK, INTERNED_NAMES, FRONTEND_RESTART).
- About 27 one-off measurement or experiment reports, several of them rejected experiments (GC_*, JIT_*, *_PROFILE, FASTA_*, BOUNDS_CHECK_ELIMINATION).
- 6 branch handoff notes (WORLD_*, MAIN_COMPATIBILITY_HANDOFF, WAMR_PROFILE_HANDOFF).

Health: content accuracy is better than the layout suggests. A scan of backticked compiler class names across all docs found 4 that no longer exist, and the 17 symbols and switches ARCHITECTURE.md names all exist in src. The "no code yet" design notes are still truthfully unimplemented. ROADMAP's "ten paired programs" matches tests/differential.

The real problems are status and navigation:
- Status headers contradict their own bodies (ADR 0003, WARM_REBUILD_REUSE, IR_PASS_INVENTORY).
- Two wire-format references carry old version numbers.
- Haxe-compatibility gaps are tracked in four places that already disagree.
- ARCHITECTURE.md does not map src/.
- The September Pragtical plan contradicts ROADMAP.
- Reference, plan, report and handoff documents are indistinguishable by location.

Paths are relative to /home/joao/dev/haxeon.

- **Flat docs/ mixes references, proposals, experiment reports and handoffs with no index or status taxonomy** (organization; severity high, effort M, risk low). Split by document kind and add docs/README.md as the index: docs/reference/ (user and contract docs: CLI, LANGUAGE_SUPPORT, LIVE_PATCHING, WASM_BACKEND, C_HEADER_FFI, ANDROID, NATIVE_MEMORY, KEY_PATHS, ITERATION, PROFILING, MESSAGEPACK, RPC, the format specs), docs/design/ (live design notes and proposals, each with a mandatory 'Status: proposal | in progress | landed | superseded' first line), docs/reports/ (dated measurement and experiment reports, named YYYY-MM-topic, never edited after acceptance), docs/adr/ (unchanged), docs/history/ (superseded plans and handoffs). Keep ARCHITECTURE.md and DEVELOPMENT.md at docs/ top level. Update the links in README and ROADMAP and the 9 or so code and script references (STRUCTS.md has 10 inbound, REACHABILITY_WALK.md 9).
- **ADR 0003/0004 status says 'nothing implemented' while ARCHITECTURE.md records M0 and M1 as landed** (organization; severity high, effort S, risk low). Change ADR 0003's status to 'Accepted; M0 and M1 landed (see ARCHITECTURE.md), M2+ pending' and add a one-line landed/pending marker per migration step. ADR 0003:349-350 already says current state lives in ARCHITECTURE.md, so keep the ADR to decisions plus a status table and nothing else. Do the same check for ADR 0004 and 0005 each time a step lands.
- **Plan documents double as changelogs and their status headers contradict their bodies** (organization; severity medium, effort M, risk low). For each landed plan: move the normative result into ARCHITECTURE.md or a docs/design/ note written in present tense, move the dated log to docs/history/<topic>-2026-11.md (the pattern already used for history/ir-pass-inventory-2026-11.md and history/structs-measurements-2026-11.md), and fix the status line. Start with WARM_REBUILD_REUSE.md, IR_PASS_INVENTORY.md, PROVIDER_REQUESTS.md and PROVIDER_INVENTORY.md; split ADR 0002's migration log out of the ADR.
- **ARCHITECTURE.md does not describe the src/ layout or anything outside the compiler pipeline** (organization; severity medium, effort M, risk low). Add a 'Source map' section to ARCHITECTURE.md: one row per top-level src/ folder and per src/compiler subfolder (purpose, entry type, allowed dependencies), the five entry points (Main, LspMain, EditorServiceMain, FfiImportMain, FfiAuditMain) and one line each for stdlib/, packages/, native/, vendor/hashlink, bootstrap/. Move 'Performance rules for compiler code' (:111-133) to DEVELOPMENT.md, where contributor rules already live.
- **Haxe-compatibility gaps are tracked in four places that already disagree with each other and with the stdlib** (organization; severity medium, effort S, risk low). Make LANGUAGE_SUPPORT.md 'Not yet supported' the single list. ROADMAP section A and LANGUAGE_ROADMAP 'Other Haxe compatibility gaps' link to it instead of restating items; TODO.md keeps only items with design content (enum abstracts as TAbstract, event signal, HTTP server, BLAKE3, shader generator) and drops the Type.getClassName line. Fix the three mismatches above; rewrite ROADMAP section C's layout bullet to say what still reloads (field type change, base or interface change, reserve exhausted).
- **Format references carry old wire versions: PATCH_TRANSACTIONS says HLP 7, code is 11; HLB_DEBUG_SECTIONS says HLB 7, code is 8** (organization; severity medium, effort S, risk low). Merge the three into one docs/reference/FORMATS.md (HLB sections, HLI, HLP, HLD3) with a version-history table per format, and add to the doc comment on HlPatchFormat.VERSION and HlCode.VERSION a line naming that file as the place to record each bump. Verify the section kind:version pairs (1:1, 2:2, 3:1) against vendor/hashlink/src/code.c while doing so; I did not check those.
- **PRAGTICAL_CONVERSION_PLAN.md is a September plan that contradicts ROADMAP on the project's primary goal** (organization; severity medium, effort S, risk low). Fold the still-useful parts (stage 4 plugin-first exit gate, the Plugin interface sketch, the 'no layer may become a second typechecker' rule at :27-33) into ROADMAP.md 'Next' and 'Definition of Pragtical-ready', then move the file to docs/history/pragtical-conversion-plan-2026-09.md.
- **Six branch handoff notes for external consumers live as top-level docs** (organization; severity medium, effort S, risk low). Move the API facts from the two descriptor handoffs into MESSAGEPACK.md and STRUCTS.md, then move all six to docs/history/ with dated names. Verify first whether the WAMR profile and fuel ABI landed on main (I did not check) and, if it did, document it in WASM_BACKEND.md.
- **User-facing docs still present '@:value @:repr("C") class' as the native record form while STRUCTS.md says 'struct' replaces it** (organization; severity medium, effort S, risk low). Update README.md:78, NATIVE_MEMORY.md, LANGUAGE_SUPPORT.md:120 and TODO.md:59 to the struct spelling, with one sentence in NATIVE_MEMORY.md that the @:value forms are deprecated pending removal. Extract a short 'Structs' user reference from the 1,592-line STRUCTS.md so the language feature has a document that is not an implementation log.
- **CLI.md is 390 lines with one section heading and omits three dispatched commands** (organization; severity low, effort S, risk low). Add one '##' section per command group (project and dependencies, build and run, watch and live, fmt and lint, package and publish, diagnostics: doctor, platforms, devices, heap, identity-path) with a command table at the top generated from or checked against HaxeonCli.usage(); link 'dev' to DEVELOPMENT.md.
- **Docs reference agent names, gitignored evidence paths and other repos' scripts; file naming is inconsistent** (organization; severity low, effort S, risk low). Replace 'dev-71' with 'approved <date>' or drop it; state in reports that out/ evidence is local and not retained (or commit the small result tables inline, as most already do). Rename to PROFILER_DESIGN.md, PROFILER_DESIGN_POSIX.md and PROFILING.md during the restructure, and retitle DEVELOPMENT.md:3.
