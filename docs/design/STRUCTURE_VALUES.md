# Structure values: open anonymous types and width subtyping (design note)

Status: in progress; decisions 1 to 5 taken by the user; slices 0, 5 (open literal structures) and 6 (`localExpectedTypes` deleted) have landed, see "As built".
Architecture plan step 2.6 (`../reports/2026-11-architecture-review.md`), approved as a step by the user on 2026-11-18;
this note is its design.
Follows 2.3 (type variables) and runs beside 2.5 ([LAZY_DECLARATION_TYPING.md](LAZY_DECLARATION_TYPING.md)), with
which it shares `BodyTyper`. Its representation half applies the model of [INTERFACE_VALUES.md](INTERFACE_VALUES.md)
to structures, and the dispatchers of erased generic owners
([GENERIC_SPECIALIZATION.md](../reference/GENERIC_SPECIALIZATION.md)) become one case of it. haxeon-e4, who owns HL
lowering, reviews the note before it is sliced.

## Problem

Haxeon lowers each distinct field set of an anonymous structure to a class of its own, `$anon:{a:Int,b:String}`
(`SemanticSignature.anonymousTypeName`, `IrProgramAssembler.objectsFrom`, `IrGenerator.lowerType`:
`TAnonymous(name, _) → Obj(name)`). A value of a structure type is an instance of exactly that class. Every divergence
below follows from it:

1. **Literals do not gain optional fields.** `var c = {name: "y"}; var d:{name:String, ?optional:Bool} = c;` is
   `E1002`. To make `arguments.push({name, type, span, optional, defaultValue})` in `Parser.hx` work, `BodyTyper`
   keeps a look-ahead pass (`inferBodyLocalTypes`, `localExpectedTypes`, `MonomorphCell.hint`) that types the literal
   in the context of a later use. The same pass lets `var values = []; values.push(1); return values;` compile as an
   `Array<Float>`, which Haxe rejects (`d1de40d1`, the 2.3 entry of the plan).
2. **No width subtyping.** `c618c16d8` added it for final fields only, by copying the value into the narrower record,
   so `narrow == wide` is false, writes are lost and `Reflect` sees the narrow fields. It is reverted, and this step
   brings width subtyping back with identity.
3. **No class or interface to structure**, no structure variance in `Array` parameters or function types, no
   optional/required unification, and `Dynamic` to a structure copies (`ConversionResolver.dynamicStructure`).

On HashLink, Haxe types every structure slot as a virtual (`HVirtual`), a view that points at the fields of the
object it wraps. Views of one object share it, so writes go through and identity holds. Wasm has no virtuals.

## What Haxe 4.3.7 does

Each row was run with the pinned compiler (`-hl`, HashLink JIT) and with today's Haxeon. The programs are kept with
the step's tests (slice 4); "copy" means Haxeon accepts but the view is a separate object.

| Case | Haxe 4.3.7 | Haxeon today |
|---|---|---|
| `var c = {name:"y"}; var d:{name:String, ?optional:Bool} = c;` | ok; `$type(c)` becomes `{?optional, name}` | E1002 |
| `var a = []; a.push({name:"x"}); f(a)` with `f(a:Array<{name:String, ?optional:Bool}>)` | ok; the element type gains `?optional` | ok (through `localExpectedTypes`) |
| `useA(c); useB(c)`, wanting `{name, ?x}` and `{name, ?y}`, either order | ok; `c` gains both; the set does not depend on order | E1009 |
| `useN(c)` wanting `{name}`, before or after `useA` | ok; a narrower use does not close the literal | E1009 at `useA` |
| a declared `{b:Int}` (not a literal) to `{b:Int, ?a:Int}` | **error**: `{ b : Int } has no field a` | error |
| `var values = []; values.push(1); return values;` as `Array<Float>` | **error**: `Int should be Float` | accepted |
| width, var fields: `var n:{a:Int} = w; n.a = 5;` (`w = {a:1, b:2}`) | ok; `w.a` is 5; `n == w` is true | E1002 |
| width, final fields | ok; identity true | copy; identity false |
| a literal with an extra field against an expected type | **error**: `has extra field y` | error |
| the same through a variable (`var q = {x:1, y:2}; var p:{x:Int} = q;`) | ok | E1002 |
| `{a:Int}` to `{a:Float}`; `{a:Child}` to `{a:Parent}` (var) | **error**: var fields are invariant | error |
| `{final a:Int;}` to `{final a:Float;}`; final `Child` to final `Parent` | ok: final fields are covariant | copy |
| `{a:Int}` to `{final a:Int;}` and back | **error** both ways (`Cannot unify final and non-final fields`) | accepts var to final |
| `{?a:Int}` to `{a:Int}`, and `{a:Int}` to `{?a:Int}` | ok both ways (an absent `a` reads 0) | E1002 |
| `{a:Int}` to `{var a(default,null):Int;}` | ok (aliases) | parse error |
| `(default,null)` or `(get,never)` field to a plain `a:Int`, or the reverse to `(get,never)` | **error**: `Inconsistent access/setter` | parse error |
| `Array<{a:Int, b:Int}>` to `Array<{a:Int}>` (var or final) | ok | E1002 |
| `({a:Int})->Void` where `({a:Int, b:Int})->Void` is expected (contravariant argument) | ok; the reverse is an error | E1009 |
| `()->{a:Int, b:Int}` where `()->{a:Int}` is expected (covariant result) | ok | E1009 |
| `[{a:1}, {a:2, b:3}]` and `c ? {a:1} : {a:2, b:3}`, either order | ok: `{a:Int}`, the common fields | E1002 |
| class instance to `{x:Int}`, `s.x = 7` | ok; the instance sees 7; `s == p` and `Std.isOfType(s, P)` true | E1002 |
| class method to `{function f():Int;}`; to `{f:()->Int}` | ok; **error** (`Field f is method but should be var`) | parse error; E1002 |
| class private field, `(get,set)` property, `final x` to `{x:Int}` | **error** (not public, inconsistent access) | error |
| inherited public var; `final x` to `{final x:Int;}` | ok | E1002 |
| interface to `{function f():Int;}` or (interface `var x`) to `{x:Int}` | ok; identity holds | parse error |
| `Dynamic` to `{a:Int}`, then `s.a = 3` | `d.a` is 3; `s == d` true (an alias) | copy: `d.a` is 1 |
| two equal literals `==`; one object through two typedef names | false; true | false; true |
| a structure as a `Map` key, looked up with an equal fresh literal | not found (identity) | found (structural `Hashable`, `STRUCTS.md`) |
| `Reflect.fields`, `hasField`, `trace` of a narrowed view of `{a:1, b:2}` | `[a,b]`, true, `{a : 1, b : 2}` | (copy) `[a]`, false, `{a : 1}` |
| `var p:{x:Int, ?y:Int} = {x:1}`: `Reflect.fields(p)`, `trace(p)` | `[x]`, `{x : 1}` | `[x,y]`, `{x : 1, y : null}` |
| a gained optional field written through the view (`d.optional = true`) | the object gets the field: `[name,optional]` | E1002 earlier |

The rules, as far as they matter here:

- **Open literals.** An object literal not typed against an expected structure has an open type (Haxe's `Const`
  status). Unifying it with a structure that has optional fields it lacks adds them to the type, in place, for every
  alias of it. Required fields are never added. Uses accumulate; the final set does not depend on the order of the
  uses. A declared structure is closed and never gains a field.
- **Width.** A structure stands for one with a subset of its fields, var fields included, at the top level, inside
  `Array` parameters and in function types (contravariant arguments, covariant results). A literal written directly
  against an expected structure may not have extra fields.
- **Depth.** var fields are invariant; final fields are covariant. var and final never convert. Optional and required
  convert both ways. Access kinds (`default`, `null`, `get`, `never`, method) must match, except that a plain field
  stands for a `(default,null)` one.
- **Classes and interfaces** stand for structures through their public fields, inherited ones included; a method only
  for a `function` field.
- **Identity.** Every conversion is a view of the same object. `==` is reference identity, writes through a view are
  seen through every other, `Reflect` and `trace` show the object's physical fields, and an optional field never
  written does not exist.

## Semantics for Haxeon

Haxeon takes every rule above, with one departure, which keeps a program's types independent of typing order
(the reason 2.5 gives for its own):

1. **A literal's type closes at the end of its unit.** An open structure belongs to the type-variable frame of the
   body or initializer that wrote the literal (`MonomorphFrames`), gains optional fields while that unit is typed, and is
   closed when the frame is settled. In Haxe it stays open forever, so a structure returned by an unannotated function
   could gain optional fields from a caller in another unit, and every other caller would then see them. Haxeon reports
   that conversion at the caller:
   `{name : String} has no field optional; the structure comes from a literal in "Main.make", which closed its type; annotate the result of "Main.make"`.
   See decision 3.

A structure used as a `Map` key compares by identity, as in Haxe (decision 5). Today's structural hashing of structures
(`STRUCTS.md`) is removed by slice 4a.

Everything else is Haxe's, including width subtyping of var fields, which is unsound in Haxe too (a narrower value
written into an `Array<{a:Int}>` that aliases an `Array<{a:Int, b:Int}>` is later read through the wider type). A read
of a field the object does not have behaves as in Haxe: the default of the field's type (`null`, `0`, `false`).

## Representation

### The model: a structure value is the object itself

A structure-typed value is a reference to whatever object it was converted from: a literal's own record, a class
instance, an interface's object, a dynamic object. Converting between structure types, or from a class, interface or
`Dynamic` to a structure, is a retype: nothing is allocated and nothing is copied, so identity, aliasing and
reflection are those of the object, as in Haxe. A field access dispatches on the object's class:

- **The record of a literal** keeps today's layout: a class per closed field set, named by it
  (`$anon:{a:Int,b:String}`), with no header beyond the object's type. It is the *exact shape* of that structure type.
- **A structure slot** (local, field, array element, argument, result) has a new IR type, `Structure(S)`. Its physical
  type is the backend's "any object" reference: `dyn` on HashLink, the object root reference on Wasm GC, a pointer on
  Wasm32. Every structure type has the same physical type, so `Array<W>` to `Array<S>` and function variance need no
  adapter.
- **A field read, write or method call** on a `Structure(S)` value is a fast path plus a call:
  `if (exactType(v) == $anon:S) field of the record else $structure:S:get:f(v)`. The fast path is the type load, one
  compare and an unchecked cast. It is dropped where the value is known to be exact: a value that a literal of `S`
  made, or one that a dominating guard of the same function already tested (the IR refines the value's type to
  `Obj($anon:S)` after the test, as a null check refines nullability). Constructor stores are therefore never guarded.
- **The dispatcher** `$structure:S:<get|set|call>:f` is a generated provider function (`Provides`), one per
  structure, operation and field. Its arms test the exact class of each shape the reachability walk finds flowing into
  `S` (literal records, constructed classes and their constructed subclasses, interface implementors), read or write
  that class's physical field, and convert it where the field types differ (final covariance `Int` to `Float`,
  optional to required with the default, a boxed `Null<T>`). The last arm reads by name, the way `Dynamic` does
  (`hl_dyn_get*` on HashLink, `ObjectReflection` on Wasm): it serves dynamic objects, objects of a shape added by a
  later patch, and objects kept across a full reload. A missing field reads as its type's default.

`==` on structures compares the references. Reflection, `Std.string` and `Std.isOfType` see the object. Dispatcher
arms come from the walk, like the interface dispatch entries of `INTERFACE_VALUES.md`; until the walk generates
providers on demand (`REACHABILITY_WALK.md` 3b), they come from all shapes registered for the program, which only adds
arms.

The fast path is chosen from the static type alone (the exact shape of `S`), never from the shapes the walk found. A
function's code is then a function of its own types, so warm and fresh builds agree and a patch that adds a shape
needs no caller recompiled (`HELPER_OWNERSHIP.md`: an artifact's attributes are a function of its subject, never of its
uses). A structure that is never written as a literal (a pure view type) pays the failed compare and the call on every
access; that is the case slice 1 measures (`SwitchArm`-like types). Dropping guards where the walk
proves a single shape is a later, measured option (see "Performance"); it makes callers depend on the walk and so needs
a patch dependency.

### Alternatives

**Haxe's model: HashLink virtuals for every structure slot.** genhl allocates a literal as a virtual with its own
storage (`hl_alloc_virtual`: header of type, value and next, one field pointer per field, then the data) and a field
access loads the field pointer, tests it and loads through it, falling back to `hl_dyn_get*` by name hash when the
pointer is null. Converting a class instance allocates a new virtual each time (`hl_to_virtual`, `HOBJ` case: there is
no cache except the interface slot); converting a virtual to a virtual that is not a prefix of it turns the source into
a dynamic object (`hl_virtual_make_value`: a dynobj, its lookup table, raw and value arrays, and a rebinding of every
view), then caches a view on it. Against the object model:

- every structure access pays the indirection, not only those through a view: 30% of the compiler's static field
  accesses, 28% of non-constructor ones, about 9% of sampled field work, and 99.8% of nbody's weighted accesses
  ("Performance");
- a literal record is about twice the size: 24 + 8n bytes plus the data, against 8 plus the data;
- class-to-structure conversions allocate, and the first non-prefix narrowing of a literal converts it to a dynobj;
- a view whose field type differs from the object's (final covariance, an erased `Dynamic` view of an `Int` field) has
  a null slot, so every access takes the hash lookup;
- Wasm needs a second model, against ADR 0004 and `INTERFACE_VALUES.md` (one model on every backend), and
  `INTERFACE_VALUES.md` is removing virtuals for interfaces for the same costs (22 ns per call against 2 to 5).

**A hybrid: exact classes where a type is never converted to, virtuals where it is.** Whether `S` is a view type is
a property of the whole program's uses. One new width conversion anywhere would flip `S` from `Obj` to `HVirtual` in
every function, field and array that mentions it: a warm build recompiles all of them, and a live session reloads,
because every stored value of `S` changes representation. It also keeps two models on HashLink and none on Wasm.

**An object plus a field table chosen at the conversion point** (a fat reference, or a small view object, on Wasm).
Two words per slot or an allocation per conversion, a composition of tables at each view-to-view conversion, and `==`
must unwrap. The object model chooses the table at the access, from the object's class, which needs no storage.

### HashLink

- Physical type `dyn`. An object in a `dyn` register is the object pointer itself (no box). Arms use `OUnsafeCast` to
  the shape's class after the test; there is no `OSafeCast` (a runtime call) on any structure path.
- `exactType` is `OGetType` compared with an `OType` constant: two loads and a compare. `HlInstruction` gains
  `GetType` (the opcode exists in HashLink; Haxeon does not emit it yet).
- `==` between structures is a pointer compare (`OJEq` on the two values cast to one object type), not `hl_dyn_compare`.
- No change to the HashLink fork.

### Wasm32 and Wasm GC

- **Wasm GC:** the slot is a reference to the object root type (`WasmGcTypePlan.objectRootTypeIndex`), which dynamic
  objects (the stdlib's dynamic object class) also extend. A literal record's struct type is final, so the exact test
  is `ref.test` on it (`br_on_cast` in the dispatcher). The read is `ref.cast` and `struct.get`. Identity is `ref.eq`.
- **Wasm32:** the slot is the object pointer; the exact test compares the header's runtime type id with a constant;
  the read is a load at the shape's offset. Identity is a pointer compare.
- Both: no allocation per conversion, the same dispatcher IR as HashLink, and the by-name arm through the existing
  reflection tables. This is the "object plus accessor table" option with the table selected by the object's class at
  the access rather than at the conversion, so a conversion is free and keeps identity.

### Generic erasure (haxeon-e4's question)

The `$generic-erased:Owner:get:member` dispatchers (`GenericOwnerErasure`) already follow this model: the erased
owner is the original object carried as `Dynamic`, and the dispatcher tests the owner's layout and reads its physical
field. They are slow because of how they test: for each candidate class, `__std_is_of_type` (a runtime call) and then
`SafeCast` (another), where stock Haxe, which does not specialize generics, reads the field directly. On lru that is
the 20 to 45% that haxeon-e4 measured.

The structure dispatcher is the same construct, so erased owners move onto it (slice 3):

- one generator, `IrShapeDispatch`, for structure and erased-owner operations;
- arms test the exact class (`OGetType` compare, `ref.test`, the type id), one compare per constructed class, with
  the by-name arm last, instead of an instance test plus a checked cast;
- the call site inlines the arm of the owner's own specialization as the fast path, so with one constructed
  specialization an erased read is a type compare and a field read.

HashLink virtuals would not help here: a `Dynamic`-typed view of an `Int` field has a null slot, and every access
would take the hash lookup.

### Value types, native layouts and generic layouts

- Structures stay reference types (`STRUCTS.md`). A struct-typed field of a structure is still stored inline in its
  record; a dispatcher arm copies it out or in, and the by-name arm uses the logical get/set adapters reflection
  already has.
- Native layouts never contain structures (`NativeLayout`), so nothing changes there.
- The `layout` policy of generic specialization keeps a concrete type inside a structure, and a shared body sees the
  erased structure (`TypeRepresentation`, the physical anonymous type). With the object model the erased structure is
  a view of the concrete record, with a boxing arm, instead of a separate type that must match it field for field.

### Live patching and stable layouts

- A record's layout is a function of its name, which is its field set, so two generations agree on it.
- Structure slots are `dyn` whatever the structure, so adding a field to a typedef, adding an optional field to a
  literal or adding a width conversion changes no containing layout: today the first changes the `$anon` class of
  every field that holds one (`object_field_type_changed`, a reload); with this model it patches. Old records keep their
  old class; a dispatcher reads them through the by-name arm, and a field they lack reads as its default.
- A dispatcher is a provider row. A patch replaces it when its arms change; callers call it by name and are not
  recompiled.
- After a full reload, an object kept from the old generation has the old type pointer, fails the fast path, and is
  read by name. That is correct and slower until the objects are replaced; nothing else in the module depends on it.
- The nominal virtual identities that HLB 8 and HLP 11 carry stay for interfaces until `INTERFACE_VALUES.md` lands;
  structures never use them.

## Typing

### Open literal structures

- **The type.** A literal typed without an expected structure gets a `TAnonymous` whose field array is open: the
  frame of the unit records it (`MonomorphFrame.literals`) with a provisional name (`$anon:open:<unit>#<n>`, never
  emitted). The array is shared by every alias of the type, as Haxe's `a_fields` is.
- **Gaining fields.** Where an open structure meets a structure in `ConversionResolver.coerce` (assignment, argument,
  return, array element, a function type's argument or result), each optional field of the expected structure that
  the open one lacks is added to it. A required field it lacks is the usual error. The field's type is the expected
  one; a later use that adds the same optional field with another type fails, at the second use in source order, as
  Haxe's first-come rule does.
- **Common fields.** An array literal and a conditional whose branches are structures take the common fields (Haxe's
  `unify_min`), whatever their order; each element is a view.
- **Closing.** `BodyTyper.settleFrame` closes the frame's literal structures before it settles its type variables:
  each one gets its name from its final fields (`anonymousTypeName`) and is registered then
  (`AnonymousTypeRegistry`, into the unit's output). The `TypedTypeMap` that replaces type variables replaces the
  provisional names in the same walk. `TObjectLiteral` takes its record name from its type, not from a string kept
  beside it. The 2.3 verifier rejects a provisional name that escapes into the typed program, IR, caches or
  fingerprints, as it does a type variable.
- **A literal typed against an expected structure** is typed as it is today (its fields checked against the expected
  ones, an extra field an error), and its record is the expected structure's, optional fields included, so a later
  write of an optional field through any view has a slot. Reflection hides an optional field that holds `null`
  (decision 4).
- **Where there is no frame** (a generated helper), a literal closes at once, as today. After 2.5, every declaration
  unit has a frame.

### As built (slice 5)

- `MonomorphFrames.openStructure` gives a literal typed without an expected structure (and not as `Dynamic`) the type
  `TAnonymous("$anon:open:<n>", fields)`, an `OpenStructure` owned by the innermost frame (`MonomorphFrame.literals`).
  Where no frame is open (a generated helper), the literal is named at once, as before. Nothing registers an open
  structure: `AnonymousTypeRegistry` skips the provisional names.
- `Monomorphs.resolve` resolves an open structure's own field types in place and returns the same type, so every alias
  keeps sharing its `fields` array; `Monomorphs.occurs` looks into it, so `x.push({items: x})` does not make it contain
  itself.
- `ConversionResolver.coerce` calls `MonomorphFrames.gain(value.type, expected)` after the type-variable fill. It walks
  both types together (nullable, `Array`, `Iterator`, `Map`, a class's or enum's type arguments, a structure's common
  fields, function arguments the other way and results), adds to each open structure of the innermost frame the optional
  fields it lacks, unifies the type variables of common fields, and then pins every open structure it met against another
  structure (`OpenStructure.pinned`). A pinned structure gains no more fields: its value is already a record of the other
  structure's fields, and a record standing for a structure with fewer fields waits for views (slice 4). So a narrower use
  before a gaining one, and two uses with different optional fields, are the known divergence
  `structure-open-literal-two-uses`. A later use that wants a gained field with another type is the usual mismatch.
- `BodyTyper.settleFrame` settles the type variables, then `MonomorphFrames.closeFrame` closes the frame's literals in the
  order they were written: field types resolved and nested open structures closed first, in place, then the name from the
  final fields (`SemanticSignature.anonymousTypeName`) and the registration, in the unit being typed. The frame's
  `TypedTypeMap` is `MonomorphFrames.settled` (type variables resolved, provisional names replaced by the closed types)
  when the frame wrote a literal. `TypedTypeMap` renames a `TObjectLiteral` from its mapped type. The signature, cell and
  deferred-check reads after the settle go through `settled` too.
- A type that leaves the unit before its end closes the structures it reaches at once (`MonomorphFrames.closeReached`):
  an enum constructor's type arguments, which name its storage (`Some({a: 1})`). Generic calls need nothing: their
  specialization keys erase structures.
- The verifier is `SemanticSignature.type`, which throws an `InternalError` when it meets a provisional name: every
  helper name, specialization key, cache key and fingerprint is spelled through it. `SemanticSignature.display` spells an
  open structure from its fields, and `DeclarationIndex.typeKey`, which names a lambda after its captures, spells it by
  the fields it has at that point (`SemanticSignature.provisionalType`), which the source fixes.
- Decision 3: an unannotated declaration's frame (`MonomorphFrame.declaration`) records, after settling, which closed
  literal structures its type reaches (`recordDeclarationType`, by `fields` identity). A conversion from such a structure
  that adding optional fields would have made valid reports
  `{name : String} has no field debug; the structure comes from a literal in "Main.config", which closed its type; annotate the type of field "Main.config"`
  (`annotate the result of "Lib.make"` for a function), in both typing orders (`OpenLiteralStructureMain`). Haxe 4.3.7
  rejects the function case too (a returned literal is closed when the function's body is typed, `{ name : String } has
  no field debug`); only the field case is a Haxeon-only error. A warm build that reuses the declaration's type without
  typing it gives the plain mismatch message.
- A dynamic object literal holding an open structure (`{inner: literal}` as `Dynamic`) is not named: its fields are dynamic.
- Self-compile (a frozen copy of the sources): byte-identical output to the compiler before the slice. Nothing in the
  compiler relies on a literal gaining a field while `localExpectedTypes` types literals in a later use's context.

### Why it is deterministic

No open structure outlives its unit, so another unit only ever sees closed structures (2.5 semantics 2). Inside the
unit, typing is in source order, so the fields a literal gains, and which of two conflicting uses fails, are fixed by
the source. Names come from field sets, and registrations go through the unit's output, merged in sorted unit order
(2.2). `--reverse-typing-order` stays byte-identical.

### Deleting `localExpectedTypes`

With open literals, `arguments.push({name, type, span, optional, defaultValue})` fills the array's element variable
with the literal's open structure, and passing the array as `Array<AstArgument>` adds `AstArgument`'s optional fields
to it. The look-ahead is then unused, and slice 6 deletes it: `BodyTyper.inferBodyLocalTypes` and its constraint
walkers, `TypingContext.localExpectedTypes`, `expectedInitializerType`, `MonomorphCell.hint`, `Monomorphs.hint` and
the hint half of `Monomorphs.expectation`, and the hint fill in `settleFrame`. An unfilled type variable becomes
`Dynamic` as Haxe makes it (2.3), and `values.push(1)` into a returned `Array<Float>` is `Int should be Float`. Before
the deletion, a census build of `src/`, `packages/` and the test programs with the pass disabled lists what else relied
on it; each such program is either a Haxe error too (and is fixed) or a case this note missed.

As built (slice 6). The census (the pass disabled; `src/` self-compiled, the compiler, programs, runtime and tooling
suites, the differential cases and the UI Showcase on all three targets) found five things, four of them cases this note
missed:

- `Parser.hx`, four sites: `arguments.push({name, type, span, optional: optional, defaultValue: defaultValue})` passed
  as `Array<AstArgument>`, whose `optional` and `defaultValue` are optional fields. The literal has them as required
  fields, and Haxe converts required to optional. So an open structure meeting a structure that declares a field it has
  as optional, of the same type or its nullable, turns that field optional with the other's type
  (`MonomorphFrames.becomesOptional`), unless it is pinned or the field has already been read or written through it
  (`OpenStructure.usedFields`, noted by `TypeRepresentation.fieldType`): those typed uses have the field's old type.
  `TypedTypeMap` wraps a literal's value as the nullable of its field where the field turned optional after the value
  was typed. The literal's record is then `AstArgument`'s, and var to final is the existing read-only widening. Fixture
  `structure-open-literal-optional-field`.
- `[null]` and `[for (...) null]` were typed in a later use's context: they are now `Array<Null<?>>`, the type variable
  filled by the first use that fixes it, as Haxe types them (`NullArrayContextMain`).
- `[].push(list.shift())` passed as `Array<String>`: the element is `Null<String>`. Haxe unifies `Array<Null<T>>` and
  `Array<T>`; for a reference `T` that holds null (not a value class, struct or enum) they are one storage, so
  `TypeRelations.isAssignable` relates the two arrays either way (`sameNullableReference`).
- A local's annotation was first resolved by the look-ahead, at the declaration; the statement typer resolved it with no
  span, so an ambiguous import (`E1029`) was reported at the type's own declaration. It is now resolved at the local's
  span (`ImportShadowingMain`).
- `values.push(1)` returned as `Array<Float>`: `Int should be Float`, as in Haxe (fixture
  `local-inference-push-int-as-float`; `tests/programs/local-inference-type-variables.hx` now pushes `1.0`).

The census also found escapes of a provisional name that slice 5 shipped with, since every literal without an expected
structure is now open: a generic specialization's type arguments and the helpers named after a type (equality, hash,
enum methods and adapters, wire codecs) close the structures they reach (`f9a9c84e5`). The self-compile is
byte-identical to slice 5's (frozen sources), and typing allocates 47.44M objects against 48.41M with the pass.

### Relations

`TypeRelations` gets one structural relation, `structureConverts(actual, expected)`, used by `isAssignable` and
`conversion` (a new plan, `StructureView`, which lowers to a retype):

- every field of `expected` is in `actual`, or is optional in `expected`, or (decision 3) `actual` is an open literal
  structure of the current unit, which gains it;
- var to var: the same type (`equals`), optional and required either way; final to final: `isAssignable`, with the
  conversion done by the dispatcher arm; var and final never; access kinds as in the table;
- inside `Array` parameters the same relation (Haxe's variance), in function types contravariant arguments and
  covariant results;
- a class or interface: its public fields, inherited ones included, with matching access; a method only for a
  `function` field;
- `Dynamic` to a structure: a retype with no check (decision 2).

`anonymousReadOnlyWidening` and the reverted `anonymousWidening` go. The parser gains what the table needs and Haxeon
cannot parse: `function` fields and property accessors in structure types, and `var` fields in interfaces.

## Performance

### Measured (2026-11-17)

Static census of the self-compile's HashLink module (`--entry=compiler.tools.HaxeonCompiler`, 786 sources, read from
the `.hl` by receiver register type; the IR census agrees, 62,099 `FieldGet` against 61,152 `OField`):

| receiver | gets + sets | share | without constructor stores | weighted by 8^loop depth |
|---|---:|---:|---:|---:|
| `$anon:` structure | 27,874 | 30.4% | 18,220 (28.0%) | 34.9% |
| `$anon:rec:` | 160 | 0.2% | 134 | 0.2% |
| class | 63,689 | 69.4% | 46,688 (71.8%) | 64.9% |

- 9,654 of the 9,687 structure writes are constructor stores, which the model never guards.
- 519 structure types; 339 are named `typedef`s (438 in `src/`). IR records (`ir/Ir.hx` and other `ir/` files) and
  AST records are 42% of the static and 79% of the weighted structure accesses; `IrInlineValueSlot`, `IrObjectField`,
  `IrPhiInput` and `AstFunction` lead the weighted list. `TypedAst` records are 8%.
- A sampling profile of a self-compile (`hlprof-live`, 2 kHz, 55,603 samples) puts structure accesses at about 9% of
  the sampled field-access work. Most samples are in natives (maps, hashing, allocation).
- lru: 9 of 57 field accesses are on a structure (`Pair`), all in `LRU.put` and `LRU.get`. nbody: 99.8% of its weighted
  accesses are on `Planet`, the worst case for any structure representation.

HashLink costs, measured with stock Haxe 4.3.7 programs on the fork's JIT:

| operation (best of 5, ns per operation; bytes per operation) | ns | bytes |
|---|---:|---:|
| read an `Int` field of a class instance (loop included) | 2.9 | 0 |
| the same through a virtual: a literal's own, or a view of a class instance | 3.0 | 0 |
| a virtual read whose field type differs from the object's (the by-name fallback) | 10.3 | 0 |
| read by name through `Dynamic` (`hl_dyn_get`, the dispatcher's last arm) | 24.5 | 0 |
| read from an array of `dyn` and read a field, unguarded | 2.3 | 0 |
| the same with the exact-type guard (`gettype`, `jnoteq`), always passing | 4.2 | 0 |
| the guard with two shapes alternating (second compare taken) | 6.0 | 0 |
| allocate a 4-field class instance | 16.1 | 24 |
| allocate a 4-field literal as Haxe does (`hl_alloc_virtual`) | 63.4 | 72 |
| class instance to structure (`OToVirtual` on an object, no cache) | 68.5 | 56 |
| virtual to a prefix virtual | 1.6 | 0 |
| fresh literal, then to a non-prefix virtual (turns it into a dynobj) | 590 | 304 |
| `==` of two views of one object; of a class pair | 2.3; 1.4 | 0 |

The machine was loaded (load average 10 to 29 on 20 cores), so read the ratios, not the digits; slice 1 repeats the
guard on a quiet machine. Programs: `views/hl/b` and `b3` in the design session's scratchpad, to be committed as
`benchmarks/structure-access` in slice 1.

The trade, then: a guarded read costs more than a virtual read (about 1.9 ns against 0.1 ns over a plain read, in this
run), while a virtual costs four times the allocation time and three times the bytes for every literal, 68 ns and 56
bytes for every class conversion, and a hash lookup for every read whose field type differs.

### Baseline: `benchmarks/structure-access` (slice 1)

The read kinds that compile today with both compilers, measured before any representation change (HashLink, release
builds, one core, best of 5 runs of 20M reads; load average about 15, so again the ratios):

| receiver | stock Haxe 4.3.7 | Haxeon | |
|---|---:|---:|---|
| class instance field | 1.17 ns | 2.94 ns | Haxeon 2.5× slower |
| structure literal's field | 6.59 ns | 2.53 ns | Haxeon 2.6× faster (an exact record against a virtual) |
| field of `Box<Int>` read as `Box<Dynamic>` (erased owner) | 5.72 ns | 18.12 ns | Haxeon 3.2× slower: the lru gap, slice 3's target |
| field read by name through `Dynamic` | 26.81 ns | 62.05 ns | Haxeon 2.3× slower; a dispatcher's last arm is this read |

Two of these are not structure costs and are followed up on their own, re-measured on a quiet machine first:

- **The class read.** Haxeon's loop has the same instruction count as stock's, but computes the constant `COUNT - 1` of
  an `inline final` every iteration (stock folds it), and reloads the captured array from the closure, with its null
  check, every iteration (no loop-invariant load hoisting).
- **The by-name read** costs twice stock's. It is the dispatcher's fallback arm, so it matters to slices 2b and 3 even when
  rare.

The view cases (a class seen as a structure, a wider literal through a narrower type) join the benchmark when the typer
accepts them (slice 4). The miss-count option counts executed guard misses, so it comes with the guards (slice 2b); the
IR census gains its receiver kinds now.

### Estimates

- **Object model, today's programs.** No program converts between structures yet, so every access hits the fast
  path. Unguarded: literal-made values and constructor stores. Guarded: the rest of the 28% of non-constructor accesses,
  less what a dominating guard covers. An upper bound: if every structure read in a self-compile were guarded and
  each guard cost as much as the read itself (the measured 1.9 ns against 2.3), structure-access work, about 9% of the
  sampled field-access work, would double. Field accesses are part of the 37% of samples that land in Haxe code (the
  rest are natives), so the bound is about 3% of the self-compile; refinement (one guard per value per function) and
  unguarded literal-made values bring it under that. Allocation does not change.
- **Haxe's model.** Every structure access, 28% of non-constructor accesses statically and about 9% of the sampled
  work, pays the virtual indirection, which is cheap (0.1 ns). The cost is elsewhere: every literal record is three
  times the bytes and four times the allocation time, in a compiler whose profile is already about 28% allocation, and
  every class conversion allocates. The compiler already shows it where stock Haxe builds it: in
  `2026-11-compiler-memory.md`, 4.26M live structure records (debug locations) take 0.672 GB as virtuals, about 158
  bytes each against about 50 for a class with the same fields. Under Haxe's model a Haxeon-built compiler would pay
  the same; slice 1 counts the records it allocates.
- **lru.** The erased dispatchers are the gap; slice 3 should close most of the 20 to 45%. The structure accesses
  themselves are few and in `put`/`get`.
- **nbody** is the case to watch for the guard: its hot loop reads `Planet` fields of values taken out of an array, so
  each body iteration tests each planet once.

### What to measure before committing

Slice 1 measures, on the same machine, before any representation change:

1. The guard in isolation: slice 2a lands the `Structure(S)` type with unguarded reads (sound while nothing converts),
   slice 2b adds the guard. The self-compile time (about 29 s), the `typing` and IR phase timers, nbody and lru are taken
   after each; the commit message carries them.
2. The guards that remain after refinement: the IR census (`HAXEON_IR_CENSUS`) gains receiver kinds (exact,
   refined, guarded, dispatcher call) so the static share is reported per build.
3. The share of dispatcher calls in a run: a census build that counts executed fast-path misses per structure. It is a
   diagnostic option of the compile (`CompileOptions`), not committed instrumentation in the runtime.

Gate for slice 2b: the self-compile no slower than noise, and nbody within 3%. If the guard misses that, the
closed-world elision (no guard when the walk proves one shape, with a patch dependency from the shape set to its
callers) comes in before slice 4, not after.

## Slices

Every slice is one or more commits on `main` that leave the tree green. Gates for every slice: the self-hosting fixed
point, `--reverse-typing-order` byte-identical, the warm-edit sweep with `--check-reuse`, the slice's own tests; slices
that change HashLink positions or lowering also run the ci-tier debug-metadata and hot-reload suites.

| Slice | Change | Behaviour | Owner | Main files |
|---|---|---|---|---|
| 0 | Revert `c618c16d8`. The three fixtures where both compilers reject stay. | Width on final fields rejected again | any | `TypeRelations`, `ConversionResolver`, `tests/differential` |
| 1 | Receiver kinds in the IR census; the miss-count diagnostic option; `benchmarks/structure-access` (exact, view, class as structure, by name) on HashLink and both Wasm targets. | None | haxeon-e4 | `ir/IrOpportunityCensus`, `CompileOptions`, `benchmarks/` |
| 2a | `IrType.Structure(S)`; structure slots physically `dyn` / root reference / pointer; reads and writes unguarded through an unchecked cast; `HlInstruction.GetType`; `==` as a pointer compare. | Same semantics; bytes change | haxeon-e4 (IR, HL); Wasm owner | `ir/{Ir, IrGenerator (lowerType), IrBuilder, IrVerifier, IrTypeIdentity, codec/*}`, `hl/{HlFunction, HlWriter, lower/HlLower, incremental/HlSymbolTable}`, `backend/wasm/{WasmFunctionLower, gc/WasmGcRepresentation, linear/WasmLinearRepresentation}` |
| 2b | `IrShapeDispatch`: dispatchers as provider rows, the guarded fast path, refinement after a guard, the by-name arm. | Same semantics | haxeon-e4 | new `ir/IrShapeDispatch`, `IrPipeline`, `core/Provides`, `REACHABILITY_WALK` hooks, the three backends' exact test |
| 3 | Erased generic owners on `IrShapeDispatch`: exact-class arms, inlined own-specialization arm. | Faster; same semantics | haxeon-e4 | `ir/GenericOwnerErasure`, `IrGenerator.erasedOwnerOperation` |
| 4a | Census of maps and sets keyed by a structure; move those users to declared value types; then structure keys compare by identity (decision 5). | `Map` keys match Haxe | any | `STRUCTS.md` `Hashable` on structures, the users the census finds |
| 4 | Relations: width, depth, optional, access kinds, `Array` and function variance, common fields, class and interface to structure, `Dynamic` to structure as a retype; `StructureView`; accessor (`get`, `set`) fields in structures (`function` fields and `default`/`null`/`never` property fields in structures, and `var` in interfaces, have landed). Deletes `dynamicStructure`, E1016's structure case, `anonymousReadOnlyWidening`. | Accepts Haxe's programs; differential tests | typer (coordinate with haxeon-7b) | `types/TypeRelations`, `typing/{ConversionResolver, ExpressionTyper, CallResolver, DeclarationIndex}`, `syntax/Parser` |
| 5 | Open literal structures: frame-owned, gaining optional fields in `coerce`, closed and named in `settleFrame`, registered at closing; `TObjectLiteral` name from its type; the verifier; the cross-unit diagnostic. | Accepts Haxe's open-literal programs | typer (haxeon-7b's files) | `typing/{BodyTyper (settleFrame), MonomorphFrames, ExpressionTyper (typeObjectLiteral), ConversionResolver, AnonymousTypeRegistry}`, `types/{Monomorphs, TypedTypeMap, TypedAst}` |
| 6 | The census build without `localExpectedTypes`, the fixes it asks for, then the deletion. | `values.push(1)` as `Array<Float>` rejected | typer | `typing/{BodyTyper, StatementTyper, TypingContext}`, `types/{Type (MonomorphCell.hint), Monomorphs}` |
| 7 | Reflection and printing of unwritten optional fields (decision 4); `LANGUAGE_SUPPORT.md`, `SEMANTIC_TYPE_CONTRACT.md`, `STRUCTS.md` updated. | Reflection matches Haxe | any | `IrProgramAssembler.anonymousStringsFrom`, `ObjectReflection`, docs |
| 8 | Interface field access on `IrShapeDispatch`: a read or write of an interface variable (`9f2db038d`) becomes a shape-dispatched field access, an exact-class arm reading the field inline with the dispatcher as fallback, instead of a virtual call to a hidden `$get_x`/`$set_x` accessor. Then delete those hidden accessors (`semantic/InterfaceFieldAccessors`) and their per-class methods. The interface's own `get_x`/`set_x` accessors stay. | Faster; same semantics; less code; adding an interface variable no longer adds methods to every implementing class | haxeon-e4 (IR), typer for the access typing | `ir/IrShapeDispatch`, `semantic/InterfaceFieldAccessors` (deleted), `typing/InterfaceProperties`, `IrGenerator` |

Order and parallelism:

- Two tracks. **Representation** (haxeon-e4): 1, 2a, 2b, 3. **Typing**: 5, 6. They share no file.
- Slice 5 does not need views: a literal that gains optional fields closes to its own record, which is exact. It can
  start now, after slice 0, but it changes `BodyTyper.settleFrame` and `ExpressionTyper`, which 2.5's slices 3 and 4
  also change (`ProgramTyper`, `BodyTyper.typeFunction`). Land it between 2.5's slices, agreed with haxeon-7b, not
  concurrently with them.
- Slice 4 needs 2b (a view must be a view before the typer accepts one) and 5 (the open-literal rule of the relation).
- Slice 3 needs 2b only and is the one that pays back early on lru.
- Slice 6 follows 5. Slice 7 follows 4.
- Slice 8 needs 2b and [INTERFACE_VALUES.md](INTERFACE_VALUES.md) (an interface value is the object itself on HashLink). The exact-class arm (`IrExactTypeFacts`, `__object_has_exact_type`) deliberately fails for a value behind an HL virtual, because the cast after it would be unsound. So while interface values are virtuals, every interface-variable access would miss the fast arm. Unwrapping the virtual in each access is the cost the interface-values design removes, so it is a prerequisite, not part of this slice. It replaces the bridge 9f2db038d used for interface variables: one mechanism for structures, interface variables and erased generics, so a monomorphic access runs at direct-field speed.

## Tests

Differential fixtures against Haxe 4.3.7 (`tests/differential/`, `.official.hx` and `.realtime.hx`, output and exit
status compared), from the cases above:

- `structure-open-literal`: a literal gaining one and two optional fields, in both orders, a narrower use between, an
  array element gaining them (the `Parser.hx` shape), `$type`-free probes through `Reflect.fields`.
- `structure-width-var`, `structure-width-final`: aliasing writes, `==`, `Reflect.fields`, `trace` and a `Map` keyed
  by the object (an `ObjectMap`, not a structure key) through narrow and wide types.
- `structure-depth`: final `Int` to `Float`, final `Child` to `Parent`, optional and required both ways.
- `structure-variance`: `Array` width, contravariant arguments, covariant results.
- `structure-common-fields`: array literals and conditionals in both orders.
- `structure-from-class`, `structure-from-interface`: fields, inherited fields, `function` fields, `(default,null)`.
- `structure-from-dynamic`: aliasing writes and `==` (decision 2); a missing field reads its default.
- `structure-literal-optional-absent`: `Reflect.fields` and `trace` of a literal against a type with an optional
  field (decision 4).

Compile-error fixtures (both reject): var `Int` to `Float`, var `Child` to `Parent`, var to final and back, a declared
structure to one with an extra optional field, an extra field in a literal against an expected type, a contravariance
violation, a class's private field, a `(get,set)` property, a method for a var field, `values.push(1)` as `Array<Float>`.

Haxeon-only error (Haxe accepts; message and position checked, listed in `LANGUAGE_SUPPORT.md`): a literal held by an
unannotated field gaining an optional field in another unit (decision 3). A literal returned from an unannotated function
is closed in Haxe too, so that case is a compile failure in both (`structure-open-literal-returned`).

Order: every fixture and the self-compile with `--reverse-typing-order`, byte-identical.

Warm and live (`tests/compiler`, warm against fresh bytes with `--check-reuse`; live through the hot-reload suite):

- an edit that adds a width conversion: patches, no caller of the structure recompiled, the dispatcher replaced;
- an edit that adds a field to a typedef held in a class field: patches (it reloads today); an old record reads the
  new field as its default;
- an edit that makes a literal gain an optional field;
- a structure value kept across a full reload, read through the by-name arm;
- a class newly converted to a structure in a patch.

Benchmarks: the self-compile time, `benchmarks/cross-lang` (nbody and lru above all) and `benchmarks/structure-access`
on HashLink and both Wasm targets, before and after slices 2a, 2b and 3.

## Decisions taken by the user (2026-11-18)

1. **The representation** is the object itself, with field access dispatched on its class (above), not HashLink
   virtuals.
2. **`Dynamic` to a structure** follows Haxe's rule: a retype with no check and no copy. A missing field reads as its
   default, and a field of the wrong type fails when it is read, as a `Dynamic` field read does.
3. **A literal's structure gaining optional fields from another unit** is an error that asks for an annotation. This
   matches step 2.5, which closes a declaration's type at the end of its unit.
4. **Optional fields a literal never wrote.** Reflection and printing treat an optional field whose value is `null` as
   absent, as in Haxe. The one difference left: Haxe shows a field explicitly set to `null`, and Haxeon does not.
   Tracking presence exactly would cost a flag per optional field on every write, for a reflection-only case. Slice 7.
5. **Structures as `Map` keys** compare by identity, as in Haxe. Structures are references, and references compare by
   identity. Value equality and hashing come only from a declared value type (`Equatable`/`Hashable`, `STRUCTS.md`).
   Hashing by fields would otherwise have to go through the dispatcher once a structure slot can hold a class instance
   or a wider record. This is slice 4a: a census of structure-keyed maps and sets, then moving those users to declared
   value types. 4a lands before slice 4, and ideally before 2a.


## Review by haxeon-e4 (HashLink and IR owner, 2026-11-18)

haxeon-e4 agrees with the representation and takes the representation track.

- **Order.** The dispatcher lands before the structure type. Erased generic owners already carry the object as
  `Dynamic` and need no `IrType.Structure`. So `IrShapeDispatch` is built and proven on them first: the generator, the
  exact-class arms, the by-name arm, and provider-row patching against existing tests. This also brings the lru win
  forward. The representation track's order is **1 → 2b-core + 3 (dispatch on erased owners) → 2a (structure type,
  unguarded) → 2b (structure guards on the proven dispatcher)**, each with its gate as written.
- **Cost of `OGetType`.** The fork's JIT emits a null test and a branch around every `OGetType` (`jit_emit.c:2297`).
  A null value therefore fails the guard and reaches the dispatcher, which must raise the null field-access error
  itself, naming the field. If 2b misses its gate, the first remedy is JIT-only, with no format change: skip the null
  test when the same block has already checked the register for null. Try this before closed-world guard elision.
- **Loops.** Refinement hoists a guard on a loop-invariant value to the loop preheader. Array-element loads keep their
  guard (the nbody shape). nbody's 3% gate decides whether that is enough.
- **Debug info.** With structure slots physically `dyn`, HashLink register types no longer name the structure. Slice
  2a must make development-mode variable metadata use the logical type from the IR debug bindings, so the debugger
  shows `{name, type}` again. The ci debug-metadata suite is part of its gate.
- **Already in place for 2a.** `HlPatchReader` and `hlpatch.c` decode `OGetType`. The register allocator shares `dyn`
  registers by type, so it needs no change. `HlInstruction.GetType` needs `HlRegisters`, `HlOpcodeSchema`,
  `HlValidator` and a `PatchOpcodeTests` fixture, the same list as `Switch`.
