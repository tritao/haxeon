# UI value types

This implements the value conversions in stage 0 of [ADR 0002](../../../docs/adr/0002-reactive-ui-model.md); the
remaining dynamic boxes listed below are still under investigation.

`Rect`, `Insets`, `Color`, `LayoutAxis` and `Transform2D` are immutable `@:structural` structs. Their fields are final;
replace the whole value to change one. Their `==` and `!=` comparisons are fieldwise. Optional values use `Null<T>`,
including inline optional fields; absent and present remain distinct. `LayoutStyle` owns these values inline in one
object, and structural style fingerprints and hashes still cover their fields.

The native layout interface uses an output buffer for resolved geometry. The session reuses that buffer and holds on to
immutable results when their fields have not changed. This keeps the C ABI explicit and avoids rebuilding geometry that
is already available. The other values continue to cross the native boundary through the existing scalar encoder.

Inlining values enlarges their holders. The conversion therefore also removes unnecessary repeated holder creation:
retained docking panes and clean inspector alternatives reuse their trees, property controls reuse private style templates,
and computed width and height share a copy-on-write inline-axis holder. The inspector cache is bounded, and changed
transient editor state is discarded on a selection change as before. Retained alternatives have separate state scopes,
validate dependencies and topology, and rearm their self-updating children before reuse. The verification mode continues
to compare retained trees to fresh builds.
The textual tree dump does not consume inspection entries or rule provenance, so it skips building those details while
still calling the same copy hooks and propagating their failures. Public inspection snapshots still include the entries
and expose their values to reflection; the dump's rendered output is unchanged. This removed 728 `LayoutAxis` boxes
from the 30-cycle interaction census (740 to 12).
For cacheable local styles, the resolver also reuses its existing immutable style snapshot for padding, background and
transform until a caller asks for their dynamic values. Forks share the materialized box, preserving the existing
dynamic identity, while each typed read uses the snapshot directly. Signed-zero differences and NaNs use the original
boxed path when a cached fingerprint cannot preserve the exact local value. A computed style keeps its snapshot alive
even after resolver cache eviction, so eviction cannot change a resolved value.

Struct boxes can still occur at real dynamic and reflective boundaries. For example, inspecting a dynamic style value
materializes a box; a type census should distinguish `@`-prefixed struct boxes from the former class allocations. The
compiler scalarizes supported direct and typed calls, optional locals and inline field copies; unsupported or escaping
values retain the normal boxed ABI. See [STRUCTS.md](../../../docs/STRUCTS.md) for the calling conventions and attribution.
In particular, `StyleValue.value` is a public `Dynamic` field. Independent boxes can compare differently by dynamic
identity, and HashLink can change a boxed value through `Reflect`. Sharing boxes across declarations or refreshes would
therefore change observable behavior. Removing these allocations needs a representation that preserves that boundary,
not a pool of shared boxes.

The same-machine 30-cycle HashLink census starts after the initial editor frame and includes scenario setup. It counts
allocations by type. Entries after conversion are
struct boxes (`@haxeon.ui.*`) at dynamic boundaries. The per-action KiB and Wasm GC Showcase comparisons are in
[STRUCTS.md](../../../docs/STRUCTS.md).

| Scenario | Rect | Insets | Color | LayoutAxis | Transform2D |
| --- | ---: | ---: | ---: | ---: | ---: |
| Interaction, classes → current | 7,511 → 0 | 70 → 44 | 487 → 486 | 1,007 → 12 | 1,722 → 0 |
| Tab matrix, classes → current | 12,586 → 0 | 8 → 0 | 1,185 → 0 | 4,956 → 0 | 351 → 0 |
| Selection stress, classes → current | 4,307 → 0 | 512 → 0 | 866 → 0 | 5,364 → 0 | 456 → 0 |
