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
parameterless enum constructors. Class instances, `Dynamic`, functions, and
other unsupported types produce a compile diagnostic.

This helper does not change `==` or `Type.enumEq`. It is intended for typed
data descriptions; cyclic runtime object graphs are not supported.
