# IR pass inventory and pass interface (ADR 0003, M2)

Status: proposal, no code. Builds on section B of [`WARM_REBUILD_REUSE.md`](WARM_REBUILD_REUSE.md) (pass interface, name families,
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
| Enum-pass consolidation: a phase-order document first (reviewed by dev-71 before code), adapter escapes expressed as typed operations | a1 | `a1-internals` | queued |
| Documentation cleanup into `docs/history/` | a1 | `a1-internals` | queued |
| §13 reachability walk over declared providers, pruning before the passes, one frontend pass | dev-c5 | `warm-rebuild-reuse` | queued; waits on the §13 design decisions |
| Warm-rebuild correctness: the edit sweep, the shared-helper origin (`docs/HELPER_OWNERSHIP.md`) | dev-c5 | `warm-rebuild-reuse` | active |
| Cold-build performance and the measure and gate scripts (`scripts/measure-cold.sh`, `scripts/gate.sh`) | dev-c5 | `warm-rebuild-reuse` | active |
| The provider model itself (`IrFunctionKind`, `ProviderOperation`, the provider table and its checks); a1 adds families to it, changes to the model go through dev-c5 | dev-c5 | `warm-rebuild-reuse` | active |
| HashLink allocator refill path: word-at-a-time scan of the mark bitmap in `flush_free_list` (fixed-class pages), then the TLAB run size; both measured with `scripts/measure-cold.sh` | dev-c5 | `haxeon/flush-word-scan` in `vendor/hashlink` (off 875bc1d25) | active (claimed 2026-11-11) |
| ADR 0003 section 13 step 3: design note for the type-aware reachability walk over typed operations and provider kinds (reviewed by dev-71 before code) | dev-c5 | `warm-rebuild-reuse` | active (claimed 2026-11-11) |
| The text of ADR 0003 section 13 | dev-71 | `adr-compiler-architecture` | follows the model above |

Rules both drivers follow:

- Claim an item before starting it: a committed line in this table changing its status to `active` with the driver's name.
- Merge `main` into the working branch daily.
- Push only at green gates (`scripts/gate.sh`; the summary file it writes is what a report quotes).
- Message the other driver before touching an area they own.

## Outer gate control evidence (2026-11-10)

On outer `haxeon-a1-outer` commit `c78fa7163`, the app suite built with a1 fails in
`CosmeticThreadTests` with `Uncaught exception: appearance edit rebuilds the child's material`.
The unmodified `origin/main` compiler `fcfd253bd1c8ea4b50921bc08cec0a885ad94171` cannot compile
that outer project or the isolated cosmetic test: `app/CncProgramPlayer.hx:744:96: E1009: Type mismatch
for argument 1 to "robotkit.execution.ProcessEventValue.Analog"`.

As a diagnostic, the same origin compiler with only the abstract-to-Float widening fix from `d4d734cb`
applied compiled the isolated cosmetic test and produced the identical exception, as did a1. This is not an
unmodified control. A supplemental runner omitting that one test then reached a second identical failure under
both compilers: `CAD plate workflow tests failed: CAD collision bounds must have positive half extents`.
The lead accepted this compiler plus widening fix as the control and these two identical failures as the
outer-app baseline. The remaining Tier 2 and output/measurement gates still require their own results.
Publishing `d4d734cb` also restores compilation of `CncProgramPlayer.hx:744` against published Haxeon.

The Tier 2 retention gate passed eight scenarios and failed `panel-flows` with
`Headless editor profile failed: Inspection camera ignored its view label`. Running that scenario with the
lead-approved diagnostic control produced the same failure. The lead accepted this as a pre-existing
outer-app failure; the other eight retention scenarios passed.

### Pre-rebase batch output and allocation comparison (2026-11-10)

The approved control is `fcfd253b` with only `d4d734cb`'s abstract widening applied. The editor modules
have SHA-256 `3267a541ba70284940408447dc228175b0b0607a005c81a648037a4b20304b24` (control) and
`0113022f30f18e5368b1663b3fc82faa940a68e364db885dd687189b745b8790` (a1).
All 36,447 normalized functions and the descriptor and function sidecars match. The four byte-difference
clusters are the generated `haxeon.build.CodeIdentityTable` fingerprint entries, references to its changed
source hash in legacy/debug spans, and the source-snapshot section ordered by that changed hash. The Wasm GC
Web guest hashes are `99f3f8bec26ad703a767eced85e3a7b93fa8c8b00f258d8def4de276c046b50b` and
`e10337474a3cd251f3cb1913f6566b1774aa831ae5546549411fefa6dcf6be78`; all sections except the data
section are byte-identical, and its 87,606 changed bytes are exclusively the generated compiler-identity table.
The Web build's generated FFI list omits `machinekit-pendant.hxi`; the comparison generated it from the pinned
C header using the wasm32 importer in the disposable gate directory. A control guest was terminated by
`earlyoom` after memory pressure crossed its threshold; a locked retry completed both byte-comparison builds.
For the separate timing/memory pair, `earlyoom` again terminated the control at 8,967 MiB RSS. With
`HL_GC_MARK_THRESHOLD=0.08`, the control completed in 489.24 s at 9,035,512 KiB peak RSS, but `earlyoom`
terminated a1 after 355.44 s at 6,610 MiB RSS; other builds were running and `earlyoom` also terminated
unrelated processes. A later pair completed with `HL_GC_MARK_THRESHOLD=0.04` for both: control/a1 wall time
was `787.75/684.22` s, peak RSS `8597848/8619712` KiB, typing-lowering `12851.27/10807.53` ms, and body
typing `843.43/643.92` ms. Both hashes matched the earlier comparison. Other builds were running.

HashLink's normal allocation counter charges 2,048-byte thread-local runs when reserved, producing varying medians
even for repeated runs of the identical control module. With `HL_GC_PROFILE=1`, which disables those runs, the
exact action medians match for all 14 tab and interaction actions; selection's available allocation components
also match. The standard selection capture does not report a total, so a temporary instrumented copy measured
selection input plus frame with the same per-allocation mode: all 59 measured cycles matched exactly, with a
577,192-byte median for both. Other builds were running.

Three planned editor timing pairs yielded two cold pairs and one mismatched pair because only the control reused
its resident module. Cold control/a1 typing-lowering milliseconds were `4746.16/3859.40` and `3911.11/3929.18`;
body typing was `187.06/130.66` and `132.78/129.40`. A preliminary cold pair was `4243.92/4290.62` total
and `141.26/136.99` bodies. One-shot control/a1 typing-lowering was `4757.61/4743.32` ms, body typing was
`165.98/167.40` ms, and peak RSS was `4969660/5003732` KiB. The mismatched reuse run is not a comparable
timing result. Other builds were running.

### Rebased batch comparison (2026-11-10)

After rebasing onto `fcfd253b`, the editor control/a1 SHA-256 hashes are
`8890fb8915cd56619a86bfbcd4ddf058febdea6a8bcb095c5005a80f8e7609f5` and
`4275fb9d96e66b04e1241d6701042b0d2e5675c51ff49617809cfd081de078b6`. All 36,421 normalized
functions and function/descriptor sidecars match. The four byte-difference clusters are the same compiler-identity
fingerprint table, its legacy debug hash, its debug-span hash, and the reordered source snapshots containing that
table. One-shot control/a1 typing-lowering was `5435.89/5095.02` ms, body typing `171.97/166.21` ms, wall time
`115.40/104.38` s and peak RSS `4981672/4997688` KiB. Other builds were running, including self-hosting.
With `HL_GC_PROFILE=1`, all 14 tab and interaction action medians matched; the instrumented selection probe also
matched all 59 measured cycles exactly at a `577192` byte median for both compilers. Other builds were running.

The rebased Web guest control/a1 SHA-256 hashes are
`40fabd46f3d62d500785db7bc0f8122267347210e0ebf7f7182268f60e5aa9ee` and
`24a1a8560f16ce5e1cced8a4a70aa59e50326ca092ab1648d323de662e6b2457`. All sections except the data
section match; its 87,742 changed bytes lie within the generated compiler identity table. The locked pair with
`HL_GC_MARK_THRESHOLD=0.04` took `735.12/724.76` s wall time and `8604268/8614840` KiB peak RSS;
typing-lowering was `11601.02/11759.46` ms and body typing `664.96/682.61` ms. Other builds were running.
These single-pair typing times are higher for a1, so they do not by themselves establish the no-regression gate.
The rebased app suite again reached `Uncaught exception: appearance edit rebuilds the child's material`,
the accepted identical control failure above. A supplemental run omitting that test reached the same
`CAD plate workflow tests failed: CAD collision bounds must have positive half extents` baseline after its other
scenarios passed. Rebased retention passed eight scenarios; `panel-flows` again
reported `Headless editor profile failed: Inspection camera ignored its view label`, also the accepted control failure.
Rebased performance budgets passed each scenario on its first capture; all three headless captures passed.
Other builds were running during those locked checks.

An instrumented Haxe-built compiler, stopped immediately after the Web frontend's typing/lowering phase,
ran three alternating-order pairs under both locks with the same Web arguments and GC threshold as the full pair.
Control/a1 typing-lowering milliseconds were `13106.99/13396.28`, `10933.27/14538.10`, and
`14723.94/13024.29`; body typing was `769.24/793.56`, `638.07/867.51`, and `736.69/765.95`.
Other builds were active and varied between samples. The samples do not establish that typing is not slower.
An earlier instrumented self-hosted control probe failed with `haxeon/ui/widgets/settings/SettingsPanel.hx:154:19:
E1003: Empty array literal requires an expected element type`; that probe used a different FFI argument order.

A separate instrumented Haxe-built frontend measured process CPU as well as wall time at the same boundaries.
Three alternating-order control/a1 pairs measured typing-lowering CPU milliseconds of `38030/34810`,
`39280/35050`, and `35110/41350`, and body-typing CPU of `2330/2180`, `2270/2100`, and `2050/2720`.
The corresponding typing-lowering wall times were `13164.30/12008.73`, `13498.74/12126.20`, and
`12086.29/14080.02` ms; body wall times were `758.50/708.06`, `816.30/700.17`, and `692.61/934.25` ms.
For this three-pair diagnostic, the control/a1 medians were `38030/35050` ms CPU and `13164.30/12126.20`
ms wall for typing-lowering, and `2270/2180` ms CPU and `758.50/708.06` ms wall for bodies. All samples
are retained here, including the slower third a1 pair. Other builds ran during the locked pairs. The earlier
wall-only probe and full Web pair above remain mixed, so a small wall-time change cannot be ruled out.

Three additional locked alternating-order pairs compiled the committed batch compiler sources with the control and
a1 compilers. Control/a1 typing-lowering milliseconds were `12834.08/18304.42`, `35861.66/17188.32`, and
`22313.87/17836.46`; body typing was `78.97/91.57`, `124.79/131.62`, and `162.84/132.00`. Peak RSS KiB was
`1684356/1686760`, `1695548/1687708`, and `1694400/1696508`. Other builds were running, including multiple
flat-structs decoder tests during the first a1 sample. The control/a1 medians were `22313.87/17836.46` ms for
typing-lowering and `124.79/131.62` ms for bodies. The spread is too large to establish a small body-time change.
All six compiler modules from these same-source runs were byte-identical, with SHA-256
`d6478a774ad1871f76c3ccb7f8f7621fc96f9c8cd7795ab0e8ca207b9b543937`.

## Measurement

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

## Classes

- **(a) local**: the rewrite of a function reads only that function (and the target profile). A cached result is valid while the
  function object is the same.
- **(b) local plus a summary**: the rewrite reads the function and a small program summary computed from per-function
  contributions and the object/interface/enum tables. Generators of helper functions belong here: the helper set is a function of
  the summary.
- **(c) global**: the rewrite needs other functions' bodies, or the summary is a fixpoint over a call-dependency graph.

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
| ObjectReflection.generate | (b) generator | helper set = f(declared natives, reflectable objects) | signatures | 1.9M | 1.5% |
| IrOptionalScalarFlow + IrOptionalValueFlow.addHelpers | (c) fixpoint + (a) generator | `candidates` = greatest set such that each `eligible(fn)` holds given the others | callee bodies (`snapshotOnlyReceiver`), method resolution | 1.0M | 0.8% |
| IrStaticNullChecks | (b) | functions reachable from `__init` (call graph) | bodies of the reachable functions | 0.4M | 0.3% |
| GenericOwnerErasure.generate | (b) generator | helper set = f(call names, objects) | callee signatures | 0.01M | 0.0% |

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
   `IrOptionalScalarFlow`, `IrTypedInterfaceDispatch.generate`, `GenericOwnerErasure.generate`, `ObjectReflection`) change with their port.
5. **Check mode.** `HAXEON_CHECK_REUSE=1` recomputes every reused rewrite, contribution and helper and compares with
   `HlFunctionEquality`-style structural equality; it names the pass, the function and the first differing instruction.
6. **Unported passes** run as one opaque step with the whole program, so every commit is correct.

## Order of ports

By edit cost, with what must come first:

0. **The 3.4M floor.** Profile one of the five passes in finding 2 and remove the shared cause. No interface needed; up to 17M (14%).
1. **The framework commit**: the interface, the view, the opaque step, check mode. No pass moves in it.
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
   `TypedInterfaceDispatch`, `CheckedDynamicCasts`, `ValueDynamicDispatch`, `OptionalFieldStorage`, `ObjectReflection`,
   `GenericOwnerErasure`, runtime-surface detection, `StaticNullChecks`: 2% to 3% each; their gain is that the helpers become derived from
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
