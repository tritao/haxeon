# Removing the frontend restart (design note, no code yet)

Status: for review. Measured on 2026-11-12 with haxeon 7b97c092e on the Materia app of outer e9173b977 (the baseline recorded in
`scripts/measure-cold.sh`). Counts below are deterministic (compile-count, bytes); the wall figures were taken at load 10 to 20 and are indicative.

## What happens today

Typing a body that does arithmetic on a Dynamic records a dependency on `haxeon.DynamicOps` (`RuntimeDependencyTracker.record`). After the typed
functions are published, `FrontendCompilation.includeTypedRuntimeDependencies` adds the module to the owner's dependencies and the frontend runs again
as a *continuation* (landed 2026-11-08: pass 2 types only the new module's functions). In the app six functions name it and it is the only module
requested (`restarted: ... needs haxeon.DynamicOps`, six times, one restart).

Pass 2 of the cold app build, by stage (time / allocation):

| stage | pass 1 | pass 2 |
|---|---|---|
| graph | 5.2 s / 2.97 GB | 0.18 s / 0.15 GB |
| semantic assembly | 3.0 s / 0.79 GB | **3.1 s / 0.88 GB** (canonicalization 2.1 s, invalidation 0.9 s, contribution reuse 0) |
| signature inference | 1.7 s / 0.86 GB | **1.2 s / 0.86 GB** |
| typing | 9.6 s / 4.30 GB | 1.2 s / 0.54 GB |
| ir generation | 7.3 s / 3.75 GB | 0.57 s / 0.18 GB |

Pass 2 is 6.3 s and 2.6 GB (65.7M objects, 10.8% of the 609M of a cold build) under load. Only typing and IR generation of the new module (1.8 s, 0.7 GB)
are work the program needs; semantic assembly and signature inference (4.3 s, 1.7 GB) re-run over the whole program to add a module that defines no
type, alias or enum case (`haxeon.DynamicOps` is a single class of static functions).

## Seeding: the saving is real

`HAXEON_SEED=haxeon.DynamicOps` (a temporary hook in `seedRepresentationModules`, not committed) puts the module in the graph from the start:

| | compile-count | peak RSS | restarts | functions retyped |
|---|---|---|---|---|
| unseeded | 609.69M | 5.35 GB | 1 | 31,317 |
| `haxeon.DynamicOps` seeded | **544.17M (-65.5M, -10.7%)** | **4.98 GB (-0.37)** | none | 31,316 |

The build succeeds and produces the program the restart produced. Seeding all eight request-able modules (the 2026-11-10 experiment) saved the same
66.9M objects. This is the cheapest possible removal of the second pass; what stops it is two things, both still true today:

1. **A module is only valid where its natives exist** (`ReactiveRuntime` on Wasm, `Std` without `CompilerIntrinsics.register`). A seed list needs a
   target and native predicate per module. `DynamicOps` itself needs none.
2. **Presence of the module changes the classification of unrelated code.** Reproduced today: with `DynamicOps` seeded, `SourceInlineEnumMain`
   ("Incorrect program-wide enum classification") and `MethodClosureValueMain` ("Enum callback unexpectedly boxed") fail. `CallbackValue`, which
   no code of the test passes to Dynamic, loses its inline storage.

## Does the provider and walk model fix blocker 2? Not as built

The hypothesis was: seeded helpers are unreachable, the early prune (step 3a) drops them before the program-wide passes, so they cannot change the
classification. I tested it. With the prune applied to every target (`HAXEON_PRUNE_WASM`, temporary) and even before the enum dispatch, the seeded
`MethodClosureValueMain` still fails with "Enum callback unexpectedly boxed". So the classification input is not (only) the unreachable functions:
it is something the prune does not remove, or something decided before IR assembly. Candidates, in the order I would check them:
- state that outlives the prune: the class objects and enum declarations of the seeded module's own types, natives, static initializers, the
  reflectable-object list (`IrProgramAssembler` computes it before the prune from the typed program);
- a typed-level flag: the typer marking an enum as escaping to Dynamic when *any* typed function (reachable or not) converts it, which is decided in
  typing or IR generation, before there is a program to prune.
The next experiment is to diff the inputs of `IrInlineEnumLowering` (and `IrInlineEnumEligibility`) between the seeded and unseeded builds of
`closure-method-value-arguments.hx` and see which element differs. Until that is known, "the walk makes seeding safe" is not established, and I
am not claiming it.

## On demand: what the provider model can and cannot do

A typed operation reaches a provider row in the *IR walk*, after the frontend. The module has to be loaded *before* its functions can be typed, so a
request for it is a frontend event; the walk cannot replace the continuation. What the new model contributes is only to make the module's *effect*
on the program demand-driven (an unreachable helper is dropped); it does not remove the need to load it.

So the continuation must be made cheap. The remaining blockers, verified in the code today:
1. **`aliasKey` is program-wide.** `SemanticAssembly` (`aliasKey = aliasUniverse.join(";")`, line 114; reuse test `canonicalAliasKey == aliasKey`,
   lines 170 and 315) joins every source alias and enum case of the whole program, so adding any module invalidates every module's canonical
   contribution (`contribution-reuse=0`, canonicalization 2.1 s). A module that defines no alias and no enum case does not change the *set* the key
   describes; a key that is the set (or a hash of the sorted set) instead of a join over module order, or per-module visibility (ADR 0003 M3/M4),
   would keep every contribution when a call-only module is added. This is the bounded fix: it removes the biggest part of pass 2 (semantic assembly
   3.1 s, 0.88 GB) without touching classification.
2. **`SemanticProgram.analyze` and `SignatureInference.inferProgram` are whole-program**; the only reuse is `replaceBodies` over identical
   declarations. Extending the analysis with a module is an operation that does not exist (1.2 s, 0.86 GB for signature inference alone). For a
   call-only module the existing functions' signatures do not depend on the new module's (their calls were typed with explicit signatures), so
   inferring only the new module's functions and leaving the rest is sound for that class of module, but it must be proved per module kind, not
   assumed.

## Options

| option | saves | needs | risk |
|---|---|---|---|
| A. alias key as a set, and extend signature inference for call-only modules | about 4 s and 1.7 GB of the 6.3 s / 2.6 GB (leaves typing and IR generation of the module) | `aliasKey` redefinition; an `extend` operation for the analyses of call-only modules | moderate; contained to the frontend; warm = cold must hold (test: add a call-only module in a warm session) |
| B. seed the request-able modules | all of pass 2: -65.5M objects, -0.37 GB, about 6 s | blocker 1 (predicates) and blocker 2 (unknown cause) | unknown until the classification input is found |
| C. make the Dynamic operations typed operations with generated providers (no stdlib module in the frontend at all) | all of pass 2 and the module's 39 functions in the frontend | provider generation on demand (3b), a typed operation per Dynamic operator | largest; the clean end state of ADR 0003 section 13 |

## Recommendation

Do A first: it is bounded, independent of the classification question, and takes the largest share (the semantic assembly) out of pass 2 for the
only module the app requests. Run the classification-input diff in parallel; if its answer is small, B becomes the cheapest total removal and A's
extension work is no longer needed for these modules. C stays the direction; A and B are steps toward it, and neither stands in its way.

## The leak, named and fixed (2026-11-12)

Seeding `haxeon.DynamicOps` flipped `CallbackValue` from inline to boxed storage. The eligibility reasons of the seeded and unseeded builds of
`closure-method-value-arguments.hx` differ in exactly one line, `CallbackValue: registered reflection layout`. The rule is
`IrInlineEnumEligibility`: when the program reflects over object layouts, every enum reachable by type from a registered layout (every class of the
typed program, plus anonymous, value and box classes) is blocked from inline storage, because the per-layout reflection helpers read and write the raw
packet and never box it. "The program reflects" was `ObjectReflection.usesObjectLayouts(program.natives)`, and `program.natives` is the declared native
surface of every loaded module: seeding `DynamicOps` loads `Reflect` (it calls `Reflect.compare`), whose module declares the `__reflect_object_*`
natives. Two inputs computed from what is loaded, not from what is reached: the declared reflection natives, and the list of all typed classes. Pruning
unreachable functions earlier (even before the enum dispatch, even for Wasm) changed nothing, which is how it was told apart from a function-level
leak.

Fix (plain builds): reflection is used when a reflection native is among the natives the walk reached (`IrTypeAwareWalk` returns `calledNatives`; the
early prune records them as `IrProgram.reachedNatives`; `ObjectReflection.usedByProgram` reads them where the program has been pruned and the declared
natives where it has not). Dynamic member access needs no special case: `raw.x`, `raw.x = v` and `raw.m()` compile to ordinary calls of
`Reflect.field` / `Reflect.setField` and a closure call, so they are calls of reflection natives in the reached IR.
`tests/compiler/UnusedModuleInvarianceMain` builds a program with and without an unused root module that itself calls `Reflect`, and asserts the same
enum storage and the same IR function for every function of the program; it fails when the detector is disabled (`CallbackValue=true` against
`CallbackValue=false`). The HashLink module does not become byte-identical yet: it lists the natives, classes and globals of every loaded module
(+17 natives, +14 types, +6 globals, same 18 functions in the test), so trimming those tables to what the program reaches is the remaining step for
"the output depends only on what it reaches".

Why not option D (box on reflective read, unbox on write, drop the rule): direct enum fields would work (the box/unbox helpers of
`IrInlineEnumEscapes` exist and the per-layout and Wasm table dispatchers share their bodies), but this leak is an enum that appears only in function
types (a static function field and method signatures with `CallbackValue->Int` parameters), which reflection exposes as closures; `supportsCallableEscape`
refuses an enum inside a nested function type, and arrays, maps and iterators of enums cannot be adapted on read (the reader must see the same storage).
D therefore needs closure adapters and still leaves container-reached enums blocked.

Live builds: they do not prune, so they keep the declared natives. This is edit-independent once the runtime modules are seeded for the target
(`Reflect` is then always loaded, so reflection is always "used" in live mode) and equals today's behavior until then. Representation may therefore
differ between a plain and a live build for these enums (inline in plain when nothing reflects, boxed in live); programs must not observe it, and
the corpus runs both modes.

`IrEnumDynamicDispatch` runs before the prune and still reads the declared natives (`usesObjectLayouts(reflectionProgram.natives)`); the
invariance test does not show it leaking, so the walk -> dispatch -> walk reorder stays a separate commit.
