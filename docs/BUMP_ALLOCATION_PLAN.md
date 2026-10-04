# Inline bump allocation plan

## Starting point

Allocation already bumps a pointer inside a thread-local run (TLAB). `docs/GC_ALLOCATION_PROFILE.md` shows 98.6% of
small allocations hit a ready run, and only about 30 per benchmark take the general path. These measurements and the
sample breakdown below predate allocation-volume-based empty-page retention. Reprofile the current runtime before
using them to predict savings. The remaining candidate cost is the work around the pointer bump. In binarytrees (68.3 M node allocations, 17.0 G instructions, about 250
instructions per node, against about 125 per node for Dart):

| Sampled category | binarytrees | merkletrees |
|---|---:|---:|
| Dispatch / common return | 13.5% | 15.1% |
| TLAB hit (slot lookup, cursor update) | 16.4% | 31.0% |
| Object metadata (`hl_alloc_obj`) | 9.5% | 4.6% |
| Zeroing | 1.8% | 4.1% |
| Mark | 10.9% | 5.0% |
| Sweep | 1.8% | 4.3% |

The historical allocation-side samples (the first four rows) total 41% of binarytrees and 55% of merkletrees. These
are sampled costs, not proof that removing a call recovers that share. The target JIT shape is a cursor load, bump,
limit check, cursor store, header store and initialization stores. Verify the comparison with Dart using current
disassembly and counters rather than assuming its allocation path or instruction count.

Past results: a thin allocation entry with bounded zeroing (kept, +9%), a thin object-allocation entry (−1.1%),
a JIT-prepared allocation helper (+2.3%, below the 5% gate), and direct JIT allocation (crashed on early method-table
initialization). The helper experiments still pay a call, the frame setup and the slot lookup; this plan removes those.

Generational collection is outside this change. Conservative roots constrain relocation without additional machinery.
A non-moving generational scheme needs remembered-set maintenance; its barrier cost and collection savings have not
been measured. The historical mark percentages do not prove it would lose. See "Deferred" below.

## Standing rules

- Expected values from stock Haxe/HL; use stock bytecode on our VM as a differential check.
- Keep the prototype opt-in until validation and acceptance. `HL_JIT_ALLOC_INLINE=0` restores the call path; read the
  switch once at JIT initialization. Give subsequent stages independent controls for A/B tests and bisection.
- Measure on core 0, nine alternating pairs, load <= 4 before and after, identical bytecode, plus `perf stat`
  instructions and cycles. Check disassembly with gdb.
- Gate: at least 5% on binarytrees or merkletrees, no regression beyond noise elsewhere, peak RSS growth <= 5%.
  If a stage fails its gate, record the numbers and revert.
- Separate commits with the `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` trailer. Never push the fork.
- x86-64 SysV only. AArch64, 32-bit, Windows and GC_DEBUG/memcheck builds keep the existing path.

## Stage 0: bound the prize before building

Completed: [Stage 0 measurements](BUMP_ALLOCATION_PROFILE.md) support a guarded Stage 1 prototype. No inline
allocation implementation has been accepted; the measured 5% gate still applies.

1. Freeze the current VM, library, native HDLL, bytecode and hashes with allocation-volume retention enabled on both
   sides. Record the retention cap and collection trigger. Measure fresh binarytrees/merkletrees medians and profile
   allocation, object setup, zeroing and collection again. Historical 0.797 s / 0.286 s values are context, not the gate.
2. Write an allocation-only microbenchmark in Haxe (allocate N 24-byte nodes and drop them; keep a 40-byte and a
   16-byte variant), with a matching Dart and C# version. Consume an observable checksum and inspect the generated
   code to ensure allocations survive optimization in every language. Report ns per allocation and distinguish
   construction, collection and process startup.
3. Count instructions per allocation on the current path with `perf stat`, and per allocation in Dart.
4. Estimate the best case by hand: write the intended inline sequence in assembly for the hit path and count its
   instructions, including TLS access, runtime eligibility and prototype-readiness guards, rounded size-class stride,
   the header and full initialization. Include register pressure and the slow-path spill cost. Do not assume a ten-
   instruction path before these costs are counted. Explain how the micro result bounds whole-tree savings; raw
   instruction savings alone do not establish a wall-time gain.

Gate: proceed only if the updated profile and micro measurements support a plausible saving of at least 8% of
binarytrees runtime. Record assumptions and uncertainty. If the evidence is insufficient or below the gate, stop.
Stage 1 still needs its own measured 5% acceptance gate.

## Stage 1: JIT inline fast path for fixed-size objects

For `ONew` of an object type (and the fixed-size array/struct variants only after objects work):

1. Per-thread access. Reuse the existing `hl_thread_info.gc_tlab` slots, indexed by size class and memory kind;
   avoid a second allocator state. The JIT does not already hold a thread-info pointer: threaded exception paths call
   `hl_get_thread()`. Specify a supported Linux x86-64 ELF TLS access through a runtime-provided descriptor, with
   ordinary-call fallback when unavailable. Do not bake the compiling thread's address into code. Compare this with
   reserving a register, accounting for spills and entry setup; include the selected cost in Stage 0.
2. Eligibility and initialization. Start with small HOBJ types without bindings. Resolve layout at JIT time with the
   existing layout machinery, but never eagerly build method tables then: function pointers may not yet be ready.
   Check runtime prototype readiness and use `hl_alloc_obj` until lazy initialization completes. Test inheritance and
   hot patching; metadata baked into code must obey module invalidation rules. Structs and binding-bearing objects
   keep the existing path in this stage.
3. One allocation operation. Introduce a dedicated internal JIT allocation instruction, with explicit input, output,
   scratch-register and slow-call clobber requirements. The x86-64 backend owns the fast/slow expansion. Do not compose
   generic branches that define the result in several places while `emit_store_reg`/`to->stored` assumes one definition.
   Specify the allocator integration before implementation: reserve stack homes for live pointer values and spill
   live caller-saved values on the slow edge, restore on every returning edge, and define the result once for downstream
   bookkeeping. Respect try handlers and exceptional exits. Existing save-around-call optimization is restricted
   and cannot be assumed to handle this expansion automatically.
4. Hit path. For sizes within the five fixed classes, load the slot cursor, compute `next = cur + block`, compare
   against its limit, and take the slow edge if the slot is empty or the block does not fit. `block` is the rounded
   allocator class size, not the requested object size; exact-boundary allocations are allowed. Commit the cursor,
   reproduce the existing `MEM_ZERO` behavior for the whole block, and store the correct type header. Clear primitive
   fields as well as pointer fields and padding. Stage 1 removes no initialization stores.
5. Slow path. Call the ordinary object initializer/allocator, preserving lazy prototype initialization, zeroing,
   accounting and exceptions. A shared stub is optional; first make correctness and result placement explicit.
   Allocation helpers remain returning calls. Pointer values must be in collector-scanned locations before the call.
6. Policy. Use one eligibility definition shared with the existing thin allocation entry. Compile out unsupported
   builds and disable for debug JIT mode and statically ineligible kinds. Census, tracking, profiling callbacks and
   GC flags can change after compilation: use a synchronized runtime guard with a defined publication protocol, or
   a proven code-invalidation mechanism, to send those modes through the ordinary allocator. The plan must cover
   enabling and disabling hooks in already JIT-compiled code; JIT-time checks alone are insufficient.
7. Accounting. Keep reservation accounting (`total_allocated`, `allocation_count`) per refill. Preserve the allocation-
   volume retention budget and collection-trigger behavior. Define how the inline path participates in a pending
   stop-the-world request and audit whether uninterrupted fast allocations can delay collection indefinitely.

Safety argument to document and test: a collecting thread waits for other registered threads to publish a blocking
or safepoint state. The allocating thread must not publish such a state between reserving its block and completing
full initialization. Verify this against the actual GC handshake, including slow-path entry, exceptions and pending
collection requests. Run ownership alone does not establish initialization safety. Stage 1 must not expose a partially
initialized object to another thread.

Tests:
- A native probe like `gc-allocation-paths` covering all five size classes, MEM_ZERO and non-zero paths, reuse of dirty
  blocks, pointer padding, a run that ends exactly at the object boundary, and refill from the cold stub.
- Fixtures with allocation inside loops, inside `try`, across calls, with many live integer, float and pointer values
  (stub spill correctness), first allocation before prototype initialization, inheritance and hot patching.
- Enable/disable census and allocation callbacks after the function is compiled; confirm hooks see subsequent
  allocations and that switching back restores correct fast-path behavior. Test a pending collection from another
  thread during sustained fast allocation. Tests must exercise emitted JIT allocation, not only the native allocator.
- GC stress with `HL_GC_MIN_TRIGGER=65536`, threads, finalizers, and the empty-page retention tests, each x20.
- Mutation checks: drop a field zero store, drop padding clearing, skip the end check, and use a wrong type pointer; each
  must make a test fail.
- Differential run of stock Haxe bytecode on our VM.

Gate: at least 5% on a tree benchmark against the fresh Stage 0 baseline. A 15–25% gain is an unverified hypothesis,
not an expectation established by the historical profile. If the gate fails, restore the code and report the result.

## Stage 2: remove redundant stores in the IR

Only if stage 1 passes. Ordinary `ONew` carries no initialization mask from Haxeon IR to the VM. Before adding IR
annotations, choose and document their transport: either a bytecode metadata/opcode extension with reader, writer,
validator, patching and debugger support, or a local JIT proof over existing bytecode. Do not silently reuse opcode
fields. Wasm keeps full initialization unless it independently consumes and validates the proof.

An initialization mask may omit a store only if every path writes that field before any operation that could observe
it: call, throw, allocation, safepoint, read, address-taking or publication into shared/reachable memory. Include default
primitive values, debugging behavior, exceptions and inter-thread visibility in the proof. Keep padding initialized
unless scanning safety is independently proven. Unknown effects invalidate the proof. Start with a straight-line,
unpublished allocation and abandon this stage if the representation or proof is disproportionate to the measured gain.

Test constructors that call out or throw before assignment, read a default primitive field, publish the object before
assignment, and join paths with different initialization coverage. Mutate each proof guard and require a failing test.

Gate: measurable on binarytrees (`left`/`right` are written by the constructor) at 2% or more, otherwise drop.

## Stage 3: arrays and boxed values

First count allocations by type and size on the current merkletrees workload; verify the suspected 16-byte boxes.
Extend only to representations with proven fixed size and initialization semantics. Define separate emit sites for
arrays and boxed nullable primitives; these do not all use `ONew`. Reuse the eligibility/slow-path mechanism and add
an independent stage control. Preserve array headers, element defaults and GC kinds. Gate: merkletrees improves a
further 3%, with the full validation and no-regression gates repeated.

## Deferred, with reasons

- **Moving or copying young generation.** Conservative roots need pinning or more precise root information before
  relocation can be safe. That is a separate collector project.
- **Non-moving generational collection.** Requires remembered-set/barrier machinery. Net cost is unmeasured; historical
  mark percentages alone are insufficient to reject it.
- **Smaller object headers.** Changes the object layout for every backend and the debugger.

## Done when

Each accepted stage clears its own gate against a frozen contemporary baseline, no benchmark regresses beyond
noise, and RSS grows by no more than 5%. Run fixtures and the driver with the stage on and off, Wasm backend/parity,
differential, self-hosting, repeated GC/thread stress, integration and debugger checks, and mutation tests. Report
startup/JIT latency and code size as well as runtime; preserve stable debugger locations. Record exact coverage,
skips, hashes and all six paired benchmark results in `docs/GC_ALLOCATION_PROFILE.md` or a linked follow-up report.
AArch64, Windows and other unsupported configurations retain their ordinary path and are explicitly listed as untested.
