package haxe;

/**
 * Haxe's extensions of an enum itself (`Color.getName()`, `Color.createAll()`). Haxeon has none of them yet: they take the
 * enum as a runtime value, `Enum<T>`, which is the Type API's next step (`docs/design/TYPE_VALUES.md`).
 */
class EnumTools {}

/**
 * Haxe's extensions of an enum value: `getName()`, `getParameters()`, `getIndex()` and `equals(other)`, the same as
 * `Type.enumConstructor`, `Type.enumParameters`, `Type.enumIndex` and `Type.enumEq`. As in Haxe they apply to every enum
 * value without a `using`, after the extensions of the value's own `@:using` and of its module's `using`. The typer provides
 * them, as it does the `Type` functions they call, so this class declares none (`StaticExtensions`).
 */
class EnumValueTools {}
