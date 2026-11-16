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

## Dispatch options, measured

`benchmarks/interface-dispatch/generate.py N out.hx` generates the benchmark for N implementors (1, 4, 32, 128). Each figure is the best of 3 runs of
10M calls over 1,024 objects of N classes, in ns per call; two full series agreed to within about 10%. The machine was loaded (load about 10 on 20
cores), so read the ratios, not the digits. HashLink, Haxeon plain build.

| implementors | today (virtual) | linear chain | `switch` | binary search | selector table, id in a field | selector table, id by class method |
|---|---|---|---|---|---|---|
| 1 | 23.5 to 24.3 | 2.4 | 2.4 | 2.4 | 3.3 | 3.7 to 4.1 |
| 4 | 22.6 to 23.8 | 4.6 | 4.1 | 4.7 | 3.9 to 4.0 | 4.5 |
| 32 | 23.4 to 23.6 | 11.3 to 11.7 | 7.8 to 8.0 | 6.0 | 4.0 to 4.2 | 4.5 |
| 128 | 26.6 to 27.1 | 39 to 41 | 21 | 7.3 | 4.7 to 4.8 | 5.1 to 5.8 |

- **Selector table** (dev-71's option c): one global function array; the call is `table[classId + selectorOffset(I.m)](receiver)`: an array
  get and a closure call, O(1) with no VM change. It is flat from 1 to 128 implementors. A `switch` on the id is not a jump table in the HL
  lowering today (it is 21 ns at 128, close to the linear chain half-way), and the binary search grows slowly (2.4 to 7.3).
- **Where the class id comes from.** A field costs 8 bytes per object (the same 8 bytes the removed interface cache field takes, per interface
  implemented; a net saving only for classes that implement two or more interfaces). Reading it through a class method (`cid()`, a method-table
  call, 1.5 ns) needs no per-object storage and costs about 0.5 to 1 ns over the field at every size. HashLink has no dense class id on `hl_type`
  to read, so the method is the choice that needs no VM change.
- **Recommendation: one mechanism, the selector table with the class id read through a method.** It is at most about 1.5 ns slower than the best
  alternative at 1 to 4 implementors and the fastest or equal from 32 up, with no size threshold. Inlining a dispatch entry that has one arm is an
  optimization of it, not a second mechanism. Wasm has the same shape natively: a table of functions and `call_indirect` (in the same series, below).
- **What it needs.** Dense class ids (assigned by the compiler, in a deterministic order, stable across the edits of a live session: a class keeps
  its id and a new class takes the next free one); a `selectorOffset` per (interface, method) so the rows do not overlap (an offset assignment
  over the class-id ranges of each interface's implementors, as in Dart); the table is a generated function array of `Unreachable` entries for
  every slot no constructed class fills. The table and the offsets belong to the provider row, not to the backend.

## Visible changes

- Reflection on an interface-typed value held as Dynamic shows the **object's** members, not only the interface's (`Reflect.fields`,
  `Reflect.field`, `Reflect.hasField`). It matches Haxe on other targets; keeping a narrower view would bring back an allocation and a second
  representation (decision of 2026-11-12). A corpus program pins it when the change lands: `Reflect.fields` of an interface-typed Dynamic lists the
  object's fields. (It cannot go into the corpus before, because it fails today.)
- Instances of classes that implement interfaces get smaller by the interface cache fields (8 bytes each).
- `Dynamic` casts to an interface type become a class check on the object. HashLink's runtime cast paths (`hl_dyn_cast*` to an `HVIRTUAL` of an
  interface type) must never be reached for interface types afterwards; if one is, it needs a typed replacement, not a fallback.

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

0. Done: the call-cost benchmark (HashLink), the dispatch options at 1, 4, 32 and 128 implementors (above). To repeat on a quiet machine.
1. IR: `ToVirtual` from an object to its interface is a retype; `HlLower` stops emitting `OToVirtual` for interface types; an interface `MethodCall`
   becomes a call of the dispatch entry, whose body is the selector-table call; class ids and selector offsets are assigned by the compiler (a
   provider row `(Interface, call)` whose fingerprint includes the constructed set, so that adding an implementor invalidates it, warm and cold alike).
2. Remove the interface cache fields (`interfaceSlotsFor`) and check the object sizes.
3. Wasm moves to the same entry in the same series, as its own commit inside the same push, so no release has two dispatch codegens. Gate:
   Wasm module sizes and the wasm-parity corpus do not get worse.
4. Tests: the reflection view (above), the native audit (the 11 `HVIRTUAL` sites in `native/runtime`), a warm-edit test that adds an implementor and
   must equal a cold build under `HAXEON_CHECK_REUSE=1`, the live patch of an added implementor, and the `hl_dyn_cast*` check above.
5. Gate: `InterfaceMountRepro` allocates 0 bytes on HashLink, Wasm32 and Wasm GC; the driver passes in both prune modes; the live regression
   (a retained object and its interface view through edits and added implementors) passes.

## Open decisions

- Dense class ids: where the compiler keeps the numbering so a live session keeps it stable, and what the id of a class reloaded under a new
  generation is.
- Whether the selector offsets are packed (Dart's coloring) or one block per interface at first; start with one block per interface and measure
  the table size on the Materia app.

## Implementation log

1. **IR (this step, no behavior change).** `ClassId(output, object)`: an I32, verified (object or interface value in, I32 out), in the canonical
   codec and state equality, interpreted from `IrProgram.classIds`; no backend lowers it yet (they fail loudly). `IrClassIds` is the persistent
   assignment: a class keeps its id, new classes take the next ids in name order, a removed class's id is never reused, a cold build assigns by name
   order whatever the order the classes arrive in. How the warm = cold check accounts for a live session's ids: the state carries them, so the cold
   side of the check starts from the same `IrClassIdState` (the ids are an input, like the cached IR); a state-free cold build is compared with
   another cold build for determinism. `MethodCall` on a `Virtual` receiver stays the IR form of an interface call; the dispatch entry that lowers
   it is generated IR (`ClassId`, a table get, `CallClosure`), so no separate `InterfaceCall` instruction is needed. `ToVirtual` from an object to
   an interface stays an instruction and becomes a retype in the HashLink lowering (step 2).

