# The type-aware reachability walk (ADR 0003 §13, migration steps 2 and 3)

Status: approved as the plan by dev-71 (2026-11-11), with the changes folded in below. Step 1, the diagnostic, comes first and decides whether
the prune is done at all (see "Decision gate"). The note is the walk and the prune of [ADR 0003 §13](adr/0003-compiler-architecture.md),
built on the unified function kinds ([PROVIDER_REQUESTS.md](PROVIDER_REQUESTS.md), superseded by `IrFunctionKind`) and placed in the phase
order of [ENUM_PASS_PHASE_ORDER.md](ENUM_PASS_PHASE_ORDER.md). It is not a second provider design.

## What exists

- `IrReachability` is a walk over name edges: calls, closures, and method calls over every class or implementor that could receive them.
  Wasm builders and the plain HashLink backend run it **after assembly** (`BackendAssembly`), so the passes still see every function typing
  produced, including unused helpers.
- **Live builds today.** A live HashLink module (`livePatching`) is not pruned: its host can call any function by id, and a reachability
  change must not move its layout. A plain HashLink build prunes from the entry (`withGeneratedRuntimeRoots(..., keepLiveClasses = true)`),
  where a class that a reachable function mentions by type keeps all its methods. The Wasm builders emit only what is reachable.
- Every function declares what it is: `IrFunction.kind`. `IrFunction.provides` maps a kind to a row `Serves(TypeKey, operation)`, and
  `IrProviders.rows/check` index and verify those rows (`$`-named functions must have a non-`Ordinary` kind; one function per
  (subject, operation)). That is the provider table, without a side table.
- The uses with no edge in the IR are becoming typed operations: `Intrinsic(EnumDynamicBox/View, EnumTagBox/Unbox, ...)` carry the subject
  type. `IrProviders.typedOperation(op)` (a1) maps such an intrinsic to `{subject, operation}`.

## The walk

State, all monotone, so a worklist reaches a fixpoint: `reached` (function names), `created` (the `TypeKey`s that can exist at run time),
`used` ((operation, subject-or-any) pairs seen at reachable sites).

Roots, each stated:

1. **The entry** of the build kind: the app's `main`, a test runner's entry, the live host's entry. Each build kind names its own.
2. **Static initializers**, and the types of the fields they initialize (those types are created).
3. **`@:keep` / `@:expose`** functions (`IrFunction.retention`), and the types in their signatures.
4. **Native callbacks**: the functions native declarations generate calls to (`generatedFunctionDependencies`), the enum and class
   constructors that a callback signature or a reflected native type names (their types are created), and reflection roots by Wasm's rules.
5. **Dynamic stringification**: each class's `toString` when `__std_string` is used, as now.
6. **Declared live-host entries** in builds that have a host.

Edges:

1. **Direct**: calls and closures by name.
2. **Method calls over created classes only** (new; today every class counts). A call to a method of class `C` reaches that method's
   implementation in `C` and in **every created subclass of `C`** (so inherited methods are reached through the subclass that inherits
   them, and each override in a created subclass is reached). An **interface call** reaches the implementation in each **created
   implementor** only; an implementor that is never created contributes nothing. A class that is only mentioned by type, not created, is
   in the layout but its methods are not reached through dispatch.
3. **Typed operation with a subject**: a reachable instruction `Intrinsic(op)` with `typedOperation(op) = {T, o}` adds `(T, o)` to `used`
   and reaches the row `(T, o)` of the provider table. A missing row is a check-mode error naming the instruction.
4. **Dynamic site over all types**: dynamic equality, compare, hash, `toString`, dynamic enum test, reflection field access. The site is
   an operation with no subject; it reaches the rows `(T, o)` of every **created** `T`. When `created` grows, the rows are revisited.
5. **Kinds**: a copy kind (`ScalarArguments`, `OptionalScalar(original)`, `ClosureAdapter`, ...) is reached by name from its callers and
   brings nothing of its own. `EnumEquality`, `EnumDynamicUnbox`, `EnumTagAdapter` and `ValueArraySlot` are reached only through their
   rows, so an enum's helpers disappear with the enum. A helper that serves a (type, operation) is a `Provider` row; `GeneratedHelper` is
   only for helpers with **no subject**. There are no name-based keep lists anywhere: a target-only helper without a kind is a bug to fix
   before the prune, and the diagnostic lists every one it finds.

`created` is deliberately coarse in the first version, and the over-approximation is documented here: a type is created when a reachable
function constructs it, converts to it (`ToDynamic` or cast target), or has it in a native boundary signature, a static field or an
object field of a created class, and when a root marks it. It is a type *mention*, not a construction site. A coarser `created` only keeps
more, never miscompiles. Refine to construction sites only if the diagnostic numbers say the difference is worth it.

## Where it runs (step 3)

ENUM_PASS_PHASE_ORDER puts reachability first (phase 1), but the enum providers do not exist then: `IrEnumDynamicDispatch.rewrite`
(`IrProgramAssembler`, before generic owner erasure) synthesizes them from all enums present.

- **3a**: the sequence is **walk → dispatch(created, used) → walk**. `IrEnumDynamicDispatch.rewrite` and
  `IrEnumRuntimeSpecializations.materialize` take the created set and the used operations as parameters instead of reading "all enums in the
  program"; no reachability call appears inside the enum code and there is no hidden global. The second walk is the same function
  (`IrReachability`), rerun on the grown program; it is not a second walker. The prune happens after the second walk, before generic owner
  erasure, boxes, scalar rewrites and inlining, so everything after sees the reachable program. Dispatchers are built from reachable
  providers only.
- **3b** (later): move provider generation to demand, driven by typed operations, so one walk before everything is enough (phase 1).
  3b removes the first walk without changing the dispatch's signature beyond its input. It depends on a1's producers.
- The backends' own prune after assembly stays until it removes nothing in check mode, then goes. Until then the same `IrReachability` is
  called from both places.

**Live and hot-reload builds.** The first version does not prune live builds: a patch can still call any function, and a reachability
change must not move the module's layout. This matches the backends today. The walk and the invariant still run on live builds in check
mode (so a missed edge is caught there too) and the prune is skipped; revisit after measuring. This is also why the driver runs every
program case pruned and unpruned, plain and live.

## Prerequisite of the prune: dynamic sites are typed, not named

The diagnostic finds a dynamic site by the **name of the native** it calls (`IrTypeAwareWalk.defaultDynamicSites`: `__dynamic_equal`, the enum
dispatch's `REFLECT`, `__std_is_of_type`, `__std_is_exact_type`). That is accepted for the diagnostic only, and it is incomplete: dynamic
`toString` / `Std.string`, `Reflect.compare`, `Reflect.field` / `setField` / `callMethod`, `Type.getClass` / `enumIndex` / `enumParameters` /
`enumConstructor`, `Std.downcast` and the dynamic map-key hash are sites too. Before step 3 prunes anything:

- the list comes from the native registry in **one place**, with a test that fails when a type-dispatching native is not classified (so a new
  native cannot be forgotten); and
- the long-term form replaces names: the instruction carries a typed operation with an any-subject operation (an a1 marker-family item),
  and the walk reads the operation from the instruction.

`keepCreatedClassMethods` (every method of a created class is reached, as a mentioned class keeps its methods in the plain HashLink prune
today, because `Reflect.field` can reach a method by name) goes away once reflective field access is such a dynamic site: it then reaches the
methods of created classes by itself.

## The invariant (decision 4)

In check mode, after each pass, every call target is in the function set and is either in the reachable snapshot or in the set of functions
the pass created. A violation names the pass and the call. This turns the failure of 2026-11-10 (a late pass calling a pruned helper) into a
test failure. Cost: one set lookup per call edge, check mode only.

## Evidence and gates

1. **Step 1, the diagnostic (no behavior change).** Run the new walk next to the conservative one on the program corpus, the self-hosting
   project and the app, and print how many functions, objects and providers each keeps, plus the list of helpers that have no kind. The
   "every typed operation has a provider" check (`IrProviders.check`, built on `typedOperation`) lands here, as a check-mode error; it does
   not need the prune and catches a missing producer early. Its timing is coordinated with a1's producer commit through dev-71.
2. **Decision gate.** Record the kept functions, objects and providers of the conservative and the new walk for self-hosting and the app in
   this note. If both keep less than about 5% fewer functions than the conservative walk, stop after step 2 and do not do the prune.
3. **Pruned and unpruned equal** (decision 6): the driver runs both on every program case, plain and live.
4. **Warm equals cold with the prune on.** In step 3 the warm-edit sweep and `HAXEON_CHECK_REUSE=1` run with the prune on, not just in step
   1. An edit that changes the reachable set must give the same bytes as a cold build. The walk's result must be a function of the
   program graph, so cached results stay valid; this is confirmed by those runs.
5. Gates: `gate.sh wave` per commit (warm-edit sweep included), `full` and the outer app gates before publishing. The cold-build effect is
   measured with `scripts/measure-cold.sh` (the app and `self-hosting` targets).

## Results of step 1

Measured 2026-11-11 with `HAXEON_REACHABILITY_REPORT=<file>` (`IrReachabilityReport`; off unless set, changes nothing) on warm-rebuild-reuse
at a7bf4778a plus the report. Two positions: **after `IrEnumDynamicDispatch.rewrite`** (the 3a prune point, before every later pass) and
the **final program** (what the backends receive). *All* is every function present; *today* is `IrReachability.withGeneratedRuntimeRoots`
(what the plain HashLink prune keeps); *type-aware* is `IrTypeAwareWalk` keeping every method of a created class (the safe variant);
*called only* is the same walk reaching only called methods (not safe while `Reflect.field` can reach a method by name).

| program | position | functions: all | today | type-aware | called only |
|---|---|---|---|---|---|
| 40 largest `tests/programs`, summed | after dispatch | 3856 | 2443 | 2434 | 2152 |
| | final | 6034 | 2669 | 2669 | 2104 |
| self-hosting project | after dispatch | 5297 | 4922 | 4922 | 4704 |
| | final | 5396 | 4620 | 4620 | 4159 |
| Materia app (outer main + classpath patch) | after dispatch | 32520 | 26375 | 26180 | 22528 |
| | final | 35281 | 23873 | 23744 | 19430 |

**Decision gate: passed.** At the prune point the passes see every function; a prune there keeps 63% (corpus), 93% (self-hosting) and 81%
(app) of them, and 20% fewer functions would be run through the passes in the app. The 5% bar is met by the app and the corpus; self-hosting
is 7.1%. The final-program column is the output-size effect and is today's prune already.

What the numbers say about the walk itself:

- The gain at the prune point comes from pruning before the passes at all. The type-aware walk with whole-class method keeping keeps the same
  functions as today's (the app: 195 fewer, 0.7%); its extra reach is in providers (the app, final program: 1230 against 1210, since it
  also keeps providers a dynamic site reaches over created types).
- The real extra saving is the *called only* column: at the prune point a further 11 percentage points of all functions in the app (30.7% off against 19.5%), 4 in self-hosting and 7 in the corpus.
  It needs reflective field access to be a typed dynamic site first (see the prerequisite above), because it drops methods that are reachable only by name.
- Objects with a reached method: the app 8850 -> 1593 (today) -> 1571; self-hosting 1399 -> 148; the corpus 933 -> 221 -> 217.
- No `$` function without a kind in any of the three (kindless helpers: 0), so the prerequisite "no target-only helper without a kind" holds on these.
- Not measured: the effect of the prune on pass time, which is step 3's evidence (`measure-cold.sh` before and after).

## Step 3a, first cut (on by default for plain HashLink builds; HAXEON_EARLY_PRUNE=0 turns it off)

`IrEntryPrune` prunes a plain HashLink build inside `IrProgramAssembler.assemble`, **after generic owner erasure** and before every later
pass (value interface boxes, typed interface calls, checked casts, enum lowering, optional flows, reflection and, after `assemble`, the passes
of `FrontendCompilation`). The point is not the one measured in step 1 (right after enum dispatch): before erasure the walk does not know
the erased owner of a generic class (`Derived<Payload>` is the class `Derived` only once erasure has renamed it), so `Derived.get` was pruned
and the erasure's own devirtualization silently did not happen. Erased-owner naming in the walk is **3b**; the prune point moves earlier then.

- **Walk.** `IrTypeAwareWalk` alone (whole created classes): a class that is only mentioned and never created keeps none of its methods. A first
  cut united it with today's walk (`IrReachability.withGeneratedRuntimeRoots`, mentioned classes keep their methods); the corpus and the
  driver pass without the union, so it is gone. On ten corpus programs the only extra thing dropped is `StringBuf`'s four methods
  (`addChar`, `addSub`, `get_length`, `toString`): the class is mentioned and never created.
- **Roots.** `main` (or the entry), the static initializers and `__init`, the exported functions, and every `@:keep` / `@:expose` function. The
  callbacks of natives and the toString methods come from the existing walk.
- **Typed demands the walk reads** (what a later pass asks for without a call edge): a struct's equality row (a `__dynamic_equal` site reaches
  the rows of the created types), and the value method behind an optional-field request
  (`IrOptionalFieldStorage.requestedMethod`, read by the walk when it meets the request call). `IrValueDynamicDispatch` no longer falls back
  to a runtime "does not conform" throw for a struct that declares `Equatable`: a missing provider is an internal compile error.
- **Detection, in check mode (HAXEON_CHECK_REUSE=1).** `IrProgram.prunedFunctions` is the set the prune removed.
  - `checkRemoved` runs after each later pass in `assemble` and at the end of the pipeline: no call or closure may name a removed function.
  - `IrFunctionIndex` is the one by-name view of the function list for the nine passes that built their own maps; a lookup of a removed name
    throws, naming the pass and the function. A pass that needs a function the prune would remove must ask for it by (type, operation).
  - Method-table lookups (`IrProgramIndex.findMethod`, the erasure's and the typed interface dispatch's `findMethod`) throw when they visit a
    class whose entry for the method the prune removed. Other readers of `IrObject.methods` (about 30 files) are not covered yet.
- **Evidence.** `tests/programs` is built plain, unpruned and pruned, with the driver's third run (`Main --no-early-prune`, the reference) and the warm-edit sweep
  under HAXEON_CHECK_REUSE=1 (545 programs pruned warm: each rebuild equals a fresh build). On the 582 programs that build as HashLink: 0
  differences in exit code, 0 invariant or lookup hits. Bytes differ in 64: in 51 only the runtime natives imported differ (a native only
  unreachable code needed is gone); in 10 the four `StringBuf` methods are gone (class mentioned, never created); in 3
  (`scoped-cleanup`, `key-path-semantics`, `enum-generated-dependencies`) types differ: the scalar ABI of key-path closure fields
  (`$get` is `fun(owner,ref<i32>,ref<i32>)->void` unpruned and `fun(owner)->struct SpecPoint` pruned). The scalar-argument pass rewrites a
  closure field's signature only when the closures stored in it are present, so an ABI choice depends on which functions are present;
  a pruned build is deterministic (built twice, equal bytes) and a warm build equals a cold one, so it does not break warm = cold.

### Removal and 3b items of step 3a

- **Removal.** `HAXEON_EARLY_PRUNE=0`, `Main --no-early-prune` and the driver's unpruned reference run are a migration reference, not a product option, and
  there is no user-facing fallback. Delete the switch, the flag and the unpruned run (and the gate.sh coverage field for it) when 3b lands, or after
  the pruned path has been the default through two pushes, whichever comes first.
- **3b: a closure field's ABI from its type.** The scalar-argument pass chooses the ABI of a closure field (the `$get` / `$set` fields of key-path classes)
  from which closures exist, so an unreachable key path's field ABI changes with the prune (`key-path-semantics`). It is benign (deterministic,
  and no reachable code reads the field), but the field's ABI should follow from the field's type, not from the presence of functions.

### Prerequisites for generating helpers only on demand, and what reads `result.ir`

Reflection helpers (`ObjectReflection.generate`) are written for every class whenever a reflection native is declared, not on demand. Two places
where the walk sees less than the program uses stop that today:

1. **Dynamic field access** (`raw.x` on a Dynamic) becomes the reflection natives only at lowering, so no call names them and the walk never sees
   the use. A filter on "natives something calls" dropped the helpers of a program that used them (`wasm-value-interface-reflection`, exit 3).
   It belongs to a1's typed dynamic sites: the access must be a typed operation in the IR before the walk.
2. **Interface box classes** (`$value-interface-box:<Value>`) are created after the prune, so they are never in the walk's created set (a filter
   on created classes dropped their helpers). They must exist, or be declared as a provider for (type, box), before the walk: a 3b item with the
   provider generation on demand.

Once both exist, the helpers can be generated only on demand, from the walk's result.

`CompileResult.ir` of a plain HashLink build is the emitted program (pruned); a live or Wasm build's is complete. Readers checked: the
Android build looks only for `main`; `CompilerDriver --ir-output` writes the emitted program; the reachability report's "final program" counts
start from the already pruned program; the tests that read `ir.functions` run in the gate (`ReachabilityPruneMain` and
`GeneratedEqualityProvenanceMain` follow the contract above).

### The native contract (what a native constructs)

Both walks use one rule (`IrConstructed`): **a native constructs exactly the class its declaration returns**, an `IrNative` or an `IrCNative` alike, and
no other. Not a subclass of the declared class, and not an argument's class: an argument was constructed by its caller, which a walk sees, and a native
that hands an argument back returns a value that already existed. A callback into Haxe is about a method being reachable, not a class being
constructed: a closure given to a native is built by a `StaticClosure` / `InstanceClosure` the walk follows, and the functions a native's lowering
calls are its `generatedFunctionDependencies`. Native code that builds an instance of a class chosen at run time has to be given that class, as a
`Class<T>` or a type argument, which is a typed reference a walk counts as created; subclass expansion would only over-approximate and would keep the
owned-handle wrappers that 9d57e32e8 removed from Wasm modules.

Audit (2026-11-12), natives allocating a Haxe object: `native/runtime/reflection.c` `__reflect_copy` allocates an instance of its argument's own class
(`hl_alloc_obj(object->t)`: a copy of something the caller constructed), `hl_alloc_dynobj` makes an anonymous dynamic object, and the others allocate
boxes of primitives (`hl_alloc_dynamic`). The std natives the stdlib binds (`thread_create`, `make_var_args`, `tls_*`, `hoalloc`, `mutex_alloc`, ...)
return abstract pointers, closures or Dynamic values handed in earlier. The HashLink libraries that allocate objects (`libs/sdl`, `libs/mysql`,
`libs/directx`) are not bound by the project. FFI natives are C functions on the C ABI and build no Haxe object. No native was found that allocates a
class its declaration does not name. There is no cheap check-mode assertion that a returned object is an instance of the declared class: it would be a
run-time check in the native's library, which this compiler does not own.

### The declaration-only slot (replaces the receiver-own-method rule)

The verifier resolves a method call against the receiver class's table, so a reachable call on a class that nothing constructs (a base class) needs that
class's table entry. The first rule kept the whole method for it (4bbb1e754), which also kept whatever the body calls: on Wasm that would bring back
the owned-handle wrappers 9d57e32e8 removed. Now the walk records such a method as `declarationOnly` (not in `reached`) and `IrEntryPrune` keeps the
entry with a stub: same name, signature and kind, and a body that is a single `Unreachable` terminator. `Unreachable` is the one IR terminator for
"control cannot arrive here by construction" (no value, no successors, verified, in the canonical codec); it is not an exception, so Haxe code cannot
catch it (an earlier version threw a Dynamic string, which `catch (e:Dynamic)` could have swallowed, and cost a string and a conversion per stub).
Wasm lowers it to `unreachable`, HashLink to the fatal runtime native `__unreachable` (`hl_fatal`: an abort with a message, since HashLink's own
`OAssert` raises a catchable error). The Wasm lowering of an unreceivable call (9d57e32e8) and of an interface method without an implementation
already emit that `unreachable` instruction. Nothing can receive the call, so the trap is never run; the body's callees are not reached. If a class
later turns out to be created, its method is reached with its body. `UnreachableTerminatorMain` checks the abort on HashLink and the trap on both
Wasm backends, and the codec round trip.
The Wasm builders do not prune at this point; when they use the shared walk, the same stub is what they lower (a throw lowers to a catchable
exception on both backends).


### Follow-ups after the Unreachable terminator

- **One representation of "unreachable".** The Wasm call-site traps (an interface method with no implementation, and the unreceivable class call of
  9d57e32e8) are emitted as the `unreachable` instruction by `WasmFunctionLower` at the call site. They should become IR `Unreachable`, lowered once,
  so the IR says it and HashLink gets the same behavior for those cases (today HL has no equivalent for them). Not urgent.
- **Whole-tree type check in the gate.** `gate.sh` runs `type-check-all` (every module of `compiler` and `build`) from `quick` up, so a switch over
  an IR enum in a module that only tests compile cannot break a wave again. (`EnumAbstractHints.hx`, an orphan that did not compile, was deleted on
  main in f33ec9256, so the stage keeps no name list.)
