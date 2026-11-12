# Interface values: one model on every backend

Status: design note for review (no code yet). Direction from dev-71: **an interface value is the object itself, and a call dispatches through the
class**, as the Wasm backends already do. HashLink virtuals stay only for structural and anonymous types and for Dynamic views that need them.
Target: `InterfaceMountRepro` allocates 0 bytes for the conversions on HashLink, Wasm32 and Wasm GC.

## What happens today

- **IR.** `TToInterface` lowers to `ToVirtual(output, object)` with an output of type `Virtual(Interface)`. A call is `MethodCall` on a
  `Virtual` receiver. A test or cast to an interface is `__std_is_of_type` / `SafeCast` with a type argument.
- **Wasm32 and Wasm GC.** `toVirtual` keeps the class reference: a conversion allocates nothing. A call on a `Virtual` receiver is a closed-world
  dispatch over the implementors (`WasmFunctionLower.virtualTargets`): select the implementation from the object's class, call it directly. With no
  implementor the call lowers to `unreachable`.
- **HashLink.** `ToVirtual` becomes HL's `OToVirtual` (`hl_to_virtual`, `vendor/hashlink/src/std/obj.c`), which allocates a `vvirtual`: type, wrapped
  value, `next`, and one slot per interface member (24 + 8 n bytes: 32 for one method, 40 for two, as measured). `HlLower.interfaceSlotsFor` gives a
  class an unnamed field per interface it implements where the virtual is cached, so a second conversion of the same instance allocates nothing;
  the first conversion of each instance does, and so does an instance that is converted once. The repro converts 1,024 instances once to two
  interfaces: 2,048 virtuals, 73,728 bytes (`reference-interface-gap.md`). The cache field also adds 8 bytes to every instance per interface.
- **Cost of a call.** A call through a virtual is not cheap on HashLink: see the microbenchmark below (22 ns against 1.5 ns for a method table).

## The model

An interface value has the representation of its object (`Obj`). The IR keeps `Virtual(I)` as the *static* type so verification, dispatch and
tests know the contract, but `ToVirtual` between an object and its interface is a no-op on every backend (a retype), and `MethodCall` on a `Virtual`
receiver is lowered by selecting the implementation from the receiver's class:

- **Closed-world dispatch entry.** One generated function per (interface, method): `$typed-interface:I.m(receiver, arguments)`; the existing
  `IrTypedInterfaceDispatch` entries are the home of this (they already exist for value interface calls). Its body switches on the receiver's class
  id and calls the implementation directly. The arm of an implementor that is never constructed ends in `Unreachable`; so does the default.
  The Wasm backends do the same switch inline at the call site today; moving it into the entry lets HL and Wasm share it and lets calls inline
  the entry when it has one arm.
- **No per-instance cache.** The unnamed interface field in each class goes away (smaller instances, one fewer write per construction).
- **Structural and anonymous types** (`Virtual` of a structure, `{x:Int}`) keep HL virtuals. An *interface* type never is one.

## Semantics to preserve, one by one

1. **Identity and `==`.** Today `==` on two virtuals unwraps both (`hl_dyn_compare` on `value`), so two views of one object are equal, and a virtual
   equals its object. With the object as the value, `==` is reference equality of objects and gives the same answers. `Map` keys and `Reflect.compare`
   see the object. A value-interface box (struct in an interface) keeps its box object as the identity, as now.
2. **`Std.isOfType` and casts.** The test is on the object's class against the interface (`realtime_implements`, `IrTypeHashDispatch`): the object
   is what is tested today after unwrapping, so results do not change. A cast to an interface is a checked retype. Casting an interface value to a
   class is the existing class check. A *failed* cast must still throw the same catchable error.
3. **Conversions to and from Dynamic.** Today Dynamic holds the virtual, and `Reflect.field(view, name)` sees the *interface's* members. With the
   object, Dynamic sees all of the object's fields and methods. This is a visible difference for reflection on an interface-typed value. Haxe
   semantics on other targets expose everything, and `value-interface-reflection` (box classes) already tests the box case, so I propose to take the
   object's view, and to list the programs that depended on the narrower one (none in the corpus: the value-interface fixtures use boxes). Decision
   needed.
4. **Hot reload.** HashLink `cd615599a` keeps nominal virtual identities across module generations so a cached interface view survives an edit.
   Without virtuals for interfaces that machinery is not needed for them: the object is its own view. What replaces it is the *dispatch entry*: it
   changes when the set of implementors changes (a new class), so a live patch replaces the entry and callers keep calling it by name. Patch planning
   must treat the entry like any generated function (`Provider` kind, replaced when its row changes), and the interface type identity needed by
   `isOfType` stays in the type tables. The nominal metadata stays in use for the structural virtuals that remain.
5. **The native boundary.** Natives and FFI never receive interface views through the C ABI (projected records and primitives only). The runtime
   natives that touch virtuals (`native/runtime/reflection.c` unwraps a `HVIRTUAL`) keep handling them for structural types; with interfaces as
   objects they see fewer. The nativekit callbacks that take an interface-typed Haxe argument receive the object. To audit: each `HVIRTUAL` use in
   `native/runtime` (11 sites) for an interface assumption.
6. **Call cost.** Measured with `benchmarks/interface-call-cost/Main.hx` (HashLink, best of 5 runs of 20M calls, machine load about 7.5 on 20
   cores, so figures are preliminary; repeat on a quiet machine before relying on the third digit):

   | call | ns per call |
   |---|---|
   | direct class call (one class) | 0.8 |
   | **interface call today** (virtual adapter), 1 or 4 implementors | **22 to 24** |
   | class method table (hierarchy of 4) | 1.5 |
   | **class-id switch over 4 implementors** (the proposed dispatch, by hand) | **4.2** |

   The proposed form is about 5 times faster than today's virtual call at four implementors and is not slower for one. The cost grows with the
   number of implementors for a linear chain: for an interface with many implementors (UI components) the entry should use a jump table or
   binary search on the class id (`IrTypeHashDispatch` already emits the hash switch); measure at 8, 32 and 128 implementors before choosing the
   threshold. A per-class table in the runtime (an HL VM change) would be O(1) but is not proposed: HashLink changes go on `haxeon/main` only
   when necessary.

## How it fits the providers and the reachability walk

- The dispatch entry is a provider row `(Interface I, call m)` of kind `Provider`, found through `IrProviders` like the enum helpers. A
  `MethodCall` on a `Virtual` receiver is the typed operation that reaches the row; the walk then reaches the implementation of each *constructed*
  implementor (`IrConstructed`) through the entry, which is what it does for interface calls now.
- The entry's arms come from the walk's constructed set: an unconstructed implementor's arm is `Unreachable`. Today the entry would be generated
  from all implementors before the walk; generating it on demand from the walk's result is the 3b item "providers on demand" (`REACHABILITY_WALK.md`),
  and until then the arms of unconstructed classes are stubs (`Unreachable` bodies from the declaration-only slot), so nothing changes in what
  is kept.
- The class-table slots of an implementor keep their entries as declarations (the verifier resolves the call against the table), as now.
- Interface boxes of structs (`$value-interface-box:<Value>`) are created after the prune today; the entry for a boxed struct is generated with
  them. This is the second prerequisite already listed for on-demand helpers.

## Plan

1. Microbenchmark at several implementor counts, on a quiet machine (this note's table is preliminary).
2. IR: `ToVirtual` object to interface becomes a retype; `HlLower` stops emitting `OToVirtual` for interface types; interface `MethodCall`
   lowers to the dispatch entry on HashLink (Wasm keeps its inline switch until it can use the entry).
3. Remove the interface cache fields (`interfaceSlotsFor`) and check object sizes.
4. Reflection on an interface-typed Dynamic (decision 3), the native audit (5), and the live-patch case for an added implementor (4), each with a test.
5. Gate: `InterfaceMountRepro` allocates 0 on HL, Wasm32 and Wasm GC; the 889 driver cases pass in both prune modes; the live regression
   (retained object and interface view through edits, added implementors) passes.

## Open decisions

- Reflection view of an interface-typed value (3): the object's, or keep the narrower view by wrapping only when converting to Dynamic.
- Dispatch for many implementors (6): jump table / binary search threshold from measurements.
- Whether the Wasm backends move to the shared entry in the same change or later.
