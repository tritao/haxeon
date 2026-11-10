# IR pass inventory and pass interface (ADR 0003, M2)

Status: proposal, no code. Builds on section B of [`WARM_REBUILD_REUSE.md`](WARM_REBUILD_REUSE.md) (pass interface, name families,
file:line evidence). This document adds the measured edit-build cost per pass and proposes the order and the per-pass interface.
Out of scope: the Wasm builders' own internal passes (ADR 0004 moves the runtime library code, so they will change first).

## Internal marker migration (a1)

These unchecked families encode compiler meaning in names today. Each family must move its producers and consumers together;
the boxes are checked only when the string representation and its parser are gone. Ordinary source names and diagnostic
interpolation are not markers.

- [ ] Closure adapter and cast signature hashes (`__haxeon_closure_adapter_`, `__haxeon_closure_cast_`); verifier and Wasm adapters.
- [ ] Function origins and scalar ABI eligibility: the duplicated prefix lists in `IrScalarArguments` and `WasmScalarAbi`,
  including lambda, generic, equality/hash, iteration, interface, optional, nullable, key-path and array helpers.
- [ ] Value-array slot, element, factory, bridge and place-method names (`$value-array:`), including encoded type and path.
- [ ] Scalar word and lane pack/unpack, lane runtime/storage and HL scalar references (`$word:`, `$lane:`, `$lane-runtime:`,
  `$lane-storage:`, `$hl:scalar-*`); receiver and reference checks.
- [ ] Scalar arguments/closures and Wasm scalar return, result, rethrow, function and closure-restore markers.
- [ ] Enum dynamic box/view/unbox/test, equality/reflection, tag, inline enum and enum specialization markers.
- [ ] Value dynamic and interface box/unbox/type-test, typed interface dispatch, checked casts and generic erasure markers.
- [ ] Optional field/value/scalar and nullable scalar helper markers, including wrappers and call boundaries.
- [ ] Typing-generated flags, raw-representable, equality/hash, wire/JSON, key-path and receiver-readonly markers; runtime
  type dependencies and fresh-constructor markers where consumed as compiler metadata.
- [ ] Wasm GC holder/place and lane-storage markers, and backend-generated array accessors and runtime names that are parsed.

Canonical IR serialization must change version with the typed representation. Generated symbols may still need unique
linkage names, but compiler decisions must use declared data rather than recover meaning from those names.

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
