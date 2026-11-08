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

### B. IR passes

The IR pipeline is the larger share of both warm builds. It is not a per-function function: the passes read other
functions and objects, and several generate shared helper functions.

- Cross-function reads: the inliner reads callee bodies; `IrScalarArguments` changes callee ABIs and every caller;
  `IrScalarClosures` decides per closure type across the program; `IrOptionalScalarFlow` and `IrValueDynamicDispatch`
  resolve methods of other classes; value-array lowering and `GenericOwnerErasure` generate helpers per shape and per
  generic owner; `IrInlineEnumLowering` looks at every use of an enum.
- Generated helpers must disappear when their last user does, or the result stops matching a cold build.

Design: the same recorded-facts memoization as in A, applied pass by pass, behind an explicit pass interface:

1. Each pass is run through `IrPassCache.run(pass, program)`: for every function the pass is given a `ProgramView`
   (objects, interfaces, enums, signatures, callee bodies, method resolution). The view records the queries a function's
   rewrite made and their answers. A cache entry is `(input function identity, queries+answers) -> output function`.
   On the next build an entry is reused when the input function is identical and every recorded answer is unchanged.
   The inliner's callee-body reads are queries on the callee's *output* identity, so an edit invalidates exactly the
   callers that inlined (or could have inlined) the edited function.
2. Whole-program outputs (generated helpers, object table changes, new natives) are recomputed from per-function
   "contributions" that each entry also stores (which helper shapes a function needs). The helper set is the union of
   contributions of the current functions, so a helper nobody needs any more is not produced. Helper bodies are
   themselves cache entries keyed by their shape.
3. A pass that has not been ported keeps running on the whole program, so the pipeline is correct at every step and the
   benefit grows pass by pass, in order of cost: `IrInlineEnumLowering` (+ its verifier), `IrValueInterfaceBoxes`,
   `IrOptionalScalarFlow`, `IrInliner`, `IrScalarArguments`, `IrScalarClosures`, value arrays, then the dispatch passes.
   Unported passes cannot be cached by function, but a *program-level* input digest still lets the whole pipeline be
   skipped when nothing changed (below).

Program-level shortcut (small, safe, first): the digest of the pipeline's raw input (the `IrGenerator` output: function
identities + objects, interfaces, enums, statics, natives) is stored with the final IR. If it is equal to the previous
build's digest (no-op, or an edit that retyped to identical IR), the previous final IR is the answer and no pass runs.
This removes the 153M of IR work from the no-op and nothing else.

Honest scope: A and the program-level shortcut are mechanical and clearly bounded. B for the edit case is the part that
needs the most care; each ported pass is its own commit with a test that compares warm and cold output, and the plan below
ends at "ported passes" rather than claiming the whole pipeline. If a pass turns out to be non-reusable for a structural
reason (it needs a global fixpoint over all functions), the doc will say which and why.

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

## Steps

1. This document (profile + plan). Send to dev-71 before coding.
2. Commit 1: relocatable lowering + link for HashLink, plain builds reuse it, live patching ported onto the same
   relocatables; `LoweringView` facts; per-function verification. Warm == cold byte test (small multi-module program:
   body edit, signature edit, generic specialization edit, no-op) in `tests/compiler`.
3. Commit 2: program-level pipeline shortcut + `IrPassCache` interface; port passes in cost order, one commit each,
   stopping when the next pass is not reusable for a stated reason.
4. Wasm: decided after reading `WasmFunctionLower`, reported in the commit message.
5. Gates: `HAXEON_NATIVE_READY=1 scripts/test-driver.sh 8`; app cold / no-op / edit compile-count before vs after with the
   same compiler build path; this document's Results section.

## Open questions for dev-71

- Is stopping B at "ported passes, in cost order" acceptable, or must the edit case reach a specific number?
- Live patching: OK to port its backend onto the same relocatables (it is the only other user of `HlFunctionCache`
  lowering reuse)? Keeping two lowering paths is the alternative and I would not recommend it.
