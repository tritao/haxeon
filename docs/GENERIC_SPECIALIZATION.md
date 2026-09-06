# Generic specialization invariants

Generic calls retain their semantic type arguments while emitted bodies use a deterministic representation chosen per parameter.

- `shape` shares a body when a parameter occurs only in ABI-erased positions.
- `layout` keeps the concrete type when it appears inside arrays, maps, functions, nullable values, anonymous records, or applied types.
- `constrained` keeps the concrete type so constrained operations and dispatch remain valid.

The policy label and representation signature are both part of the generated function name and persisted registry key. Changing policy therefore creates a new identity instead of reusing an incompatible body.

Generated bodies are owned by the module declaring their generic origin. Incremental compilation regenerates them when a generic body changes and prunes them when that owner becomes unreachable or the specialization is no longer requested.

Constraints are semantic signatures. Changing a function or owner constraint invalidates dependent callers even when the runtime ABI shape is unchanged.
