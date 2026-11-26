# Enum members and per-case constants

Status: decided (2026-11-25). Members (stage 1) and per-case constants (stage 2) are implemented; tools are next. Haxeon's `enum` becomes the one construct for a closed set of values:
cases with optional payloads (as today), any methods and static members, and immutable per-case constants. This is a
Haxeon extension; stock Haxe rejects it, so the compiler's own source does not use it (it still builds with stock
Haxe).

## Today

- **Cases and payloads** are Haxe's: an `enum` is an algebraic data type with generic parameters, recursion and
  exhaustive matching. Payload-free enums are scalar tags ([STRUCTS.md](STRUCTS.md#payload-free-enums-are-scalar-tags)).
- **Methods** are allowed only to implement an interface the enum declares (`enum E implements Equatable` with its
  `equals`); any other method is `E1025`, and `static` members are a syntax error.
- **Closed sets with a fixed external code** are `enum abstract X(Int) implements RawRepresentable`, whose
  representation *is* the code; **combinable sets** are `enum abstract X(Int) implements Flags`
  ([STRUCTS.md](STRUCTS.md#closed-raw-value-enums)).
- **Data that depends on the case** is written as a `switch` in a separate class (`EffectParameterTypeUtil`) or as
  `Int` constants in a class (`ScrollAxis`, `EnvironmentColorScheme`), which nothing checks.

## Members

An enum declares instance methods, static methods and static fields like a class:

```haxe
enum EffectParameterType {
	Float;
	Vec2;
	Vec4;
	Color;

	public static function parse(label:String):Null<EffectParameterType> { ... }

	public function isVector():Bool return this != Float;
}
```

- `this` is the value; `switch this` is exhaustive like any switch over the enum.
- Visibility is the class rules: `public`, `private`, `internal`; unwritten is private.
- Instance methods are statically dispatched, as conformance methods are today, so a call costs what a call to a
  static function taking the value does. An interface view keeps its existing boxed dispatch.
- A method may declare type parameters of its own (`function map<U>(f:T->U):Slot<U>`), inferred at each call as a
  generic class method's are. Its body is typed once per enum and method type arguments, as a method of a generic
  enum already is per the enum's.
- A member cannot share a name with a case. Static fields follow class static initialization, including the
  order-independent `static var x = []` rule.
- No instance fields: a value's data is its payload, and a case's data is its constants (below).

## Per-case constants

An enum declares `final` fields; each case gives their values as a struct literal after its name and payload:

```haxe
enum EffectParameterType {
	/** How many numbers a parameter of this type takes. */
	final componentCount:Int;
	/** The type's name, as shaders spell it. */
	final label:String;

	Float {componentCount: 1, label: "float"};
	Vec2 {componentCount: 2, label: "vec2"};
	Vec4 {componentCount: 4, label: "vec4"};
	Color {componentCount: 4, label: "color"};
}

enum Shape {
	final sides:Int = -1;

	Circle(radius:Float) {sides: 0};
	Square(side:Float) {sides: 4};
	Polygon(points:Array<Point>);
}
```

- **Immutable.** Only `final`; `var` is an error. A case is a value, and a mutable field on it would be global state
  hidden in a constant.
- **Complete at the declaration.** Every case sets every field that has no default, once. Adding a case without its
  data fails where the case is declared.
- **Constant values.** A value is a compile-time constant: a literal, a payload-free case of an enum, `null` for a
  nullable field, or an operator over constants. Types are `Int`, `Float`, `Bool`, `String`, payload-free enums and
  `Null` of those.
- **Reads.** `value.componentCount` reads the case's constant: folded when the case is known, otherwise one switch on
  the tag. No value grows: the data is per case, not per value, so payload enums keep their layout.
- **Names.** A constant cannot share a name with a case or a member.
- **Documentation.** A constant's comment documents the field; the API reference shows each case's values beside the
  case.

Lowering adds no new IR: each constant becomes an inline getter whose body is a `switch this` over the cases, and the
backend's switch lowering handles it (a jump table where the backend makes one).

## Which construct

| A set that is | Declared as |
| --- | --- |
| closed, values chosen in Haxe code | `enum` |
| closed, values fixed by a native, wire or file format | `enum X:Int` or `enum X:String` ([below](#raw-value-enums)) |
| combinable bits | `enum abstract X(Int) implements Flags` |
| open (codes from outside that no case may name) | an abstract over `Int` |

## Raw-value enums

Status: decided and implemented (2026-11-26). Before this, closed sets with a fixed external code were enum abstracts,
which leave two constructs for closed sets; the raw form was the weaker one (no per-case constants, `this` is the bare
code, and `cast` makes values outside the set).

```haxe
enum PixelFormat:Int {
	Rgba8 = 1;
	Bgra8 = 2;
	R8; // 3: an omitted Int value counts up from the previous one, a String value is the case name

	public function bytesPerPixel():Int
		return this == R8 ? 1 : 4;
}
```

- **Payload-free cases with a raw value** of type `Int` or `String`, a compile-time constant, unique within the enum.
- **The representation is the raw value**, so native and wire boundaries cost nothing. It is compiled as an enum
  abstract over the raw type; `Null<E>` behaves as `Null<Int>` or `Null<String>` does.
- **No implicit conversions.** `rawValue` gives the code; `E.fromRaw(code)` returns the case, or null for a code
  that names none. A `cast` to the enum is unchecked, as every `cast` is.
- **In its methods `this` is the enum value**, as in any enum; `rawValue` reaches the code.
- **Members** are those of any enum: methods, static methods and static fields. Per-case constants come later.
- **A code this build does not know never reaches a case.** A value read from native code or the wire may carry a code
  newer than the binding. It keeps its representation, as every native value does, and a `switch` over the enum has an
  implicit default that throws a `haxeon.UnmatchedValue` (a `haxe.Exception`, since it is a bug) for it, so no arm runs for a code that is not its own. Code that dispatches on codes from
  outside, such as the platform event decoder, checks with `fromRaw` and reports an unknown one explicitly (`Raw`)
  instead of failing.
- **No `RawRepresentable` interface.** Only its own tests used it as a bound; a generic need later is met by interfaces
  with static requirements and `Self` ([FUTURE_LANGUAGE.md](FUTURE_LANGUAGE.md)), which raw-value enums satisfy with
  their synthesized members.
- **`Flags` stays separate**: combinable bits are not a closed set of cases.
- **Enum abstracts remain** for Haxe code and for the compiler's own source, which builds with stock Haxe. Haxeon's
  packages and generated bindings use raw-value enums.

Done in stages: syntax and typing with tests on every backend; tools (API model and site, formatter); the binding
generator; migration of the packages, ui's keys and accessibility actions included; removal of `RawRepresentable`.

## Not in scope

- GADTs (a case refining the type parameter) and open, extensible enums.
- Methods on individual cases (Java's constant-specific bodies): a `switch this` in the enum's method says the same
  in one place.
- Reflection over per-case constants.

## Stages

1. **Members.** Lift `E1025` for enum methods; parse, type and lower `static` methods and fields in enums; API model,
   doc and LSP support for enum members.
2. **Per-case constants.** Parse `final` fields and case blocks; check completeness, constant values and names; lower
   to inline getters; API model shows each case's values.
3. **Tools.** Formatter, LSP completion and hover, the API site's case table.
4. **Tests.** Programs for each rule and each error, on HashLink, Wasm32 and Wasm GC with inlining on and off. Neither
   the stock-Haxe differential tests nor self-compile can exercise the feature.
5. **Adoption in `ui`.**
   - `EffectParameterType` takes `componentCount` and `label` as constants; `EffectParameterTypeUtil` goes.
   - The `Int`-constant classes that are ordinary UI choices become enums: `ScrollAxis`, `ScrollbarVisibility`,
     `EnvironmentColorScheme`, `EnvironmentOrientation`, `EnvironmentPointer`, `GestureKind`, `Easing`.
   - Those that cross to native map through `haxeon.ui.NativeEnums`, as the other UI choices do.
   - `EnvironmentCondition`'s integer encoding becomes a payload enum.
