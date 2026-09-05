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
- Arrays are invariant. Maps and function values currently require equality.
- Numeric types do not convert implicitly.

Semantic conversions are represented explicitly in the typed AST. Declaration
IDs, function-local binding IDs, and persistent runtime IDs are separate identity
domains. Type-parameter symbols have a declaration representation, although the
source language does not yet expose generic declarations.
