# Declared value equality

Value equality is a capability declared through conformance. There is one equality for a type, selected consistently by
`==`, `!=`, `haxeon.Equality.equals`, containing conforming values, and maps keyed by `Hashable` values.

```haxe
struct Color implements Hashable { /* stored fields */ }
struct Record implements Hashable { /* stored fields */ }
```

`Equatable` supplies equality. `Hashable` extends `Equatable`. The compiler synthesizes the implementation when every
stored field supports the requested conformance; diagnostics identify the field that prevents synthesis. A handwritten
`equals(other:T):Bool` satisfies `Equatable`. A `Hashable` type with a handwritten equality must also provide
`hash():Int`, because a synthesized field hash might distinguish values that its equality considers equal. A custom
hash may also accompany synthesized equality.

Structs that do not conform to `Equatable` cannot be compared with `==` or `!=`. Classes cannot conform to `Equatable` or `Hashable`; use a struct for value equality. Class and interface references
always compare by identity, including interface views of boxed values. Explicit class methods named `equals` or `hash`
do not change these rules. Generic value-capability bounds reject class and interface type arguments. Nullable conforming values compare absent values with absence and otherwise use their element's
declared equality. Float equality follows IEEE rules (`NaN != NaN`, `0.0 == -0.0`); float hashes treat the two zero
representations alike.

`haxeon.Equality.equals` chooses the same implementation as `==` from its statically known argument type. When its
argument is genuinely `Dynamic`, the runtime dynamic equality path remains available. Reflection, dynamic values and
native escapes keep their required boxing and runtime handling.

`Diffable` is a separate opt-in for declaration-order field masks:

- `Diff.mask(before, after)` returns the bits for fields whose declared equality reports a change.
- `Diff.apply(target, before, after)` copies changed fields into `target` and returns those bits. Every destination field
  must be writable; the diagnostic names an immutable field.
- `Diff.bit(\Type.field)` and `Diff.all(Type)` are compile-time constants. At most 32 stored fields are supported.
- `Diff.copy(value)` is only for mutable `Diffable` classes. Struct values already copy on binding.

Field numbering is an explicit contract for each type. [Key paths](KEY_PATHS.md) supply the typed field references used
by `Diff.bit`; the former string field-name form is removed. Use `Diff.mask(a, b) == 0` for content equality of
`Diffable` class snapshots. Synthesis still requires value conformance on each field; class references in a value
therefore need explicit equality that compares those references with `==`.
