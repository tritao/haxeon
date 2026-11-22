# IR pass inventory and pass interface (ADR 0003, M2)

Status: proposal; the pass order of the frontend is in one place (`compiler.ir.pipeline.IrPipeline`), the per-pass interface below is not
written yet. Since 2026-11-19 it is built on the query engine ([QUERY_ENGINE.md](QUERY_ENGINE.md), ADR 0003 M4a): `view`
is the engine's read interface, and contributions, summaries and rewrites are query kinds. Builds on section B of [`WARM_REBUILD_REUSE.md`](WARM_REBUILD_REUSE.md) (pass interface, name families,
file:line evidence). This document adds the measured edit-build cost per pass and proposes the order and the per-pass interface.
Out of scope: the Wasm builders' own internal passes (ADR 0004 moves the runtime library code, so they will change first).

## Internal marker migration (a1)

These unchecked families encode compiler meaning in names today. Each family must move its producers and consumers together;
the boxes are checked only when the string representation and its parser are gone. Ordinary source names and diagnostic
interpolation are not markers.

- [x] Closure adapter and cast signature hashes: linear Wasm uses planned signature IDs for linkage, and the verifier reads
  declared adapter, cast and varargs kinds and their semantic types instead of parsing hashes from names.
- [x] Function origins and scalar ABI eligibility: typing and generated IR functions declare their roles, and one shared
  predicate selects the shared and Wasm ABIs, including their distinct nullable-scalar and closure-restoration boundaries.
- [x] Value-array slot markers: opaque linkage IDs identify helpers, while declared operations carry the element type,
  slot, path, carrier status and optional-check operands; the verifier and IR codec use those declarations.
- [ ] Other value-array element, factory, bridge and place-method names (`$value-array:`). Deferred: do when this code is next touched.
- [ ] Scalar word and lane pack/unpack, lane runtime/storage and HL scalar references (`$word:`, `$lane:`, `$lane-runtime:`,
  `$lane-storage:`, `$hl:scalar-*`); receiver and reference checks. Deferred: do when this code is next touched.
- [ ] Scalar arguments/closures and Wasm scalar return, result, rethrow, function and closure-restore markers.
  Deferred: do when this code is next touched.
- [x] Enum box/view/unbox/tag markers: typed operations carry the enum or tag type; checked adapter roles carry the
  tag type and direction, and opaque linkage IDs replace the encoded descriptors. Array bridges request their tag
  adapters when they are created.
- [ ] Other enum test, equality/reflection, inline enum and specialization markers. Deferred: do when this code is next touched.
- [ ] Value dynamic and interface box/unbox/type-test, typed interface dispatch, checked casts and generic erasure markers.
  Deferred: do when this code is next touched.
- [ ] Optional field/value/scalar and nullable scalar helper markers, including wrappers and call boundaries.
- [ ] Typing-generated flags, raw-representable, equality/hash, wire/JSON, key-path and receiver-readonly markers; runtime
  type dependencies and fresh-constructor markers where consumed as compiler metadata. Deferred: do when this code is next touched.
- [ ] Wasm GC holder/place and lane-storage markers, and backend-generated array accessors and runtime names that are parsed.
  Deferred: do when this code is next touched.

Canonical IR serialization must change version with the typed representation. Generated symbols may still need unique
linkage names, but compiler decisions must use declared data rather than recover meaning from those names.

The slot migration's self-hosted compiler has SHA-256
`12df28aa6ac2103d009ffa69c4f7efc69f64e12806e17ba6a43279c9f9564a2c`, compared with
`8dfd1ea68c163cb035fb6acfda615772a01038e7ab4ea0bc7e7d864e482c66e3` before the migration.
The compiler changes are the typed operations, their verifier and codec, shifted helper-class field/method indexes,
and generated enum equality for the new role and operation enum. Nine generated slot functions are renamed; their
instruction bodies match. In `struct-array-places`, 11 caller bodies change only slot-call names, and the 31 old and
31 new slot helper bodies match as a multiset. Source snapshots and source-derived debug sections change with the code.

Before rebasing onto upstream's enum-size batch, the enum migration's self-hosted compiler had SHA-256
`d91a7ed8ae62a2276c9b0184b2b0a2fae23ad57b25e323c7f80a4ecc36e53bc1`, compared with the slot migration above. This is the pre-rebase comparison.
After matching the old and new helper symbols by their declared signatures, 6,793 normalized function bodies are
identical. Of the changed functions, 321 differ only in 1,683 method-table indexes: 1,056 calls on `IrBuilder`, 623 on
`CfgBuilder`, and four on `WasmGcContext` move by one when their new methods are added. Four codec functions change
their version constants. The remaining 51 functions implement or consume the new operations and roles, generate or
verify their helpers, or reflect the added payload-free typing roles; enum Dynamic dispatch and its type-test helper
visit the same descriptors in type order instead of hash order. Fourteen old function signatures disappear and 19 new
ones appear, including the removed name encoders, new typed builders and adapter request, and functions whose signatures
carry the new data. Adapter ID planning preserves existing roles when new enum specializations appear and avoids occupied
symbols. The string/type/global/function/constant tables change by +59/+13/+30/+5/+25 entries respectively; integer,
float and native counts are unchanged. Function identity, opcode span and source snapshot sections change from
1,079,960/23,437,284/5,337,080 bytes to 1,078,070/23,484,210/5,348,579 bytes respectively, reflecting renamed helpers,
changed instructions and the edited compiler sources.

## Roadmap and ownership (2026-11-11)

One list for the marker migration above and the work of ADR 0003 section 13. Owner is the driver; branch is where the work is
committed; status is `done`, `active` or `queued`. The declaration model it rests on landed with the merge of `a1-internals` into
`warm-rebuild-reuse`: one declaration per function (`IrFunction.kind`; a function that serves an operation on a type is
`Provider(subject, operation)`), `provides` as a read-only view of it, one `withBlocks`, one scalar-ABI predicate
(`IrScalarAbiEligibility`), and typed operations in instructions instead of request records or name-encoded calls.

| Item | Owner | Branch | Status |
| --- | --- | --- | --- |
| Closure adapter and cast signatures; function origins and scalar-ABI roles; value-array slot declarations; enum box, view, unbox and tag operations | a1 (Codex, driver dev-18) | `a1-internals` | done (checked above) |
| The five deferred marker families in the checklist above: other value-array names (`$value-array:`), scalar word/lane and HL scalar references, scalar arguments/closures and Wasm scalar markers, other enum/inline-enum/specialization markers, value dynamic/interface/typed-interface/checked-cast/generic-erasure markers; plus the optional, typing-generated and Wasm GC families | a1 | `a1-internals` | queued, each family when its code is next touched |
| Value-array names and the runtime-array native registry | a1 | `a1-internals` | queued |
| Enum-pass consolidation: a phase-order document first (reviewed by dev-71 before code), adapter escapes expressed as typed operations | a1 | `a1-internals` | active: phase-order proposal for dev-71 review |
| Typed dynamic sites: producer and backend boundary proposal | a1 | `a1-internals` | active (claimed 2026-11-12) |
| Wasm GC closure adapters as IR | a1 | `a1-enum-producer` | active (claimed 2026-11-12) |
| Value-constructor destination through the scalar ABI: design note for dev-71 review | a1 | `a1-value-constructor-design` | active (claimed 2026-11-13) |
| Documentation cleanup into `docs/history/` | a1 | `a1-internals` | done (2026-11-12) |
| §13 reachability walk over declared providers, pruning before the passes, one frontend pass | dev-c5 | `warm-rebuild-reuse` | queued; waits on the §13 design decisions |
| Warm-rebuild correctness: the edit sweep, the shared-helper origin (`docs/design/HELPER_OWNERSHIP.md`) | dev-c5 | `warm-rebuild-reuse` | active |
| Engine core (ADR 0003 M4a, [QUERY_ENGINE.md](QUERY_ENGINE.md)), then the M2 framework on it and the (a) ports of step 2 | haxeon-e4 | `main` | active (claimed 2026-11-18, reordered 2026-11-19) |
| Cold-build performance and the measure and gate scripts (`scripts/perf-guard.py`, `scripts/test.sh --gate`) | dev-c5 | `warm-rebuild-reuse` | active |
| The provider model itself (`IrFunctionKind`, `ProviderOperation`, the provider table and its checks); a1 adds families to it, changes to the model go through dev-c5 | dev-c5 | `warm-rebuild-reuse` | active |
| HashLink allocator refill path: word-at-a-time scan of the mark bitmap in `flush_free_list` (fixed-class pages), then the TLAB run size; both measured with cold builds of the app (`scripts/measure-cold.sh`, since removed) | dev-c5 | `haxeon/flush-word-scan` in `vendor/hashlink` (off 875bc1d25) | active (claimed 2026-11-11) |
| ADR 0003 section 13 step 3: design note for the type-aware reachability walk over typed operations and provider kinds (reviewed by dev-71 before code) | dev-c5 | `warm-rebuild-reuse` | written: `docs/design/REACHABILITY_WALK.md`, awaiting dev-71 review |
| The text of ADR 0003 section 13 | dev-71 | `adr-compiler-architecture` | follows the model above |

Rules both drivers follow:

- Claim an item before starting it: a committed line in this table changing its status to `active` with the driver's name.
- Merge `main` into the working branch daily.
- Push only at green gates (`scripts/test.sh MODE --gate`; the summary file it writes is what a report quotes).
- Message the other driver before touching an area they own.

## Outer gate control evidence

The outer app comparison had three matching control failures: the cosmetic-thread material rebuild, CAD collision
bounds and panel-flows inspection-camera label. The rebased editor and Web comparisons retained identical normalized
functions; the exact allocation windows matched. One-shot typing and memory measurements were noisy under concurrent
builds. The complete control, per-run measurements, module hashes and accepted baseline messages are preserved in the
[November 2026 gate history](../history/ir-pass-inventory-2026-11.md).

On outer `8ced7e09a`, the app suite also stopped at `Worker document tests failed: schema v17 is unsupported;
expected v18`. The same message occurs with the unchanged `124b72aa0` control compiler in the same outer worktree;
the candidate and control logs are `q3-outer-logs/app-tests.log` and `q3-outer-logs/control-app-tests.log` under
`/media/joao/DATA1/haxeon-a1-gates/`. The remaining outer gates were run separately: retention and budgets encountered
the previously recorded `Inspection camera ignored its view label` baseline, and the headless-only check passed.
On the updated outer base `60d9d4c36`, the app suite passes, including with its test temporary directory under
`TMPDIR`; retention and budgets still report the inspection-camera baseline, and headless-only passes. The logs are
under `/media/joao/DATA1/haxeon-a1-gates/q3-outer-60d-logs/`.

## Measurement

### Typer stabilization worklist (2026-11-16)

On compiler `17a459977`, a temporary probe timed the initial runtime-type drain and the first and subsequent passes of
`ProgramTyper`'s request-stabilization loop. Three cold compiler self-build pairs used Haxeon-built control and probe compilers,
the measurement and heavy-build locks, and the a1 heavy marker. Pair-start loads were 2.86, 2.43 and 2.81; process snapshots
showed no other active build at those starts (other processes were not monitored continuously). Outputs were byte-identical.
Control/probe median wall times were 12.07/12.08 s, peak RSS 1,411,512/1,412,344 KiB, and typing time 2,087/2,102 ms.
The probe reported three passes in each run: first passes took 14.08–14.18 ms, and subsequent passes 9.97–10.49 ms
(median 10.39 ms, 0.49% of median probe typing time). Subsequent-pass time includes useful newly requested generation, so it
is an upper bound on the work a worklist might avoid. The paired results show no measurable probe perturbation at this resolution.

An editor measurement could not be completed on the available outer revisions. In a disposable outer checkout, the existing
one-line `HttpHeader` to `NativeHttpHeader` port was applied solely for this measurement; no outer branch was changed. Outer
main `e1766d192` then failed with `app/BimModelEditor.hx:150:5: E1026` on `Button.selected`. The Button-port revision
`5f40717a4` instead failed with `app/EditorPerspectiveViewport.hx:2040:22: E1005`: the null check on `sensor.reading` no longer
holds after a possible mutation. The newer outer revision `d428464e3` requires the unpublished `haxeon.ui.core.RootInputs`
API and failed with `E2001`. No editor timing is claimed. Raw timings and diagnostics are in
`/home/joao/dev/materia-cache/haxeon-a1-gates/typer-final/results/`.

**Decision:** skip the typer worklist for now: the measured subsequent-pass upper bound is well below the approximately 10%
threshold. This decision is based on the self-build alone under the approved editor-build fallback; revisit if a compatible
editor measurement or later profiling shows a material cost. The measurements do not isolate the cost of any temporary
structure, so they do not justify removing scaffolding.

App edit build (one-line edit in `src/Main.hx` of the app, after a cold build and two no-op builds in the same worker), pre-merge
tree `0405feb5` (the merge changed the app's API, so the app does not build on it). A temporary probe sampled the allocation counter
between pass boundaries (object counts, not time; the probe was removed). Raw rows: `/media/joao/DATA1/warm-prof/passalloc-keep.txt`.
The IR-assembly phase of that build allocates 123.1M objects (216.5M in the cold build).

**Finding 1: apart from the inliner and the verifier, every pass allocates exactly as much in the edit build as in the cold build.**
The two builds differ in 625 retyped functions out of about 34 000, and no pass notices. Together these passes are 87.5M of the
123.1M (71%). The inliner and the verifier already memoize (91.3M to 31.2M and 32.8M to 4.2M).

**Finding 2: a floor of about 3.4M objects per pass.** `EnumDynamicDispatch`, `ValueDynamicDispatch`, `ValueInterfaceBoxes`,
`TypedInterfaceDispatch` and `CheckedDynamicCasts` allocate 3.38M to 3.49M each although they change a handful of functions. That is
17.1M (14% of the build) for five passes that do nothing in the edit case. The likely cause is a per-pass walk of every instruction
with a temporary per instruction plus a name map of all functions (`IrCheckedDynamicCasts.rewrite` builds `known` from every
function name); I have not profiled it. If it is one shared helper (instruction iteration), fixing it is a day of work and removes
most of those 17M before any pass is ported.

## Edit time on the compiler's own sources (2026-11-18)

A Haxeon-built compile server (release) compiling the compiler: cold 19.2 s, no-op 1.3 s (IR and module reused), a one-string edit
in `Lexer.hx` 6.7 to 7.3 s with 5 functions retyped. CPU samples of that edit: the assembly stages take 40%, the target stages 26%,
the HashLink backend 18% (already incremental), typing 5%. The passes rerun over all ~8,200 functions; per stage, in seconds:

| stage | s | stage | s | stage | s |
|---|---|---|---|---|---|
| inlineEnums | 0.58 | entryPrune | 0.23 | enumSpecializations | 0.13 |
| verifier | 0.30 | enumDynamicDispatch | 0.20 | genericOwnerErasure | 0.12 |
| runtimeSurface | 0.29 | closedEnumTagAbi | 0.19 | assemblyEnumTagEscapes | 0.12 |
| valueArrayRewrite | 0.28 | enumTagLowering | 0.18 | enumTagEscapes | 0.09 |
| inliner | 0.25 | scalarArguments | 0.18 | valueDynamicDispatch | 0.08 |
| dispatchWalk | 0.25 | nullableScalarFlow | 0.14 | valuePhiScalarization | 0.08 |
| | | scalarClosures | 0.14 | the rest | under 0.08 each |

No stage dominates, so the gain comes from the framework applied to many passes, not from one port: an edit should rerun each
pass on the changed functions and the cone its summary reaches, and reuse the rest. The first no-op after a cold build also
reran everything, because a warm build lists one fewer anonymous type (`reused: none (environment: reflectable
-$anon:{bytes:Bytes,tag:Int})`); that is a typer fix, handed to its owner.

## Classes

- **(a) local**: the rewrite of a function reads only that function (and the target profile). A cached result is valid while the
  function object is the same.
- **(b) local plus a summary**: the rewrite reads the function and a small program summary computed from per-function
  contributions and the object/interface/enum tables. Generators of helper functions belong here: the helper set is a function of
  the summary.
- **(c) global**: the rewrite needs other functions' bodies, or the summary is a fixpoint over a call-dependency graph.

`IrInlineEnumRequests` is transitional: delete it together with the whole-program enum rescans when enum operations are
resolved at the reviewed backend boundaries in [the phase-order plan](ENUM_PASS_PHASE_ORDER.md).

## Per pass

Edit cost is allocations in the edit build; share is of the 123.1M. Order is by that cost, which is also the order of ports below.
The "label" of a measured span can cover two passes where the code runs them back to back.

| pass | class | summary (what it is a function of) | the rewrite may read | edit cost | share |
|---|---|---|---|---|---|
| IrInliner | (c), memoized | per callee: transitive dependency list (`InlineMemo.dependencies`) | callee bodies, object table | 31.2M | 25.4% |
| IrScalarClosures | (b) | set of scalar closure function types, from all bodies and natives, minus excluded | existence of the `$scalar-arguments:` clone of a closure target | 11.2M | 9.1% |
| IrEnumRuntimeSpecializations + IrInlineEnumLowering (+Eligibility, Escapes) | (b) | concrete enum specializations; `allowed` enums = union of per-function escape facts, closed over the type graph | method signatures | 11.2M | 9.1% |
| IrScalarArguments | (c) | `candidates`: functions whose value arguments/results travel as scalars; greatest fixpoint over the call graph | callee candidacy, signatures | 9.2M | 7.5% |
| IrValueArrayProgramRewrite | (b) | concrete value-array element types (objects, enums, interfaces, statics, natives, all bodies) | place-method bodies (cloned), helper bodies inlined by `ScalarLowering` | 8.7M | 7.1% |
| IrScalarReplacement | (a) | none | none | 7.6M | 6.1% |
| IrNullableScalarFlow | (c) | `candidates`, pruned by trial rewrite until stable | callee candidacy | 5.7M | 4.7% |
| IrVerifier (verification, not a rewrite) | per-function memo, done | reads recorded through `IrVerifyTable`s | tables | 4.2M | 3.5% |
| IrValueConstructors | (b), bounded | small `.new` value constructors (<= 16 blocks, <= 64 instructions) | the bodies of those constructors (inlines them) | 3.7M | 3.0% |
| IrEnumDynamicDispatch | (b) | enum box descriptors; `needsEqual/Reflect/Compare` flags merged from per-function call names | bodies only for reachability pruning of `$enum-reflect-equals:*` | 3.5M | 2.8% |
| IrValueInterfaceBoxes | (b) | value objects with interfaces and the implementation signatures | signatures | 3.5M | 2.8% |
| IrTypedInterfaceDispatch (`rewriteValueCalls`: (a); `generate`: (b) generator) | mixed | helper set = f(`$typed-interface:` names) | signatures | 3.4M | 2.8% |
| IrCheckedDynamicCasts | (a) | none (helpers keyed by type) | names | 3.4M | 2.7% |
| IrValueDynamicDispatch | (b) | suffix set from value objects and `$value$equality:` names | names only | 3.4M | 2.7% |
| IrOptionalFieldStorage + IrNullableScalarFields | (b) / (a) | `plans` from the object table only | value-method bodies (cloned per owner/field/path) | 3.0M | 2.4% |
| IrValuePhiScalarization (twice) | (a) | none | none | 2.4M + 0.9M | 2.6% |
| runtime-surface detection and the rest of `assemble` | (b) | which runtime helpers any call needs (a union of per-function facts) | none | 2.2M | 1.8% |
| IrObjectReflection.generate | (b) generator | helper set = f(declared natives, reflectable objects) | signatures | 1.9M | 1.5% |
| IrOptionalScalarFlow + IrOptionalValueFlow.addHelpers | (c) fixpoint + (a) generator | `candidates` = greatest set such that each `eligible(fn)` holds given the others | callee bodies (`snapshotOnlyReceiver`), method resolution | 1.0M | 0.8% |
| IrStaticNullChecks | (b) | functions reachable from `__init` (call graph) | bodies of the reachable functions | 0.4M | 0.3% |
| IrGenericOwnerErasure.generate | (b) generator | helper set = f(call names, objects) | callee signatures | 0.01M | 0.0% |

Counting the table's rows, about 7 passes are (a), 12 are (b) and 4 are (c) (`IrInliner`, `IrScalarArguments`, `IrNullableScalarFlow`, `IrOptionalScalarFlow`; the
last three are the candidate-pruning fixpoints). The inliner is already memoized and is left for last.

Note on `IrValueConstructors`: it is "global" only in that it inlines small constructor bodies. It is (b) if the summary is the set of
small constructors with their bodies as contributions and the rewrite reads the summary instead of other functions.

## Interface

The interface of B.1 stands; this section fixes the rules a port must follow.

```
Pass<C, S>
  contribution(fn, view)      -> C     // optional; per function, cached by function identity, plain data
  summarize(contributions, tables, view) -> S   // optional; small, comparable by value
  rewrite(fn, summary, view)  -> IrFunction     // same object when nothing changes
  helpers(summary, view)      -> Array<IrFunction>
```

1. **What `rewrite` may read.** Its own function, the target profile, the program tables through `view`, and the summary fields it names.
   Never another function's body: a body that is needed becomes a contribution (a small value) of that function.
2. **What is recorded.** Every `view` read records `(query, digest of the answer)`. A cached rewrite is reused while its function is
   the same object and every recorded answer is the same. A read of a summary field is per key (a closure type, a candidate name), so
   one new key does not rerun every function.
3. **Summary type per class.**
   - (a): none; the cache key is the function plus the profile key.
   - (b): a value type of the pass: a set of names or types, or a map from name to a small record (for example `ScalarClosureSummary
     {closureTypes: Set<IrType>, excluded: Set<String>}`). Comparison is structural. An unchanged summary reuses every rewrite.
   - (c): `candidates:Map<String, Bool>` plus the dependency edges recorded while deciding each candidate. An edit re-decides the
     changed functions and the functions whose recorded reads include them (the cone); if a decision flips, the readers of that function
     are re-decided. A flip is the true cost of the semantics, not an artifact. The removal loop reads candidacy only through the view,
     so the cone is complete.
4. **Tables.** A pass names the tables it changes (objects, interfaces, enums, statics, natives). The change is part of its summary,
   not a side effect on a shared array. The ones that push into input arrays in place today (`IrValueInterfaceBoxes`,
   `IrOptionalScalarFlow`, `IrTypedInterfaceDispatch.generate`, `IrGenericOwnerErasure.generate`, `IrObjectReflection`) change with their port.
5. **Check mode.** `--check-reuse` recomputes every reused rewrite, contribution and helper and compares with
   `HlFunctionEquality`-style structural equality; it names the pass, the function and the first differing instruction.
6. **Unported passes** run as one opaque step with the whole program, so every commit is correct.

## Order of ports

Superseded for the engine (2026-11-19, [QUERY_ENGINE.md](QUERY_ENGINE.md) step 4): a pass only gets reuse once every
stage before it keeps unchanged functions as the same objects, so ports go in pipeline order from the front. The order
below by edit cost remains the measure of what each port is worth.

By edit cost, with what must come first:

0. **The 3.4M floor.** Profile one of the five passes in finding 2 and remove the shared cause. No interface needed; up to 17M (14%).
1. **The framework commit**: the interface, the view, the opaque step, check mode. No pass moves in it.
   Landed in part: `compiler.ir.pipeline.IrPipeline` runs every frontend pass as an opaque, named stage in one ordered list per phase
   (`assembly`, `target`), with the target differences as stage predicates and the pass meter and the early prune's
   check hooks as stage properties. The interface, the view and the reuse check mode of rule 5 are still to come; the Wasm builders'
   passes are outside the lists.
2. **IrScalarReplacement and IrValuePhiScalarization** (a): 7.6M + 3.3M. They are the cheapest to port (no summary) and they follow
   the other passes' changes, so porting them first is the proof of the cache key, the unchanged-returns-same-object rule and check mode.
3. **IrInlineEnumLowering + IrEnumRuntimeSpecializations** (b): 11.2M. The summary is the `allowed` set (union plus one closure over
   the type graph); the escape facts are per-function contributions.
4. **IrScalarClosures** (b): 11.2M. Depends on `IrScalarArguments` clones existing: its read of "the clone exists" is the first use of a
   per-key summary read.
5. **IrScalarArguments** (c): 9.2M. The first cone fixpoint; the hardest port. Done after 2 to 4 so its re-clone and re-SROA loop can
   call ported passes.
6. **IrValueArrayProgramRewrite** (b): 8.7M.
7. **IrNullableScalarFlow, IrOptionalScalarFlow** (c): 5.7M + 1.0M; they reuse the mechanism of step 5.
8. **The dispatch and helper-generating passes** (b): `ValueConstructors`, `EnumDynamicDispatch`, `ValueInterfaceBoxes`,
   `TypedInterfaceDispatch`, `CheckedDynamicCasts`, `ValueDynamicDispatch`, `OptionalFieldStorage`, `IrObjectReflection`,
   `IrGenericOwnerErasure`, runtime-surface detection, `StaticNullChecks`: 2% to 3% each; their gain is that the helpers become derived from
   summaries. If the floor of step 0 is fixed, the remaining edit cost of these is small, and they can be ported by need (name
   families, M3) rather than by cost.
9. **IrInliner** last: it moves onto the shared view and `IrInlineCache.memo/cleaned/instrumented` are deleted. Its 31.2M is the
   largest single item, but it already memoizes, so the question is why 625 changed functions cost 31M; that should be profiled
   before the port (the span also holds the per-build setup: object table, fingerprints, cleanup of every function).

## Open questions

- Is the 3.4M floor one shared helper? (Step 0 answers it.)
- The inliner span: how much of its 31.2M is per-build setup that scales with the program, not with the edit?
- `IrStaticNullChecks` keeps its own `__init` reachability fixpoint (`IrInitializationCalls`); is that a (c) pass or a (b) pass over a
  call-graph summary? Its cost (0.4M) does not decide the order, but the interface does.

## Enum escape reach and array factories

`IrEnumEscapeReach` owns the transitive storage reach used by
`IrInlineEnumEligibility`, `IrClosedEnumTagAbi` and reflected Dynamic descriptor
registration. It follows class and anonymous record fields, inherited interfaces and fields, registered reflection layouts,
static fields, containers, erased map contents and closure environments. The
callers supply their escape roots and whether a verified callable adapter covers
a value boundary; none maintains a second reference-reach traversal. Opaque
native handles are reference leaves at the native ABI; a reflective root reaching an erased map
through a field follows the indexed contents and captured receiver types.

`IrArrayFactory.NAME` is a typed logical allocation intrinsic. Its output carries
`Array(element)` directly; it has no Dynamic temporary or descriptor. After
storage selection, lane factories consume requests for their shapes and the
ordinary factory emits the physical allocator. Closed tags therefore request an
I32 allocation at emission, without matching an allocation/cast instruction
sequence. Ordinary checked reference allocations acquire their descriptors only
when that physical factory is emitted. The interpreter executes the typed
intrinsic directly; standalone backends use the same physical factory on an
immutable program view if no frontend lane pipeline has run.

The reach query memoizes value and reference shapes independently, indexes static
fields by owner and map writes/captured receivers by their semantic carrier, and
shares inherited-interface indexes across queries. A 32-level diamond value graph
checks that shared children are visited once rather than expanded per path.

**a1 debt:** runtime array natives still lack declared operation roles.
`IrArrayRuntimeNatives` is the single exact-name registry used by enum escape
classification and tag escape adaptation; unknown names are never exempted by
a prefix. Replace this registry with native roles when the runtime-surface
migration reaches arrays.
