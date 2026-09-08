# Semantic type contract

This compiler uses nominal classes, interfaces, and enums. Type aliases are
transparent: their source spelling is retained in the syntax tree and diagnostics,
while equality, interface conformance, and compatibility use the resolved type.
All named types must resolve to a declaration or the built-in `Dynamic` type.
Alias, class-inheritance, and interface-inheritance cycles are errors.

Implicit conversions are deliberately limited:

- Every type converts to `Dynamic`.
- A class converts to its base classes and implemented interfaces.
- An interface converts to its base interfaces.
- A reference converts to a compatible `Null<T>`, and `null` converts to any
  nullable type.
- Arrays are invariant. Maps require equality.
- Function values are contravariant in their arguments and covariant in their
  result. Conversions preserve the declared callable type and adapt through the
  runtime's checked function conversion.
- `Int` converts to `Float`; other numeric conversions require explicit operations.

Semantic conversions are represented explicitly in the typed AST. Declaration
IDs, function-local binding IDs, and persistent runtime IDs are separate identity
domains. A representation-preserving conversion still changes the semantic type
of the expression; it must not silently replace an annotated binding's type.
Generic declarations retain their semantic type arguments separately from their
specialized runtime representation.
