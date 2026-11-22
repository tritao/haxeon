# Type values: classes and enums as runtime values (design note)

Status: proposal, reviewed by haxeon-e4 (2026-11-19, folded in below); phase 2 is not started. Phase 1
(`Type.enumConstructor`, `Type.enumParameters`, Haxe's `EnumValueTools`) has landed, and so have `Type.createEnum`,
`Type.createEnumIndex` and `Type.allEnums` on a named enum (5b77054c4), none of which needs runtime type information. The
decisions left are the user's (end of the note).

## Scope

Phase 2 makes classes and enums values, `Class<T>` and `Enum<T>`, on HashLink, wasm32 and wasm-gc, with `Type.getClass`,
`getEnum`, `getSuperClass`, `getClassName`, `getEnumName`, `getInstanceFields`, `getClassFields`, `getEnumConstructs`,
`allEnums` and `typeof`, Haxe's `EnumValue` type, and Haxe's `haxe.EnumTools` on an enum (`Color.getName()`,
`Color.getConstructors()`, `Color.createAll()`). It also covers a class named as a value, for instance an extension
with a `Dynamic` first argument called on a class (`Main.twice()`, which Haxe passes `Class<Main>`), and `Type.enumConstructor`
and `Type.enumParameters` on a `Dynamic` or `EnumValue` value. Phase 3 (`resolveClass`, `resolveEnum`, `createInstance`,
`createEmptyInstance`, `createEnum`, `createEnumIndex`) is sketched at the end so that phase 2 does not block it.

## What Haxe 4.3.7 does on HashLink

Run with the pinned compiler (`-hl`, default `-dce std`):

| Expression | Result |
|---|---|
| `Type.getClass(new Child()) == Child` | `true` |
| `Type.getClassName(Child)`, `(haxe.ds.StringMap)`, `(String)`, `(Array)`, of an interface `I` | `Child`, `haxe.ds.StringMap`, `String`, `Array`, `I` |
| `Type.getSuperClass(Child) == Base`; `Type.getSuperClass(Base)` | `true`; `null` |
| `Type.getInstanceFields(Child)` (`Base` has `a`, `m()`; `Child` has `b`, private `hidden`, `n()`) | `[n,b,hidden,m,a]`: each class from the object's up, its methods then its variables, private ones included |
| `Type.getClassFields(Child)` (`Child` has `sc` and a `@:keep` private `kept()`; `Base` has statics too) | `[sc,kept]`: the class's own statics only, private ones included |
| `Type.getEnumName(E)`, `Type.getEnum(B(1)) == E`, `Type.getEnumConstructs(E)` | `E`, `true`, `[A,B,C]` |
| `Type.allEnums(E)` (`B` has an argument) | `[A,C]`: the constructors without arguments |
| `Type.typeof` of an instance, `1`, `1.5`, `null`, `"s"`, `true`, `B(1)`, `{a:1}`, a function, `Child`, `E`, `[1]` | `TClass($Child)`, `TInt`, `TFloat`, `TNull`, `TClass($String)`, `TBool`, `TEnum($E)`, `TObject`, `TFunction`, `TObject`, `TObject`, `TClass(hl.types.$ArrayBase)` |
| `Main.twice()` with `using Main.Ext` and `twice(d:Dynamic)`; `Std.string(Child)`, `trace(Child)` | `$Main!`; `$Child`; `$Child` |
| `Type.getClass("s") == String`, `Type.getClass([1]) == Array`, `Type.getClass(1)` | `true`, `true`, `null` |
| `Type.resolveClass("Child") == Child`, `Type.resolveClass("Nope")` | `true`, `null` |
| With `-dce full`: `Type.getInstanceFields(Child)`, `getClassFields(Child)` | `[]` and `[kept]`: fields that DCE removed are not listed |

So on HashLink a class value is the class's global object (`hl.BaseType.Class`, the `global_value` of its `hl_type`),
an enum value's enum is the enum's (`hl.BaseType.Enum`, holding `__constructs__` and the values without arguments), and
the lists come from the runtime type, after DCE. A class prints with HashLink's `$` prefix. A structure, a class and an
enum are `TObject`.

## What Haxeon has today

- **Types as values exist only as `Std.isOfType`'s second argument**: the typer makes a `TClassRef`, IR has
  `TypeValue(output, type)`, HashLink lowers it to `OType` (the `hl_type*`), and Wasm to an `i32` runtime type id
  (`WasmTypeIdPlan`, hash-based and module-owned). `TClassRef` anywhere else is an internal error in `IrGenerator`
  ("Class references are only valid for static members").
- **HashLink's type table** has an `HObj` per class (`HlSymbolTable.internObject`), named by Haxeon's object name, with
  its base, fields (plus Haxeon's interface cache slots and reserved patch slots, unnamed), methods, and a global slot
  of the object's own type that nothing uses; an `HEnum` per enum with constructor names and payload types and no global.
  Statics are separate globals. Value objects are `HStruct`, structures `$anon:{...}` objects.
- **Wasm** objects carry the runtime type id (a header word on wasm32, a field on wasm-gc); names exist only where a
  table needs them: `EnumStringDescriptors` for enum printing, `IrObjectReflection` for `Reflect` on object layouts.
- **Dense class ids**: `IrClassIds` assigns each class an id, stable across a live session, and IR has
  `ClassId(output, object)` (`INTERFACE_VALUES.md`); no backend lowers it yet.
- **Exact-type tests**: `STRUCTURE_VALUES.md` adds `exactType(v) == C` (`OGetType` and an `OType` compare on HashLink,
  `ref.test` on wasm-gc, the header id on wasm32) for structure and erased-owner dispatch (`IrShapeDispatch`).
- **Enum values behind `Dynamic`** keep their concrete enum: an enum box carries its type, and `IrEnumDynamicDispatch`
  dispatches by testing each requested enum type in turn.
- **Generic specializations** have physical names (`Box<Int>` is its own class, a boxed `Tree<String>` is
  `Tree$enum-specialization:<hash>`, `EnumRuntimeType`), so a physical type is not a Haxe type.

## Design

### 1. One runtime descriptor per declaration

A `Class<T>` or `Enum<T>` value is a reference to a **type descriptor**: an instance of a runtime class
`haxeon.runtime.TypeDescriptor` (stdlib), one per class, interface or enum *declaration*, emitted as a constant global:

```haxe
final class TypeDescriptor {
	final kind:Int;                      // class, interface, enum, core type
	final name:String;                   // the Haxe path: "haxe.ds.StringMap", "Child"
	final base:Null<TypeDescriptor>;     // getSuperClass
	final instanceFields:Array<String>;  // getInstanceFields, Haxe's order
	final classFields:Array<String>;     // getClassFields
	final constructs:Array<String>;      // getEnumConstructs
	final values:Array<Dynamic>;         // allEnums: the constructors without arguments, boxed
	// phase 3: construct, constructEnum (closures), see below
}
```

- **Per declaration, not per physical type.** Every specialization of `Box<T>` and every boxed specialization of
  `Tree<T>` maps to the one descriptor of its declaration, so `Type.getClass(intBox) == Type.getClass(stringBox)`,
  as in Haxe. The name is the Haxe path, never Haxeon's object name. A structure's record (`$anon:`), an interface
  box, an inline enum lane or a value-array helper object has no descriptor: `getClass` of it is `null`, `typeof` is
  `TObject`.
- **The lists are the declared ones**, in HashLink's order (the class's methods, then its variables, then its base's,
  private ones included), never the physical fields: no interface cache slots, reserved slots, scalar lanes or presence
  bits. They are compile-time constants built from the typed declarations.
- **Same on every backend**: the descriptor is ordinary IR (a generated global and its initializer), so wasm32 and
  wasm-gc need no new runtime code for names or lists, and the `IrInterpreter` runs it.
- **Built from the declaration alone**: its contents are a function of the declaration, so its digest is the
  declaration's (warm equals cold, and it fits the query engine's content digests).
- **Identity**: one global per declaration, so `==` on class values is reference identity on all targets.

Options for the value itself:

- **A: a descriptor object (recommended).** It boxes to `Dynamic` as an ordinary object, so `typeof(Child)` is
  `TObject` and `Std.string` can print it, and it is one model on all backends.
- **B: the backend's native type** (`hl_type*` on HashLink, the type id on Wasm). Free on HashLink, but a Wasm `i32` is
  not an object (boxed to `Dynamic` it is an `Int`), HashLink's `hl_type` names physical types (specializations,
  `$anon`, reserved slots), and statics are not on it. Rejected.

### 2. From an object or enum value to its descriptor

`getClass(o)` needs the descriptor of the object's class at run time. This is where it meets the structure-values
track: both read the object's exact class, the structure dispatcher to pick a layout, `getClass` to pick a descriptor.
One primitive per question:

- **`exactType(v) == C`** (is the object exactly of class `C`) stays `OGetType` and an `OType` compare on HashLink, the
  header or field id on Wasm, for `IrShapeDispatch`.
- **`getClass(o)` is `ClassId(o)` indexing a descriptor table (option 2a, chosen).** The table is a generated global
  array indexed by `IrClassIds`, one entry per class id (`null` for a class without a descriptor, the declaration's
  descriptor for each specialization). `ClassId` is the shared primitive: on HashLink it is the `cid()` method of
  `INTERFACE_VALUES.md`, on Wasm it reads the header or field id, as the interface dispatch does.

Rejected:

- **2b: HashLink's `global_value`.** HashLink reserves a global per `HObj` (Haxeon leaves it unused); set to the
  descriptor, `getClass` would be `OGetType` and the type's global, as genhl does. It ties the model to a VM-specific
  slot, and a live patch replaces `hl_type`s, so the identity would follow the physical type, not the declaration.
- **2c: a `$descriptor()` method per class.** It is only how HashLink implements `ClassId` (`cid()`); a second method
  would duplicate it.

On a `Dynamic` value, `getClass` first tests the value's kind (null, number, bool, string, array, function, enum box,
object), as `Std.isOfType` does today, and only reads the class of an object. A structure-typed value is the object
itself (`STRUCTURE_VALUES.md`), so `getClass` of a structure that holds a class instance is that class, as in Haxe.

`getEnum(v)` on a value of a known enum type is a constant. On `Dynamic` or `EnumValue` it is its own IR operation,
`EnumDescriptorOf(value)`, lowered for now as the existing test chain of `IrEnumDynamicDispatch` (one arm per boxed enum,
linear in their number), so the lowering can later move to enum ids in the same table without changing its users.
`HEnum` gets no global. The same operation serves `Type.enumConstructor` and `Type.enumParameters` on `Dynamic` (the
descriptor's `constructs[index]`, and a per-enum generated helper for the arguments, as phase 1 writes them out inline).

### 3. Typing

- **Types.** `Class<T>`, `Enum<T>` and `EnumValue` become types of the typer: `Class<T>` and `Enum<T>` lower to
  `Obj(TypeDescriptor)` in IR whatever `T`; `EnumValue` lowers to `Dyn` (an enum value that has lost its enum is boxed
  like any enum behind `Dynamic`). Every enum value converts to `EnumValue`; a class value to `Class<Dynamic>`; both to
  `Dynamic`. `T:EnumValue` is accepted as a constraint, which lets Haxe's `haxe.EnumTools` be ordinary stdlib code (and
  phase 1's typer-provided `EnumValueTools` move into it).
- **A type name in value position** (`var c = Child;`, `f(Child)`, `Main.twice()`) is the descriptor:
  `TClassRef(name)` gets the type `Class<Name>` (or `Enum<Name>`) and lowers to a new IR instruction
  `TypeDescriptor(declaration)`, which carries the declaration's identity, not a physical type; each backend lowers it
  to a read of the provider row's global (not a `GlobalGet` of a named global, which would add another `$`-name family,
  against ADR 0003 decision 5). This replaces today's internal error. `Name.member` stays a static access.
  An extension whose first argument is `Dynamic` or `Class<T>` (or `Enum<T>`) then applies to a class named as a
  value, as Haxe does (`fields.ml` types the class as `TAnon` of its statics and unifies it with `Dynamic`); today
  `CallResolver.typeMethodCall` refuses an extension on a `TClassRef` receiver.
- **Folding.** Where the type is known where it is typed, `Type.getClassName(Child)`, `Type.getEnumName(E)`,
  `getEnumConstructs(E)`, `getSuperClass(Child)`, `Color.getName()` and `Color.createAll()` need no descriptor read; the
  typer can fold them to constants, so a program that only uses them with type names needs no descriptor at all. This
  is an optimization, not a second semantics: both paths read the same declared lists.
- **Null safety.** Haxe's signatures return `Class<T>`, which may be null. Haxeon keeps null in the type where a call
  can return it: `getClass(o:Dynamic):Null<Class<Dynamic>>`, `getSuperClass`, `resolveClass` and `resolveEnum` return
  `Null<...>`; `getClass(o:T)` for a non-null class type `T` returns `Class<T>`; `getEnum(e:EnumValue):Enum<Dynamic>`.
- **`typeof`** returns Haxe's `ValueType` enum (stdlib), built from the kind test above: `TClass(descriptor)`,
  `TEnum(descriptor)`, `TObject` for structures, descriptors and dynamic objects.

### 4. Pruning, providers and warm builds

- A descriptor is a provider row `(declaration, type-descriptor)` (`PROVIDER_INVENTORY.md`), generated from the
  declaration only, so its fingerprint is the declaration's and a warm build agrees with a cold one
  (`HELPER_OWNERSHIP.md`).
- The walk reaches a row from a `TypeDescriptor(T)` instruction (a typed operation with a subject), and from a dynamic
  site with no subject (`getClass`, `getEnum`, `typeof` on `Dynamic`): edge 4 of `REACHABILITY_WALK.md`, the rows of
  every *created* type. A class that is never created has no instance to ask about, so its descriptor is not kept for
  `getClass`; `getSuperClass` reaches the base's row from the subclass's.
- A descriptor names fields and constructors but holds no function, so it keeps no code alive. `allEnums` reaches the
  enum's constructors without arguments (they are constants).
- Live patching: descriptor globals are kept across a patch like static fields, and replaced only when the
  declaration's digest changes. The class-id table is regenerated by each patch (`IrClassIds` keeps the ids) and points
  at the kept globals. A changed declaration gets a new descriptor, so a class value held from before the patch
  compares unequal to the new one: that is the patch semantics, as for any value of a replaced type.

### 5. Phase 3: names and construction

- `resolveClass(name)` and `resolveEnum(name)` read a generated name table of descriptors. Which declarations it holds
  is the real question, because a name in a string defeats the walk. Options:
  - **3a (recommended): Haxe's `-dce std` rule.** A reachable `resolveClass` or `resolveEnum` site roots every
    declaration of the program's own modules (not the standard library's) and every `@:keep` declaration, with their
    constructors; a program that never calls them keeps nothing more. Equal to Haxe's default.
  - **3b: only `@:keep` declarations and created ones.** Smaller, but `resolveClass("Plugin")` of a class only named
    in configuration returns null where Haxe finds it.
- `createInstance(c, args)` calls a generated adapter of the constructor, `(Array<Dynamic>) -> Dynamic`, held by the
  descriptor (a closure field) and generated only for rooted declarations; arguments are checked casts, as a `Dynamic`
  call's are.
- `createEnum`, `createEnumIndex`: one generated helper per enum (index and `Array<Dynamic>` in, value out), held by
  the descriptor, with checked casts of each argument.
- `createEmptyInstance` makes an object whose fields have not been initialized. A non-nullable reference field is then
  null, which Haxeon's null safety rules out. This needs a decision (below).

## Slices

1. Typer: `Class<T>`, `Enum<T>`, `EnumValue`, type names as values, folding of the known-type calls, `Main.twice()`.
   No runtime change; anything that needs a descriptor is `E1007` with a pointer to slice 2.
2. Descriptors: the stdlib class, the provider rows, `TypeDescriptor(T)` in IR and its lowering (a global read) on the
   three backends, `getClassName`/`getEnumName`/fields/constructs on values, `allEnums`, printing.
3. Object to descriptor (`ClassId` and the table), `EnumDescriptorOf`, `getClass`, `getEnum` and `typeof` on
   `Dynamic`, `enumConstructor` and `enumParameters` on `Dynamic` and `EnumValue`; `haxe.EnumTools` as stdlib code.
   Needs `ClassId` lowered on every backend (`INTERFACE_VALUES.md`).
4. Phase 3, when a port needs it.

Each slice is differential against Haxe on HashLink and in the Wasm parity corpus.

## Decisions for the user

1. **Null in results**: keep `Null<Class<...>>` where Haxe can return null (above), or follow Haxe's signatures.
2. **Printing a class value**: HashLink's `$Child` (what the differential tests compare against) or the plain name.
3. **Phase 3 retention**: 3a (Haxe's `-dce std`) or 3b.
4. **`createEmptyInstance`**: not provided, provided only for classes whose fields all accept null or have a default,
   or provided as an unsafe escape that leaves non-null fields null.
5. **Instance fields after pruning**: Haxe lists only the fields DCE kept; this note lists the declared fields whatever
   the walk keeps, so the result does not depend on the build mode.

## Review by haxeon-e4 (IR and HashLink owner, 2026-11-19)

haxeon-e4 agrees with the model: one descriptor per declaration, declared lists independent of pruning, ordinary IR on
every backend, a provider row keyed by the declaration. Its answers, folded in above:

1. Object to descriptor: option 2a. `ClassId` is lowered on HashLink as the `cid()` method; `exactType` stays `OGetType`
   for `IrShapeDispatch`. Not 2b (VM-specific, and the identity would follow the patched `hl_type`).
2. A typed instruction, `TypeDescriptor(declaration)`, not a named `GlobalGet`.
3. Enums: the `IrEnumDynamicDispatch` chain for slice 3, behind `EnumDescriptorOf(value)`; no `HEnum` global.
4. Patches: descriptor globals kept like statics, replaced on a declaration digest change; the table regenerated per
   patch; a held class value of a changed declaration compares unequal.
5. Descriptor contents from the declaration alone; slice 1's folding is kept.
