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

(To be filled in by the diagnostic: conservative vs. type-aware, functions / objects / providers, for the self-hosting project and the app.)
