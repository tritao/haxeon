# Generic specialization invariants

Generic calls retain their semantic type arguments while emitted bodies use a deterministic representation chosen per parameter.

- `shape` shares a body when a parameter occurs only in ABI-erased positions.
- `layout` keeps the concrete type when it appears inside arrays, maps, functions, nullable values, anonymous records, or applied types.
- `constrained` keeps the concrete type so constrained operations and dispatch remain valid.

An unconstrained struct argument also uses `layout`, including a struct with managed references that has no native
layout. Its fields and value calling convention depend on the declared struct, so two different structs do not share
the erased reference body even when their current fields have the same shapes. Ordinary class arguments continue to
share the `shape` body. Generic class fields and methods are still erased; this function policy does not yet provide
specialized generic owner storage or guarantee allocation-free value returns on every target.

With inlining disabled, a managed `struct` with a null reference field passed through `identity<T>(value:T):T` allocates
zero times for 1,024 calls on Wasm GC and 2,048 times on Wasm32. The equivalent class allocates 1,024 times on either
target. Wasm GC uses its scalar-result ABI for this case; Wasm32 needs a value-result convention that keeps scalar and
reference lanes in locals before generic value returns meet the no-allocation goal. A separate Wasm GC regression test
keeps a non-null managed object in the value, passes it through a typed closure and checks zero allocations for 8 and
1,024 calls, with inlining on and off.

The initial editor measurement after this policy change reported 12.6 KiB for `hover-field`, versus 12.4 KiB at the
starting baseline and in a build made with the committed pre-change compiler. In matched 60-cycle allocation censuses,
both builds recorded 533,935 allocations and identical instrumented action medians. Two alternating pairs using the
same uninstrumented capture path measured 12,704/12,712 and 12,704/12,704 bytes for control/current respectively.
This evidence is consistent with capture accounting variability; the source of the initial 224-byte difference is not
established, and it does not justify a lower budget ceiling. An isolated census of the hover-other/hover-field sequence
recorded 101,358 allocations in each build with equal per-action medians; total allocation sizes were 8,109,824 bytes
for control and 8,109,608 for current, with the entire difference in byte buffers.

The same-machine selection-stress census was 342,354 allocations, compared with 342,877 at the starting baseline.
The 120-frame fixed-time Wasm GC Showcase counts were 5,896, 5,896, 5,896 and 12,835 for full, static, text-heavy and
editing, matching the baseline. In nine alternating control/current 500-cycle headless captures, median RSS window
growth was respectively [30.00, 3.75, 0.78, 4.84] and [30.16, 3.75, 0.78, 4.84] MiB. The original baseline medians
were [30.47, 4.06, 0.94, 4.69] MiB; all captures passed the memory gate. The 0.16 MiB first-window difference against
the paired control is retained here rather than treated as a demonstrated improvement.

The policy label and representation signature are both part of the generated function name and persisted registry key. Changing policy therefore creates a new identity instead of reusing an incompatible body.

Generated bodies are owned by the module declaring their generic origin. Incremental compilation regenerates them when a generic body changes and prunes them when that owner becomes unreachable or the specialization is no longer requested.

Constraints are semantic signatures. Changing a function or owner constraint invalidates dependent callers even when the runtime ABI shape is unchanged.
