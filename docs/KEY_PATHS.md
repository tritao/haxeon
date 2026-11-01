# Key paths

Status: design (2026-11-01); not implemented. Key paths are typed references to
stored fields, for APIs such as bindings and `Diff.bit`. They are a general
language feature and do not give the compiler knowledge of UI concepts.

`\T.field` has type `KeyPath<T, V>`, where `V` is the declared field type.
The compiler resolves the field and its accessibility at the expression site;
a missing or inaccessible field is an error. A path refers to the declaration,
not a string looked up at run time. Renaming a field therefore requires updating
its paths. Static fields, methods and computed properties are excluded: they do
not have the stored-place semantics on which this design relies.

Paths compose only when the first value type is the second root type. Reading a
composed path follows the same copy, nullability and access rules as spelling
out the field chain. Optional traversal is deferred until its short-circuit and
write semantics are designed; a nullable intermediate is not silently unwrapped.
Writing through a path requires a writable root place and writable fields along
the chain, just as a direct assignment does. In particular, a path does not
grant mutation of a final field or of a temporary struct.

For a concrete struct root, a statically known path lowers to the target's
constant field offsets and creates no object. A composed path folds its offsets
where the representation permits it; managed references are followed at the
appropriate step. Offsets are target-specific implementation details, not
portable serialized identifiers. A path that escapes as a first-class value may
need a runtime representation; generic specialization should retain constants
when the path and root are statically known. Wasm GC field indices and HashLink
offsets need not have the same representation.

Equality compares the resolved root and field sequence, not physical offsets:
distinct fields can share an offset in different layouts. Paths are invalidated
and recompiled when a referenced declaration's layout or field contract
changes. They do not retain an instance and do not expose private fields to a
caller that could not name them.

`Diff.bit` can later accept a direct, stored-field path rooted at its `Diffable`
type. Its bit is the declaration-order field number already used by the diff
mask, not a byte offset. Nested paths are not a single bit: the outer field is
the unit represented by the current mask. This avoids conflating layout with
the explicitly exposed field-numbering contract. String-based `Diff.bit`
remains the intended stage-one interface until key paths themselves are
implemented; this document does not introduce a second implementation.
