# Generated structural equality

`haxeon.Equality.equals(left, right)` generates a comparison for the static
type of `left`. The second value must be assignable to that type. It compares
anonymous structures and typedefs field by field, arrays by position, enums
by constructor and payload, and maps by key and value regardless of insertion
order. Nested combinations use the same rules recursively.

Primitive fields use Haxe `==` semantics, abstracts compare by their underlying
values, and byte buffers compare by content. In particular, `NaN` differs from
itself, while `0.0` and `-0.0` compare equal. Nullable values compare equal
when both are null; otherwise their contents are compared. Map keys use the
map's own key lookup semantics and currently support `Int`, `String`, and
parameterless enum constructors. Value classes and classes marked
`@:structural` compare their stored fields in declaration order; a structural
reference compares equal to itself first, and to null only when both are null.
Other class instances, `Dynamic`, functions, and other unsupported types
produce a compile diagnostic.

This helper does not change `==` or `Type.enumEq`. It is intended for typed
data descriptions; cyclic runtime object graphs are not supported.

## Structural classes

A class marked `@:structural` (or a value class) is also accepted by
`haxeon.Structural`, whose operations are generated from the class's stored
instance fields, in declaration order, at each call site. Adding a field to the
class updates every one of them; a field type they cannot handle is a compile
error rather than a silent omission.

- `Structural.copy(value)`: a new instance, made with the class's no-argument
  constructor, with every field copied shallowly. Final fields are an error.
- `Structural.hash(value)`: an `Int` hash consistent with `Equality.equals`:
  equal values hash equally. Nested structural fields are hashed by content.
- `Structural.changedMask(a, b)`: one bit per field, set where `Equality.equals`
  finds the two values' fields different. At most 32 fields.
- `Structural.assignChanged(target, before, after)`: copies into `target` each
  field that differs between `before` and `after`, leaves the others as they
  are, and returns the mask of the fields it copied.
- `Structural.fieldBit(Type, "field")` and `Structural.allFieldsMask(Type)`:
  compile-time constants for those masks. A misspelled field is an error, so a
  hand-written group of fields can be checked against `allFieldsMask` in a test.

A structural class may not extend another class: the base's fields would be
left out. `LayoutStyle` in the UI package uses these for its copy, its restyle
delta, its frame comparison and its cache keys.

The UI package uses them beyond `LayoutStyle`: `Color`, `Insets`, `LayoutAxis`, `Transform2D`, `Rect`, `TextStyle`,
`ParagraphStyle`, `Shortcut`, `EffectParameter`, `InkOverflow` and `CustomEffectDefinition` are compared with
`Equality.equals`, so their comparisons cannot fall behind their fields. What stays written out, and why:

- `Semantics.same`: the value compares through `sameValue` and a deferred source is not a field to compare.
- `Mask.isEqual`: its image is compared by identity, which `Equality` does not do for a plain class.
- Decorations and effects extend a base class, which a structural class may not do.
- String keys that spell out the fields of `Color`, `LayoutAxis`, `Insets`, `Transform2D`, `TextStyle` and `ParagraphStyle`
  (the style cache and the dock's label widths): a hash could collide. Each is paired with a field list that a test checks
  against `Structural.allFieldsMask`, so a new field fails the test until the key names it.

