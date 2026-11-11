# The type-aware reachability walk (ADR 0003 §13, migration steps 2 and 3)

Status: proposal for dev-71 review; no code until it is reviewed. It is the walk and the prune of [ADR 0003 §13](adr/0003-compiler-architecture.md),
built on the unified function kinds ([PROVIDER_REQUESTS.md](PROVIDER_REQUESTS.md), now superseded by `IrFunctionKind`) and placed in the phase
order of [ENUM_PASS_PHASE_ORDER.md](ENUM_PASS_PHASE_ORDER.md). It is not a second provider design.

## What exists

- `IrReachability` is a walk over name edges: calls, closures, and method calls over every class or implementor that could receive them.
  Roots are the entry, `@:keep`/`@:expose` functions, `toString` implementations for dynamic stringification, and the functions native
  declarations generate calls to. Wasm builders and the HashLink backend run it **after assembly** (`BackendAssembly`), so the passes
  still see every function typing produced, including unused helpers.
- Every function declares what it is: `IrFunction.kind`. `IrFunction.provides` maps a kind to a row `Serves(TypeKey, operation)`, and
  `IrProviders.rows/check` index and verify those rows (`$`-named functions must have a non-`Ordinary` kind; one function per
  (subject, operation)). That is the provider table, without a side table.
- The uses with no edge in the IR are becoming typed operations: `Intrinsic(EnumDynamicBox/View, EnumTagBox/Unbox, ...)` carry the subject
  type. `IrProviders.typedOperation(op)` (a1) maps such an intrinsic to `{subject, operation}`.

## The walk

State, all monotone, so a worklist reaches a fixpoint:

- `reached`: function names. `created`: the set of `TypeKey`s that can exist at run time. `used`: (operation, subject-or-any) pairs seen at
  reachable sites.

Edges:

1. **Direct**: calls and closures by name, and method calls over created classes, as now (restricted to *created* classes, which is
   the new part: today every class counts).
2. **Typed operation with a subject**: a reachable instruction `Intrinsic(op)` with `typedOperation(op) = {T, o}` adds `(T, o)` to `used`.
   The row `(T, o)` of the provider table, if any, is reached. A missing row is a check-mode error naming the instruction (the
   "every typed operation has a provider" check, `IrProviders.check`, once a1's producers are in).
3. **Dynamic site over all types**: dynamic equality, compare, hash, `toString`, dynamic enum test, reflection field access. The site is
   an operation with no subject; it reaches the rows `(T, o)` of every **created** `T`. When `created` grows, the rows are revisited.
4. **Kind-specific**: a copy kind (`ScalarArguments`, `OptionalScalar(original)`, `ClosureAdapter`, ...) is reached by name from its
   callers and brings nothing of its own. `EnumEquality`, `EnumDynamicUnbox`, `EnumTagAdapter` and `ValueArraySlot` are reached only
   through their rows, so an enum's helpers disappear with the enum.

`created` (the soft spot): a first version counts a type as created when any reachable function constructs it, converts to it
(`ToDynamic`/cast target), or has it in a native boundary signature, a static field or an object field of a created class. Anything that
cannot be placed (reflection by Wasm's rules, native callbacks, declared live-host entries) is a root that marks its types created.
Construction sites refine it later; a coarser `created` only keeps more, never miscompiles.

## Where it runs (step 3)

ENUM_PASS_PHASE_ORDER puts reachability first (phase 1), but the enum providers do not exist then: `IrEnumDynamicDispatch.rewrite`
(`IrProgramAssembler`, before generic owner erasure) synthesizes them from all enums present. So step 3 has two parts:

- **3a** (this proposal): run the walk and the prune **right after** `IrEnumDynamicDispatch` and `IrEnumRuntimeSpecializations.materialize`, before
  generic owner erasure, boxes, scalar rewrites and inlining. Providers exist as rows, so rule 2 and 3 work unchanged. Everything after
  that sees the reachable program. Dispatchers that the enum code builds over "all enums" must be built over reachable providers: that
  means running the walk once before `IrEnumDynamicDispatch` to decide which enums are created (rules 1 and 3 without providers), then
  once more after it. Two walks, both linear.
- **3b** (later): move provider generation to demand, driven by typed operations, so one walk before everything is enough (phase 1).
  This depends on a1's producers and is not part of the first prune.

The backends' own prune after assembly stays until it removes nothing in check mode, then goes (no second walker: the same
`IrReachability` is called from both places until then).

## The invariant (decision 4)

In check mode, after each pass, every call target is in the function set and is either in the reachable snapshot or in the set of functions
the pass created. A violation names the pass and the call. This turns the failure of 2026-11-10 (a late pass calling a pruned helper) into a
test failure. Cost: one set lookup per call edge, check mode only.

## Evidence and gates

1. **Diagnostic first, no behavior change**: run the new walk next to the conservative one on the program corpus, the self-hosting project
   and the app; print how many functions, objects and providers each keeps. The step is worth doing only if the difference is large; the
   self-hosting and app numbers decide.
2. Equal behavior of pruned and unpruned builds (decision 6): the driver runs both on every program case.
3. Gates: `gate.sh wave` per commit (warm-edit sweep included), `full` and the outer app gates before publishing.
4. Cold-build effect measured with `scripts/measure-cold.sh` (app and `self-hosting` targets), and the warm-rebuild reuse unchanged: the
   walk's result must be a function of the program graph, so cached results stay valid (it reads module reachability that reuse already
   tracks; this is to be confirmed in step 1 by running `HAXEON_CHECK_REUSE=1`).

## Questions for review

- Is two walks in 3a acceptable, or should the enum dispatch be changed to take the created set as an input instead?
- Is a coarse `created` (mention, not construction) the right first cut?
- Should the "every typed operation has a provider" check land with step 2 (the diagnostic) rather than with the prune?
- Wasm GC and Wasm32 reach providers through the same rows; any target-only provider (a linear-memory helper) must be a `Provider` or
  `GeneratedHelper` kind before the prune, or its callers keep it by name. Is that the intended reading of `GeneratedHelper`?
