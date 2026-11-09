# Warm rebuild reuse

Status: plan (step 1), not implemented. Branch `warm-rebuild-reuse`, from `4b460ad2`.

## Problem

A warm `haxeon build` (same compiler worker, "reusing compiler session") retypes only what changed, but the rest of the
pipeline runs over the whole program every time. `materia/app`, `--compiler-only --timings`, same compiler build:

| build | compile-count | wall | functions retyped | final functions | final IR changed |
|---|---|---|---|---|---|
| cold | 792.4M | 66-67 s | 30502 | 34445 | 34445 |
| warm no-op (new output path) | 288.8M | 36-40 s | 0 | 34449 | 0 |
| warm after a one-statement `Main.hx` edit | 357.1M | 41 s | 625 | 34489 | 372 (840 regenerated) |

(`final IR changed` = `IrInliner.run` result; `regenerated` is what the backend is asked to lower. Measured with a
temporary probe in `FrontendCompilation.run`, not committed.)

So after an edit about 2.4% of the final functions differ, and the warm build still pays for all 34489.

## Profile (warm no-op, hlprof-live, 250 Hz, compile thread only)

Percent of the compile thread's samples (8658 samples, `CompilationPipeline.compile`).

| phase | samples | share | what it is |
|---|---|---|---|
| `FrontendCompilation.run` | 4839 | 56% | everything before the backend, see below |
| - `IrGenerator.assemble` (`IrProgramAssembler.assemble`) | 1771 | 20% | whole-program IR passes #1 |
| - `IrInliner.run` | 808 | 9% | inliner + `IrInlineCache` comparison |
| - `SemanticAssembly.run` | 479 | 6% | semantic reuse / canonicalization |
| - `IrScalarArguments` / `IrScalarClosures` / `IrValueArrayProgramRewrite` | 365 / 254 / 253 | 4% / 3% / 3% | value lanes and scalar ABI |
| - other IR passes (constructors, phi scalarization, replacement, nullable flow) | ~340 | 4% | |
| `BackendAssembly.assemble` | 3753 | 43% | |
| - `HlLower.lowerProgram` | 2582 | 30% | per-function lowering (1690 in `lowerFunction`) + metadata |
| - `IrVerifier.verify` | 898 | 10% | whole-program verification, every build |
| `HlWriter.writeFile` | 654 | 8% | encode and write |

Allocation counts per phase from `--timings` (objects), pre-merge vs merged vs merged-cold:

| phase | pre-merge no-op | merged no-op | merged cold |
|---|---|---|---|
| semantic + typing | ~20M | ~20M | ~65M |
| `ir-assembly` | 98.5M | 153.0M | 196.8M |
| backend (`backend-assembly`) | 100.2M | 111.1M | 110.7M |
| ABI | 2.6M | 2.6M | 2.6M |

Where the extra 65M of the merge went: 54M in `ir-assembly`, 11M in the backend. In the `IrProgramAssembler` profile the
passes origin added are `IrInlineEnumLowering.run` (21% of that phase, plus `IrVerifier.verifyInlineEnumsLowered` 360
samples), `IrValueInterfaceBoxes.rewrite` (12%), `IrEnumDynamicDispatch` (7%), `IrValueDynamicDispatch` (6%),
`IrEnumRuntimeSpecializations.materialize` (5%) and `IrTypedInterfaceDispatch` (4%). Each one visits and, in part,
reconstructs every function; `IrInlineEnumLowering.run` allocates `IrBlock`s for functions it does not change.

Conclusions:

1. Warm no-op: about 55% of the objects are IR passes, 38% the backend, 7% frontend. Nothing in the IR pipeline or the
   backend depends on what changed.
2. Everything after the frontend runs on the whole program, and an edit changes ~2.4% of it. The achievable floor is
   frontend + changed functions + their dependents, roughly 30-40M objects for the no-op and well under 100M for the edit.
3. The IR pipeline is the larger half and the harder one: its passes read other functions (see "IR passes").

## What exists today

- `IrInlineCache` keeps the previous build's final IR per function and `IrInliner.run` returns the names whose final IR
  differs (structural equality, provenance and file hash included, `IrFunctionStateEquality.same`). That set is exactly
  the "changed" input the backend needs, and is already computed on every build.
- `HlModuleAssembler` + `HlFunctionCache` reuse lowered `HlFunction`s for functions not in `regenerated`, but only under
  live patching. They keep absolute indices into append-only tables (`HlSymbolTable`, stable function slots), so the module
  produced depends on the session's history. `BackendAssembly.hx:74` therefore gives a plain build a fresh
  `HlModuleAssembler`: "the result depends only on the source, never on what the session compiled before".
- `HlLower` lowers metadata first (enums, interfaces, objects, static globals), then each function. Function bodies intern
  types, ints, floats, strings, globals and function types into the shared tables in encounter order, and resolve callees
  through `functionIndices`, which a plain build derives from the order of `program.functions`.

So a lowered function is not reusable across plain builds because its operands are absolute indices that shift whenever
any function, constant or type is added or removed anywhere before it.

## Design

Goal: output of a warm build is a pure function of the sources and the compiler (byte-identical to cold), and the work
done is proportional to the change.

### A. Relocatable lowering (backend, HashLink)

`HlLower.lowerFunction` stops writing absolute table indices. Every reference goes through a sink:

- A function is lowered to `HlLoweredFunction`: the `HlFunction` with provisional operands plus a relocation list
  `(instruction, operand, kind, key)`. `kind` is int / float / string / type / global / function / object field / method
  slot, and `key` is the value or name. Debug metadata is already per-function.
- A link step assigns canonical indices and patches operands. It is the only code that touches `HlSymbolTable`:
  it replays each function's references in function order, so tables get the encounter order a cold lowering would give.
  Cold and warm both go through the link step, so byte identity holds by construction; the test checks it.
- Live patching keeps its append-only tables: its link step is the existing `HlSymbolTable` interning in stable slot
  order (same relocatables, different assigner). No second lowering path, no compat form: `HlFunction`-with-absolute-
  operands is produced only by linking.

Cache entry: `LoweredEntry { relocatable function, facts }`.

- Key: function name + the function's final-IR identity (the inliner cache already decides "same structurally,
  provenance and file hash included") + `LoweringEnvironment` (target, `fieldReserve`, `developmentMetadata`, native
  ABI set; changing any of these drops the whole cache, which is a different build configuration, not a fallback).
- Facts: the cache is also valid only while the things lowering read *about other entities* are unchanged. `HlLower`
  reads `objects`, `valueObjects`, `interfaceBases`, `typedInterfaces`, `nativeVisible` and the object/interface layouts.
  These reads go through one narrow `LoweringView` that records `(query, answer digest)` for each function. On reuse the
  recorded queries are re-evaluated against the new program; any different answer relowers that function (e.g. a field's
  storage type changed, an object turned into a value type). This is the precise invalidation rule, not a fallback.
  Callee signatures, field offsets and method slots are *not* facts: they are relocations resolved at link time.
- Verification: `IrVerifier.verify` runs on the whole program today. It becomes per function keyed by the same final-IR
  identity (a verified function stays verified) plus the whole-program checks that really are global
  (`verifyValueArraysLowered`, `verifyInlineEnumsLowered`, duplicate names), which become incremental over the changed set.

Removed functions disappear at link time; added functions are just lowered. Order is `program.functions` order, as today.

Wasm: `WasmFunctionLower` runs per function over `WasmProgramIndex`/`WasmLayout`/type-id plan with whole-module layout
decisions (type ids, flattened value fields, reflection table), and `WasmOptimizer` works on the whole module. The same
relocation approach applies to the function bodies, but the layout inputs are wider. Step 2 will say after reading
`WasmFunctionLower`: I expect HashLink first and Wasm for function bodies only if the layout facts record the same way;
if not, I will report why instead of shipping a half reuse.

Expected: backend 111M -> ~10M for a no-op (link only) and ~15M for the edit case; the 898-sample verification and most
of the 654-sample write step (encoding unchanged functions' bytes can be cached as well, since the bytes are index
dependent only through relocations) shrink with it.

### Program-level shortcut (step 2)

Before any per-function reuse, a build whose pipeline input and lowering environment are unchanged reuses everything:

- *Pipeline input* = what `FrontendCompilation.run` hands to `IrGenerator.assemble`: the cached typed-function IR in order,
  natives, objects, interfaces, enums, statics, static initializers, entry point, C natives, reflectable objects, the static
  check cache identity, value-lane target and exported functions. Functions compare by object identity, falling back to
  `IrFunctionStateEquality.same` (a regenerated but equal function); the small tables compare by a canonical digest.
- *Lowering environment* = target, `fieldReserve`, `developmentMetadata`, live patching flag, the native set, debug-file list.
- Equal on both: keep the previous final IR and the previous encoded module bytes; run no pass, no verification, no lowering,
  no encoding; write the bytes to the requested output path (a new path included).
- Not equal on either: the normal path. There is no partial use of this cache; per-function reuse is steps 3-4.

### B. IR passes: summary plus local rewrite (ADR 0003 layers 4-6, milestone M2)

The first draft of B added recorded facts to each existing pass. That multiplies per-stage caches (typer metadata,
`IrInlineCache`, `HlFunctionCache`, `IrStaticCheckCache`, ...) and leaves the cause alone: passes mix global decisions into
per-function rewrites, so rewrites read other functions and every new pass touches the whole program (the merge's +54M).
B is therefore a pass interface, and one dependency mechanism shared with A.

#### B.1 The pass interface

```
Pass<S>
  contribution(fn: IrFunction, view: View) -> C        // optional; per-function facts, cached by function identity
  summarize(contributions: Map<name, C>, tables: ProgramTables, view: View) -> S   // optional; small, comparable by value
  rewrite(fn: IrFunction, summary: S, view: View) -> IrFunction                    // maps one function to one function
  helpers(summary: S, view: View) -> Array<IrFunction>                             // generated entities are a function of S
```

- `rewrite` sees its function, the summaries and what it reads through `view`. It does not see the program. It returns the
  *same object* when it changes nothing; check mode asserts that.
- `helpers` is derived from the summary, so a helper exists exactly while something needs it. This replaces ownership by
  name (`DeclarationOwners` for IR, `retained/origin` rules) for the generated functions of these passes. Each helper is
  itself a cache entry keyed by its structured identity (B.4).
- `summarize` runs over contributions, not bodies: a contribution is computed once per function identity and survives
  builds, so a summary is a merge over 34k small values rather than a scan of 34k functions. Summaries compare by value
  (structural digest); an unchanged summary lets every `rewrite` of that pass be reused.
- A pass lists the tables it changes (objects, interfaces, enums, statics, natives). Those changes are part of its summary
  (`inline enum storage`, `physical objects`), not a side effect on shared arrays. Today `IrValueInterfaceBoxes`,
  `IrOptionalScalarFlow`, `IrTypedInterfaceDispatch.generate`, `GenericOwnerErasure.generate` and `ObjectReflection` push
  into input arrays in place; that goes away with their port.

#### B.2 One dependency mechanism, shared with A

`View` is the single read interface of the pipeline (ADR decision 1). `LoweringView` in A is the HashLink-lowering
specialization of it, and the inliner's `InlineMemo.dependencies` is the same idea already in the code.

- Every read goes through the view: another function's signature, another function's body (inliner), an object layout, a
  summary field, the target profile. Each read records `(query, answer digest)`.
- A cached rewrite is reused while its input function is the same object and every recorded answer is unchanged. When a
  summary changes, only the rewrites that read the changed part run again. A read of `summary.closureTypes` is tracked per
  key (the closure type), not per summary, so one new closure type does not rerun every function.
- `HAXEON_CHECK_REUSE=1` recomputes every reused rewrite, contribution and helper and compares; it throws naming the pass,
  the function and the first differing instruction. It is part of the warm == cold test and runs once on app warm builds
  before each port merges.
- One cache per pass (rewrites + contributions), one engine, one invalidation rule. `IrStaticCheckCache`,
  `IrInlineCache.cleaned/memo` and similar per-pass caches are deleted as their passes are ported.

#### B.3 Inventory (24 passes, 2026-11-08)

Class: **L** already local; **LS** local rewrite plus a summary; **G** needs facts about other functions' bodies or a
fixpoint. "Edit risk" is how likely an edit to one body forces other functions to be rewritten. Evidence file:lines are in the
audit notes at the end of the doc. CPU is the share of the warm no-op compile thread; objects are from the per-pass probe
(functions a pass changes on a cold app compile, of ~34k).

| pass | class | summary / what makes it global | reads other functions | program tables / helpers | edit risk | CPU |
|---|---|---|---|---|---|---|
| IrEnumDynamicDispatch | LS | enum box descriptors and the `needsEqual/Reflect/Compare` flags, merged from per-function Call names | bodies (reachability pruning of `$enum-reflect-equals:*`) | adds box/view/unbox/dispatch functions; set = f(names in all bodies) | medium: the first body that needs an enum box flips a flag and rewrites every `__dynamic_equal` call | in 20% group |
| IrValueDynamicDispatch | LS | `suffixes` from value objects and `$value$equality:` names | names only | one dispatcher | low | in group |
| GenericOwnerErasure.generate | generator | helper set = f(Call/InstanceClosure names, objects) | callee signatures (`findMethod`) | adds erased/test/call helpers | low | in group |
| IrValueInterfaceBoxes | LS | value objects with interfaces + implementation signatures | signatures | adds `$value-interface-box:*` objects and wrappers (pushes into `objects`) | low | 12% of group (220) |
| IrTypedInterfaceDispatch.rewriteValueCalls | L | none | none | none | none | 54 |
| IrTypedInterfaceDispatch.generate | generator | helper set = f(`$typed-interface:` names) | signatures; replaces entries in place | dispatchers/adapters | low | 24 |
| IrCheckedDynamicCasts | L | none (helpers keyed by type) | names | appends helpers | none | 67 |
| IrEnumRuntimeSpecializations.materialize | summary only | concrete enum specializations from all signature/body types, closed over payloads | all types | filters `enums` | low | 86 |
| IrInlineEnumLowering (+Eligibility, Escapes) | LS | `allowed` enums: per-function escape facts unioned, then a closure over the type graph | method signatures | rewrites objects, interfaces, statics, enums, natives; adds objects/helpers; re-runs rewriteValueCalls/generate | **high**: one new escape in one body rejects an enum and reverts it everywhere | 373 + 360 verify |
| IrOptionalScalarFlow | **G** (candidate-pruning fixpoint) | `candidates` = greatest set such that each `eligible(fn)` holds given the others | callee bodies (`snapshotOnlyReceiver`), signatures, method resolution over all objects | pushes wrapper objects; `$optional-scalar:` clone of every candidate; receiver-check helpers | high | 315 |
| IrOptionalValueFlow.addHelpers | L + generator | helper set = f(Call names) | none | copy/box/unbox helpers | none | 10 |
| IrStaticNullChecks | LS | functions reachable from `__init` (`IrInitializationCalls`, with a closure-origin fixpoint of its own) | bodies (call graph) | `__static$nonnull$*` helpers | medium: an `__init` call-graph change instruments unrelated functions | 68 |
| ObjectReflection.generate | generator | helper set = f(declared natives, reflectable objects) | signatures | layout functions, renamed natives | low | 42 |
| IrOptionalFieldStorage | LS | `plans` from objects only | value-method bodies (cloned per owner/field/path) | accessors, place getters/setters, method clones; `physicalObjects` | low (callers keep names) | 129 |
| IrNullableScalarFields | L | none | none | normalize helpers | none | 18 |
| IrValueArrayProgramRewrite | LS | concrete value-array element types (objects, enums, interfaces, statics, natives, all bodies) | place-method bodies (clones), helper bodies inlined by `ScalarLowering` | many shape helpers, natives | medium | 253 |
| IrValueConstructors | G (bounded) | small `.new` value constructors (<=16 blocks, <=64 instructions) | callee bodies (inlines them) | none | medium: callers of an edited small constructor | 98 |
| IrValuePhiScalarization (run twice) | L | none | none | none | none | 67 |
| IrScalarArguments | **G** (heavy fixpoint) | `candidates`: functions whose value arguments/results can travel as scalars; the loop re-clones, re-rewrites calls, re-phi-scalarizes and re-SROAs every candidate until stable | callee bodies (`fieldOnly`, `receiverSnapshotOnly`, `freshReceiver`) and signatures | `$scalar-arguments:` clones, `$receiver:` variants | **highest**: flipping a candidacy retargets all callers and other candidates | 365 |
| IrScalarClosures | LS | `candidates - excluded`: scalar closure function types, from all bodies and natives | existence of the `$scalar-arguments:` clone of a closure target | rewrites objects, interfaces, enums, statics, natives; makers/environments; re-runs ValueInterfaceBoxes and CheckedDynamicCasts | high: one use of a closure type that excludes it changes its ABI everywhere | 254 |
| IrScalarReplacement | L | none | none | none | none (only follows other passes' changes) | 97 |
| IrNullableScalarFlow | **G** (candidate-pruning fixpoint by trial rewrite) | `candidates` pruned until stable | callee candidacy (a body-derived fact) | `$nullable-scalar:*` clones, require/equal helpers | high | 75 |
| IrInliner | G, already memoized | per-callee transitive dependency list (`InlineMemo.dependencies`) | callee bodies, object table | none | the dependents set is already recorded | 808 |

Findings that shape the design:

1. **Only three passes have true candidate fixpoints**: `IrScalarArguments`, `IrNullableScalarFlow`, `IrOptionalScalarFlow`.
   All three compute a *greatest* set (start with everything plausible, remove what fails), where whether `f` stays depends
   on the candidacy of the functions it calls or passes values to. That is a monotone computation over a call-dependency
   graph, so it can be made incremental by re-running it only over the *cone* of a changed function:
   1. reset the candidacy of the changed functions and of every function whose recorded read depends on them,
   2. re-run the removal loop over that set with everyone else's candidacy as fixed input,
   3. if a candidacy flipped, the same step repeats for the readers of the flipped functions.
   Cost: the cone, which for an edit that does not flip any candidacy is the changed function alone. It can grow to a
   transitive caller set when a candidacy flips; that is the true cost of the semantics, not an artifact. The soundness
   obligation is that the removal loop reads candidacy only through the view, so the cone is complete; check mode verifies it.
2. **Everything else is local plus a summary, or a generator.** `IrInlineEnumLowering` is the only large LS pass whose summary
   is itself a closure over a type graph, but each body contributes independent escape facts, so the summary is a union
   plus one graph closure over small data.
3. **Passes call other passes.** `IrInlineEnumLowering` re-runs `rewriteValueCalls`/`generate`; `IrScalarClosures` re-runs
   `IrValueInterfaceBoxes` and `IrCheckedDynamicCasts`; `IrValueArrayProgramRewrite` and `IrScalarArguments` invoke phi
   scalarization and scalar replacement inside their loops. The pipeline is not linear. In the framework each such call is a
   separate stage with its own summary input; the nested calls become explicit stages (ADR layer 5 then 6 per target) rather
   than helpers called from inside a pass.
4. **Hidden global state**: `IrGenerator.genericOwnerOrigin`, `usesNativeReflectionDispatch`, `observableClassFieldCount`
   and `IrInliner.packedValueFields` are read by passes but are not part of the `IrProgram`. They must move into the target
   profile or summaries (ADR M1) before the passes that read them are memoized, or a cached rewrite can go stale silently.

#### B.4 Name-encoded structure, and which summary replaces it

Rendered names stay as link-time output (ADR decision 5). Where a pass parses a name back, the structured identity of the
generated entity replaces it. Per family (pass that owns it in parentheses):

| name family | parsed in | replaced by |
|---|---|---|
| `$enum-equals:`, `$enum-reflect-equals:`, enum box/view names, Base64 types (IrEnumDynamicDispatch) | same pass, `IrInlineEnumEscapes` | identity `EnumHelper(kind, enumType)`; the box descriptor set is the summary |
| `$value$equality:` suffixes (IrValueDynamicDispatch, IrOptionalScalarFlow exclusions) | `substr` | identity `ValueEquality(valueType)` |
| `$generic-erased:`, `$generic-type-test:`, `$generic-method-reference:` (GenericOwnerErasure, `methodReferenceOf`) | `split(":")` | identity `ErasedGeneric(owner, member, typeArgs)`; the owner/member fields replace splitting `Owner.member` |
| `$value-interface-box:` (`BOX_PREFIX`) (ValueInterfaceBoxes) | IrTypedInterfaceDispatch, InlineEnumEligibility, ObjectReflection, `IrValueInterfaceBoxes` | identity `InterfaceBox(valueType, interface)`; box objects are part of the box summary |
| `$typed-interface:` entries/adapters | `split(":")`, `originalEntryName` | identity `TypedInterface(entry|adapter, interface, method, object)` |
| `$optional-scalar:`, `$optional-value:*`, `$optional-field:method:` (+Json), `$nullable-scalar:*` | startsWith chains, `Json.parse` | identities per family; the Json-in-name encodings (OptionalFieldStorage) become typed fields |
| `$scalar-arguments:`, `$receiver:` | prefix allowlists in IrScalarArguments, IrScalarClosures, `originalEntryName`, `WasmScalarAbi` | identity `ScalarClone(original, kind)`: "the original of this clone" is a field, not `substr` |
| `$value-array:` shape helpers | prefix/suffix/Base64 in `ScalarLowering` | identity `ValueArray(elementType, operation)` |
| `$inline-enum-global:<len>:<name>:<field>` | `HlLower`-side parsers | identity `InlineEnumGlobal(global, field)` |
| `.new`, `Owner.member` splits (`lastIndexOf(".")`) | IrValueConstructors, IrInitializationCalls | owner and member as fields on every method function |
| `EnumRuntimeType.declaration` (`indexOf(SEPARATOR)`) | IrEnumRuntimeSpecializations | specialization = (declaration, type args) structured |

Ordering rule: a name family is converted in the commit that ports its owning pass, and the parser is deleted in the same
commit (ADR M3 rides with M2).

#### B.5 Migration and order

The framework runs every pass that is not ported as one opaque whole-program step, so each commit is correct. A port moves
one pass onto the interface, deletes its old entry point (no compat form), and adds its warm == cold case.

Order, by what a port saves in the edit case (CPU share of the warm build x probability that an unchanged function is
reused), after the framework commit and the target-profile milestone (ADR M1):

1. `IrScalarArguments` + `IrScalarReplacement` + `IrValuePhiScalarization` (365 + 97 + 67 samples, and 820+918 functions changed
   per build): the largest edit-case cost; ScalarReplacement and Phi follow its changes. The fixpoint cone is the hard part.
2. `IrInlineEnumLowering` + Eligibility + Escapes (373 + 360): the source of most of the merge's +54M; summary is the inline
   set.
3. `IrScalarClosures` (254) and `IrValueArrayProgramRewrite` (253).
4. `IrNullableScalarFlow`, `IrOptionalScalarFlow` (75, 315): second fixpoint pair, reusing the cone mechanism from step 1.
5. The helper generators and dispatch passes (`IrValueInterfaceBoxes`, `IrEnumDynamicDispatch`, `IrValueDynamicDispatch`,
   `GenericOwnerErasure`, `IrTypedInterfaceDispatch`, `ObjectReflection`, `IrOptionalValueFlow`, `IrEnumRuntimeSpecializations`):
   cheap per pass; most of their benefit is that helpers become derived from summaries (no ownership by name).
6. `IrInliner` last: it already has the only correct dependency recorder; it moves onto the shared view, which deletes
   `IrInlineCache.memo/cleaned/instrumented` as separate stores.

For each pass left on the whole-program path the doc records the reason (for example a fixpoint whose cone is the whole
program because its candidacy depends on a table every function reads).

#### B.6 Package-level separate compilation (not built)

A summary is a small value computed from per-function contributions, and a contribution is the unit a package could export.
The framework therefore keeps contributions and summaries serializable by construction (plain data, no object identity in
their values). Cached rewrites key on function identity today; the digest form of that key is what a package interface would
carry. No package code is written here.

## Cache lifetime and invalidation, summary

| entry | key | invalid when |
|---|---|---|
| lowered function (A) | name + final-IR identity + lowering environment | function IR differs; recorded view query answers differ (object/value/interface facts); lowering environment (target, field reserve, dev metadata, native set) differs (drops all) |
| link output (tables, indices) | none, recomputed | always (cheap, canonical) |
| verified function | final-IR identity | function IR differs |
| pass output (B) | input identity + recorded query answers | input differs; any recorded answer differs (callee signature/body, object layout, enum use, method resolution) |
| pipeline output (shortcut) | raw input digest | any function/shape differs |
| encoded function bytes | lowered function + its link-time operand values | lowered entry differs or a relocation resolves to a different index |

Session lifetime: caches live with the compiler worker session, like `IrInlineCache`. A new session starts cold and
produces the same bytes. They are rebuilt (not patched) when the compiler is rebuilt, which restarts the worker anyway.

## Approved order and safety rules (dev-71)

Each item is its own commit, full suite before each commit. After each: compile-count for cold / no-op / edit.

1. Pass allocation fixes, no caching: the merged passes that rebuild every function (`IrInlineEnumLowering`,
   `IrValueInterfaceBoxes`, the enum/value/typed-interface dispatch passes) return the same `IrFunction` and blocks when
   they change nothing. Helps cold builds too.
2. Program-level shortcut extended to the backend: if the raw pipeline input digest and the lowering environment both equal
   the previous build's, reuse the previous final IR and the previous module bytes; no pass, no lowering, only write the
   bytes (also to a new output path). Test: warm no-op output == cold output.
3. Relocatable lowering:
   a. relocatable lowering + link step, cold path only; no output byte changes (byte equality against the pre-change
      compiler on cnckit/tests in the same install path, and on the test programs);
   b. plain warm builds reuse lowered functions; warm == cold test (no-op, body edit, signature edit, generic
      specialization edit, added/removed function, an added constant or string that shifts tables);
   c. port live patching onto the same relocatables (all Live*, Profiler*Lsp and HotReload tests keep passing);
   d. per-function verification.
4. IR pass ports, ordered by what they save in the edit case. Each skipped pass gets the reason it is not reusable.

Safety:

- `LoweringView` is the only way `HlLower` sees other entities. It must not hold the `IrProgram` or the object maps, so an
  unrecorded fact cannot be read.
- Check mode (`HAXEON_CHECK_REUSE=1`): every reused entry (lowered function, later pass outputs) is also recomputed and
  compared; the build throws, naming the function and what differed. It runs in the warm == cold test and once on the app
  warm builds before each pass port. A test aid, not a fallback.
- Worker RSS after a warm app build is reported before and after the caches.
- Wasm: as planned, the decision is reported.

## Steps

Order and safety rules are in "Approved order and safety rules". Mapping to ADR 0003: steps 1-3 are M0, the target profile is
M1, B is M2 together with M3 (structured identities of the families it ports).

1. Done: pass allocation fixes (`fc02b21d`).
2. Program-level shortcut including module bytes.
3. Relocatable lowering: (a) link step on the cold path, byte-identical; (b) plain warm builds reuse lowered functions;
   (c) live patching ported; (d) per-function verification.
4. B (after review of this doc and after ADR M1): framework with the opaque step, then ports in the order of B.5.

Gates for each step: full `HAXEON_NATIVE_READY=1 scripts/test-driver.sh 8`, and app cold / no-op / edit compile-count with
the same compiler build path, plus worker RSS after a warm app build once caches exist.

## Audit notes (where the inventory comes from)

File:line evidence from the 2026-11-08 read of `src/compiler/ir` (a classification agent read each pass; the fixpoint claims
for `IrOptionalScalarFlow.hx:30-39`, `IrScalarArguments.hx:76-120` and the `canPassAliases` callee-body read at
`IrOptionalScalarFlow.hx:285-295` were re-read by hand):

- Cross-function body reads: `IrEnumDynamicDispatch.hx:103-121` (reachability pruning), `IrOptionalScalarFlow.hx:285-295`,
  `IrStaticNullChecks.hx:30-38` + `IrInitializationCalls.hx:44-66`, `IrOptionalFieldStorage.hx:98-117`,
  `IrValueArrayPlaceMethods` clones and `ScalarLowering` inlining, `IrValueConstructors.hx:11-30,121-137`,
  `IrScalarArguments.hx:180-216,296-323`, `IrNullableScalarFlow.hx:28-35,156-161`, `IrInliner.hx` memo
  (`InlineMemo.dependencies`).
- Signature/name-only reads: `GenericOwnerErasure.hx:230-236` (`findMethod`), `IrValueInterfaceBoxes.hx:38-56`,
  `IrTypedInterfaceDispatch.hx:107,130-137`, `ObjectReflection.hx:154-186`, `IrScalarClosures.hx:80-83`.
- In-place mutation of inputs: `IrValueInterfaceBoxes.hx:64`, `IrOptionalScalarFlow.hx:52`,
  `IrTypedInterfaceDispatch.hx:196,209`, `GenericOwnerErasure.hx:75,102,144`.
- Hidden state: `IrGenerator.hx:64` (`genericOwnerOrigins`), `usesNativeReflectionDispatch`, `observableClassFieldCount`,
  `IrInliner.packedValueFields`.
- Name parsing sites: see B.4 for the families; the heaviest users are `IrOptionalFieldStorage` (Json in names),
  `IrTypedInterfaceDispatch` (`split(":")` on interface names) and the prefix allowlists in `IrScalarArguments.hx:34-47`.

Not traced: `IrInitializationCalls.calls()` beyond its fixpoint header, and the internals of `IrLoadStoreForwarding` and
`IrStrengthReduction` (both inside `IrInliner.run`).

## Open questions for dev-71

- ADR M1 (target profile) before B ports: assumed. The hidden globals above are the reason.
- B.5 puts the scalar-argument fixpoint first because it dominates the edit case; its cone mechanism is also the risk. If you
  prefer to start with the inline-enum pass (the merge regression, simpler summary) and bring the fixpoint passes second,
  say so.

## Open items

- **Generated helper units lose their anonymous-type records.** A unit's anonymous types are kept for a build that does not type it
  again only while the unit is a function in the signature table or a class's `Class.__init`. Generated helpers (enum equality and
  reflection bodies, wire and JSON codecs, key-path helpers) are typed on request and are not in that table, so a warm build that
  does not request them again drops what they registered. None is known to register an anonymous type, and the app's cold and warm
  typed programs agree. Structured identities (ADR 0003 M3) give a helper the unit it needs; until then
  `WarmRebuildReuseMain` compares the warm and the fresh typed program, which is the check. `HAXEON_CHECK_REUSE` cannot recompute a typed
  program without typing every unit again, which is what a fresh compile is, so it does not cover this.
- **Remaining cold/warm differences found while making the first no-op reuse** (all fixed): process-wide temporaries counters in
  `IrGenerator`, the typing-order list of reflectable classes, the anonymous types of unchanged units, generated helpers cached by two
  modules. Each was an input the pipeline could not tell was equal. The class of problem is the mutable `IrGenerator` state
  (`inputState()` hashes the part the passes read); ADR M1 replaces it.
- **Worker memory.** The warm app worker reaches 9-12 GB; `earlyoom` ends it when free memory drops under 10%. The reuse caches add about
  0.4 GB (kept final IR, module and encoded bytes). Tracked separately.

