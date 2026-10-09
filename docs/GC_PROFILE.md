# GC and allocation locality profile

Later measurements identify empty-page release/refaulting as a substantial tree-benchmark cost, superseding the
earlier cache-miss hypothesis. See [bounded empty-page retention](GC_EMPTY_PAGE_RETENTION.md) for the accepted
policy, timings and validation. The original experiments below remain historical evidence.

The Stage 4 gate is at least 5% on binarytrees or merkletrees, no regression beyond noise in the other benchmarks,
and no increase above 5% in peak RSS. Experiments use identical bytecode, core 0, and nine alternating pairs;
acceptance runs require one-minute load average <= 4 for every pair and discard pairs crossing that threshold. Diagnostic profiles below were collected on a busy machine
while the validation suites ran, so their elapsed times are exploratory, not an acceptance baseline.

## Baseline profile

Commands, from the repository root with `LD_LIBRARY_PATH=$PWD/out:$PWD/.tools/hashlink`:

```sh
perf stat -e instructions,cycles,cache-references,cache-misses,LLC-loads,LLC-load-misses \
  taskset -c 0 .tools/hashlink/hl out/optimization-next/binarytrees/app.hl 18
perf record -F 499 -g --call-graph dwarf -o out/optimization-next/binarytrees.perf.data \
  taskset -c 0 .tools/hashlink/hl out/optimization-next/binarytrees/app.hl 18
perf report --stdio --no-children -i out/optimization-next/binarytrees.perf.data
```

Repeat for merkletrees, input 16. Use the `cpu_core` counters on this hybrid machine: events sampled before taskset
sets affinity can appear under `cpu_atom` and are not the benchmark. Kernel symbols are restricted; JIT code is
partly unnamed. The allocation entry includes inlined TLAB refill/free-list work, so sampling is not a precise
allocation-versus-lazy-sweep accounting. `HL_GC_PROFILE` is deliberately not used for timings because it disables
TLABs and adds per-allocation timing overhead.

| Metric | binarytrees (18) | merkletrees (16) |
|---|---:|---:|
| Core instructions | 19,010,176,084 | 7,067,384,106 |
| Core cycles | 7,130,979,288 | 3,109,326,380 |
| Cache references | 50,271,585 | 24,617,585 |
| Cache misses | 40,155,603 | 18,832,296 |
| LLC loads | 1,735,476 | 911,930 |
| LLC load misses | 1,089,949 | 499,874 |
| Exploratory elapsed seconds | 1.409 | 0.613 |
| `hl_gc_alloc_gen_owner`, exclusive sampled cycles | 18.29% | 25.90% |
| `hl_alloc_obj`, exclusive sampled cycles | 8.15% | 3.51% |
| `gc_flush_mark`, exclusive sampled cycles | 10.64% | 4.47% |
| libc memset, exclusive sampled cycles | 5.24% | 8.09% |

The first sampled profile contains 669 core-cycle samples for binarytrees and 331 for merkletrees. Cache miss ratios support
investigating locality, but do not prove that marking is the dominant bottleneck. Allocation and initialization
are larger named costs. Empty-page sweeping is below the reporting threshold as a separate symbol; some free-list
rebuilding is charged to allocation because it happens lazily.

## Allocation, marking and sweep split

A second profile rebuilds only the GC translation unit with the same release flags plus `-g`, then links a separate
library under `out/optimization-next/gc-profile-symbols`. The main VM/library are untouched and all experiment
switches are zero. TLABs remain enabled. `perf record -F 999 -g --call-graph dwarf` plus `perf script --inline`
recovers inline frames such as `gc_flush_empty_pages`, previously charged to its enclosing native symbol.
The separate library preserves both benchmarks' output exactly.

Core-cycle sample periods are assigned to mutually exclusive phases: a sweep/free-list/finalizer frame first,
otherwise a mark/dispatch/setup frame, otherwise an allocation frame. Thus a collection nested inside allocation
is charged to collection, rather than counted twice. Allocation includes initialization and system work while
an allocator frame is active. Other includes JIT execution and unresolved frames. These inclusive phase shares
are different from the exclusive leaf-symbol percentages above.

| Sampled phase | binarytrees (18) | merkletrees (16) |
|---|---:|---:|
| Allocation and initialization | 59.40% (786 samples) | 74.78% (418 samples) |
| Marking and setup | 12.03% (164) | 5.56% (31) |
| Sweep, free-list rebuilding and finalizers | 4.35% (59) | 1.08% (6) |
| Other / unresolved | 24.22% (325) | 18.58% (114) |
| Total core samples | 1,334 | 569 |

The six merkletrees sweep samples are too few for a precise estimate. Empty-page sweep alone is a subset of this
already small phase, so a bitmap comparison is unlikely to meet the 5% gate by itself. Mark prefetch has a limited
ceiling, especially on merkletrees. Allocation locality is the larger target; none of these phase shares substitutes
for paired timings. Reproduction scripts, stack dumps, reports and `phases.json` are in the scratch directory.

## Candidates and rejected experiments

- **Pointer-free scan skip is already implemented.** `GC_PUSH_GEN` checks `MEM_HAS_PTR(page->page_kind)` before
  enqueuing an object. `hl_alloc_obj` chooses `MEM_KIND_NOPTR` when `rt->hasPtr` is false. This optimization needs no
  new switch or duplicate scan.
- **Contiguous, ascending TLAB runs already exist.** `gc_alloc_fixed_run` takes consecutive blocks from an
  address-ascending free-list run, and `gc_tlab_alloc` advances by the size-class block size. The new experiment
  sorts page lists by their base address at a stop-the-world collection, before publishing free-page cursors.
- **Next pending object prefetch (`HL_GC_MARK_PREFETCH=1`).** Existing marking already prefetches newly discovered
  children. The experiment additionally prefetches the next non-sentinel entry while scanning the current object.
- **Page ordering (`HL_GC_ADDRESS_ORDER=1`).** Sort each size/kind page list at collection time; leave object layouts,
  free-list positions, sizes, allocation accounting and mark bits unchanged. Allocation failure of the temporary
  sort buffer falls back to the existing order.
- **Empty bitmap comparison (`HL_GC_FAST_EMPTY=1`).** Compare an entire page bitmap with a static zero bitmap in one
  libc operation instead of repeated 256-byte comparisons. Finalizers still run before freeing pages.

The tested switches were independent, disabled by default and accepted exactly `1`. They were runtime choices,
so compiler fingerprints did not change. All three experiments failed the performance gate and were removed;
none of these switches exists in the resulting VM. Pointer-free scanning and contiguous TLAB runs remain unchanged.

The 32-bit free-list cursor fix's static size assertion and refill/overrun fatal checks remain active during all
experiments. The three GC fixtures passed x20 with all switches enabled, both at the default collection threshold
and with `HL_GC_MIN_TRIGGER=65536`; this includes the five-thread allocation and retained-chain stress test. Each
switch also passed the same 120 runs independently (other switches zero), for 480 successful stress executions
in total. These independent checks use the frozen measurement runtime, so combined options cannot mask a failure.

## Acceptance measurements

Core 0, nine alternating pairs per switch and benchmark, identical bytecode and frozen VM/runtime libraries.
Other experimental switches were zero. Every pair's recorded one-minute load stayed at or below 4; pairs
crossing that threshold were discarded. Positive improvement means faster; RSS compares median peak observations.

| Switch | Benchmark | Off (s) | On (s) | Improvement | Peak RSS change |
|---|---|---:|---:|---:|---:|
| `HL_GC_MARK_PREFETCH` | binarytrees | 1.1901 | 1.1921 | -0.17% | -0.00% |
| `HL_GC_MARK_PREFETCH` | merkletrees | 0.4874 | 0.4862 | +0.24% | -0.00% |
| `HL_GC_ADDRESS_ORDER` | binarytrees | 1.2013 | 1.1989 | +0.20% | +0.01% |
| `HL_GC_ADDRESS_ORDER` | merkletrees | 0.4909 | 0.4907 | +0.04% | -0.17% |
| `HL_GC_FAST_EMPTY` | binarytrees | 1.2024 | 1.2040 | -0.13% | +0.00% |
| `HL_GC_FAST_EMPTY` | merkletrees | 0.4909 | 0.4924 | -0.29% | +0.00% |

None approached the required 5% gain. RSS stayed well inside the 5% limit, but that does not satisfy the speed
gate. All three changes were reverted and no fork commit or submodule bump was made for them. Other-benchmark
regression runs were not needed because no tree result passed the first gate. The existing allocator's contiguous
runs and pointer-free scan skip were retained rather than duplicated.

`perf stat -e instructions,cycles` also completed for each switch, each tree and both modes, with other switches
zero. Counter logs are named `gc-perf-<switch>-<benchmark>-<mode>.log`. They are supporting diagnostics, not a
replacement for the paired timing gate. Raw counters, profiles, timings, rejected patch and test logs remain under
`out/optimization-next/`; `gc-measure.json` includes every pair's loads and build hashes. The benchmark README
retains its accepted numbers.

The subsequent fixed-size allocation follow-up is recorded in
[GC_ALLOCATION_PROFILE.md](GC_ALLOCATION_PROFILE.md). It profiles allocation dispatch and zeroing separately;
its accepted change does not revive the rejected mark/sweep experiments above.

## Compiler follow-up

[Compiler GC marking and refill experiments](COMPILER_GC_MARKING.md) profile the compiler workload separately.
The opt-in one-worker bitmap candidate passed correctness validation; quiet performance acceptance is pending.
It does not revive the rejected tree prefetch/page-order/empty-comparison experiments.

## Experimental incremental marking (Linux)

`HL_GC_INCREMENTAL=1` enables an opt-in collector that preserves its mark queue between stop-the-world
slices. Automatic allocation slow paths request 1 ms slices, spaced by at least 256 KiB of allocation.
The desktop `FrameGcScheduler` also advances marking at frame boundaries once allocation pressure reaches
half the actual collection trigger. It uses `Gc.triggerBytes()`, including `HL_GC_MIN_TRIGGER`, rather
than just a fraction of mapped capacity. Idle points still finish a full collection.

The native/Haxe APIs are `Gc.incrementalSupported()`, `Gc.incrementalPending()` and
`Gc.step(budgetMicros)`. A step returns true when a collection completes, including synchronous fallback.
Budgets in `(0, 100000]` microseconds are accepted; other values are no-ops returning false. Explicit
steps work with automatic GC disabled. `Gc.major()`, heap dumps and live-object queries cancel any pending
incremental cycle and rebuild a complete mark. Existing collection counters count completed cycles;
last/max pause counters include individual incremental slices and cumulative mark time includes all slices.

The collector uses [Linux soft-dirty PTEs](https://docs.kernel.org/admin-guide/mm/soft-dirty.html) to detect
heap writes from both JIT and native code. It probes kernel support and proc permissions, and falls back
to full collection if tracking is unavailable or fails. It rereads roots and queues marked objects on
dirty heap pages before each marking slice. Interior references are accepted for roots; heap fields
follow HashLink's exact-pointer convention. Object payloads are scanned conservatively: pointer-shaped
scalar values can retain extra objects compared with the ordinary collector's typed marking.
New allocations are retained for the current cycle. Partial
marks never feed allocator free lists. TLABs and generated allocation fast paths are guarded off while a
cycle is pending; the previous collection's lazy free-list sweep finishes before its bitmap is replaced.

New mappings in incremental mode have inaccessible alignment/guard space, preventing adjacent mmap
operations from merging with the old heap and making unchanged pages appear soft-dirty. This adds up to
128 KiB of reserved virtual address space per mapping, without committing that space as heap memory,
and increases VMA count. Dirty tracking clears soft-dirty bits for the whole process, adding write-fault
and page-table overhead beyond the GC heap. Other tools must not independently reset soft-dirty tracking
while an incremental cycle is active. Native threads must obey the existing registration, safepoint and
blocking rules; unmanaged concurrent writes, DMA and writable shared aliases are unsupported.

This is incremental **marking**, with the existing lazy free-list sweep. Root capture, dirty-page discovery,
cycle preparation, finalizers and empty-page release remain synchronous; the budget is a target, not a
hard realtime deadline. A repeatedly mutated large object can also delay progress. Allocating more than
four times the trigger captured at cycle start forces a full collection, even if a growing heap would
otherwise keep raising the trigger. Explicit idle/emergency collections can therefore still cause stalls.
The default collector is unchanged unless the environment option or step API is used.

Run correctness and synthetic latency checks after building the native runtime:

```sh
bash tests/integration/test-gc-incremental.sh
bash tests/bench/incremental-gc/run.sh
HL_GC_INCREMENTAL=1 <application-command>
```

The correctness guard covers native reference mutation, interior roots, allocation during marking,
explicit cancellation, exactly-once finalizers, forced loss of either proc descriptor and allocation
pressure fallback, with one and four mark workers. It also runs the real frame scheduler against the
native API. The `gc-incremental` program exercises Haxeon-generated allocation and reference stores.

An exploratory latency run over a stable 500,000-node graph, 15 collections and 64 KiB of transient
allocation per simulated frame measured full-collection maxima around 4–6 ms and incremental maxima
around 1.1 ms with a 1 ms target and one mark worker. Total GC time increased roughly 2 times. These are synthetic,
non-isolated observations, not application frame-rate or performance acceptance results. The benchmark
prints sample counts, median, p99, maximum and aggregate GC time so the latency/throughput tradeoff is
visible. Actual UI frame percentiles and mutation-heavy workloads still need application measurements.

### Portable write-barrier investigation

The next useful prototype is a **post-write destination-page barrier**, reusing the current incremental
mark queue and dirty-object rescanning. Proposed private/native interfaces are
`hl_gc_write_barrier(void *slot)` and `hl_gc_write_barrier_range(void *destination, size_t bytes)`.
These interfaces are a design proposal, not implemented APIs.

After a reference-bearing store or bulk copy, the barrier flags every affected GC heap page as dirty.
It accepts interior destination addresses, ignores non-heap addresses, performs no allocation, takes
no GC lock and introduces no safepoint between the store and recording it. Mutators only publish dirty
metadata; they do not change mark bits or append to the collector's mark queue. Dirty flags require
portable atomic publication for shared pages. The collector consumes them only after all registered
mutators have stopped, rescans marked objects on those pages, and rereads roots before finishing.
Use the existing 64 KiB-or-larger allocator pages initially; finer cards can follow measurements.

A runtime active flag should guard generated barrier calls, including code compiled before marking
starts. Initially prefer a simple native helper call on the active path over duplicating the collector's
platform-dependent address hashing in each machine-code backend. Numeric stores can bypass the barrier
only when their destination layout is proven pointer-free. Packed values require a range barrier when
their embedded layout contains references. New black allocations still need barriers on initialization:
a later allocation can trigger a slice before construction has finished. Elision needs proof that no
safepoint intervenes before initialization/publication completes.

The initial source audit identified these coverage groups:

| Area | Concrete paths | Required handling |
|---|---|---|
| Shared current JIT lowering | `jit_emit.c`: `OSetField`, `OSetThis`, `OSetArray`, `OSetref`, `OSetEnumField` | Barrier the actual destination slot, including virtual-field aliases, array backing storage and packed copies. |
| Dynamic-field helpers | `std/obj.c`: `hl_dyn_setp`, `hl_obj_lookup_set`, `hl_obj_set_field`; `std/cast.c`: `hl_write_dyn` | Cover direct stores, conversion paths, backing-buffer replacement and virtual/dynamic-object structural changes. |
| Arrays and bulk copies | `std/array.c`: `hl_array_reserve`, `hl_array_blit`, `hl_carray_blit`; `native/runtime/arrays.c` | Cover copied destination ranges and the old array header's reference to replacement storage. |
| Maps and closures | `std/maps.h` template and `std/fun.c` | Cover reference keys/values, resized buffers, captured values and initialization across allocations. |
| Legacy ARM JIT and generated C | `jit_arm64.c`, `hlc.h` | Audit separately; shared current JIT instrumentation does not cover these paths. |
| Unsafe/native interfaces | `OSetMem`, `ORefData`, raw pointer writes, FFI callbacks and external HDLLs | Define an explicit reference-store/bulk-write contract; compiler instrumentation alone cannot cover arbitrary native writes. |
| Roots | Globals, registered roots, stack references | Current root rescanning handles these; distinguish root storage from heap storage when references can alias either. |

This is a starting inventory, not a certification that all heap writes have been enumerated. In particular,
barriering a virtual wrapper alone misses writes through its field addresses into a separate object.
Likewise, barriering an array header alone misses element writes into its separate backing allocation.
Writes into native buffers containing managed pointers need both the existing rooting/lifetime contract
and a barrier if those buffers are GC-scanned managed storage.

Roll out in three stages: implement and stress-test dirty-page recording while retaining Linux soft-dirty
as a safety net; instrument the shared JIT and native coverage groups with tests for each store family;
then enable software-only collection for explicitly audited runtime/FFI configurations. Unknown native
modules must retain OS tracking or force full collection rather than silently permitting software-only
incremental marking. Soft-dirty validation must account for kernel false positives: a dirty OS page is
not by itself proof that a reference barrier was missed. Add a stop-the-world tracing oracle to check
that barrier-only results never omit objects reachable at final remark, and deliberately remove barriers
to confirm the mutation tests catch the omission.

Measure default-mode store overhead as well as active-mode frame percentiles, total GC work and memory.
The first acceptance gate is complete write coverage and correctness, followed by eliminating proc
tracking/whole-process write faults on certified workloads. Portability still requires validating atomics,
JIT calls, roots and suspension on each target; barriers do not bound root capture or finalizers.

This destination-rescan design keeps the collector's current stop-the-world slices. An insertion barrier
that directly marks the new referent is another option, but would require new mutator-safe marking queues
and publication rules. V8's [incremental/concurrent marking discussion](https://v8.dev/blog/concurrent-marking)
explains why heap mutations need a barrier and why the algorithm changes when marking itself runs
concurrently with application threads.

### Implemented mutation/tracking foundations

The incremental marker now obtains write discovery through `gc_write_tracking.c`'s private backend
interface: capability probing, begin, dirty-page visitation, rearm, end, disable and shutdown. The backend
reports pages without inspecting mark bits; the marker decides which objects need rescanning. Linux
soft-dirty remains the active backend, and unavailable backends retain synchronous fallback. Full
collection cancels tracking after stopping mutators. Shutdown requires the existing quiescent-runtime
contract. The scheduler still chooses when to request collection independently of this interface.

`gc_write.h`, included by `hl.h` and distributed with it, provides typed native mutation boundaries for
reference stores, value-range copy/move/clear/swap and packed payload copies. They perform
writes followed by guarded software dirty-page recording, without allocation, locks or retain/release operations. Each interface preserves
the destination and layout so a future implementation can inspect old and incoming references before
overwriting. Value slots and inline packed objects are distinguished. Overlapping move operations copy
rather than consume the source; reference counting will need to retain incoming references before
releasing overwritten ones. Swaps are represented as one operation rather than unrelated byte stores.
These helpers do not yet establish ownership of locals, returns, foreign pointers or backing allocations.

The shared current JIT lowering routes field, this-field, global, enum, array and reference stores through
typed emit helpers. Pointer stores and packed copies now emit a guarded barrier call. Their destinations
can be heap slots, globals or referenced stack slots; the hook classifies the address. Automatic register
spills remain separate. The legacy ARM emitter and generated C remain separate migration work.

The first native migration covers HashLink array allocation/growth/blits, Haxeon's typed and dynamic
array mutations, backing-storage replacement, copying, shifting, clearing and reversing, plus the typed
pointer-store case of `hl_write_dyn` used by array conversions. Pointer-free string-byte operations keep
ordinary byte copies. The subsequent dynamic-object, map and closure migration is described below;
remaining foreign/native write paths still need auditing before software-only tracing can be considered safe.

The native incremental guard now keeps targets alive solely through an array while its backing storage
grows and overlapping copies, swaps and clears execute between slices. Default and incremental program
runs each passed all 355 fixtures; the small-trigger array/GC run passed 56 fixtures. Existing native
allocation, finalizer, tracking-failure, cancellation and JIT guards also passed. These checks validate
behavior preservation; they do not certify software barrier coverage or reference-counted ownership.

### Software dirty-page recording alongside Linux tracking

Incremental cycles now enable software recording in the typed native helpers and shared JIT. The hook
atomically marks destination allocator pages, including every page covered by a bulk write. It ignores
non-heap destinations and pointer-free pages. Page-map publication uses release stores and the hook
uses acquire reads; page reclamation remains suspended with the world. The collector consumes dirty
flags while stopped and rescans those pages together with Linux soft-dirty results. Hooks do not allocate,
lock, scan objects or introduce safepoints. Inactive native writes and generated stores guard the call.
Linux capability probing and failure fallback remain mandatory; this does not enable other platforms.

The integration test masks kernel dirty bits after probing and validates array mutation survival with
one and four marking workers. A negative control also drops software barriers and must fail the survival
check. A shared-JIT probe exercises field, global and array writes while kernel bits are masked. All 355
existing program bytecode fixtures passed with incremental mode off and on at a 64 KiB trigger. This
validates the migrated paths, not complete runtime/FFI coverage. The native migration described below
extends coverage; remaining native paths, legacy emitters and generated C still need auditing.

### Native dynamic objects, maps and closures

The native migration now also records dynamic-field pointer assignment, pointer-storage growth and
compaction, deletion, object copies, virtual materialization, virtual-address remapping and cached views.
Inline virtual copies and clears preserve each field's actual type. Scalar-only payload buffers and
runtime type/method metadata remain outside the managed-reference mutation paths.

Map recording covers managed keys and values, header/backing-buffer replacement, resizing, copying,
clearing, removal and exported key/value arrays. Integer keys remain scalar; the private lookup map's
non-owning keys remain in pointer-free storage. Heterogeneous map buffer copies retain their existing
byte operations and explicitly record the destination range rather than inventing a value layout.
Captured closures, wrapper captures, pointer-valued dynamic return boxes and dynamic pointer boxing also
record their writes. Varargs captures use a dynamic layout when there is no declared first argument.

The native survival guard now checks 24 finalizable targets, including targets retained through copied
dynamic objects, inline/materialized virtuals, integer maps and captured closures. Tests pass with kernel
dirty bits masked for one and four workers, and the missing-barrier negative control still fails as
expected. The shared-JIT probe additionally exercises reflective field type changes, virtual views,
string/object maps, map copying/clearing and dynamic closure calls. All 355 existing program bytecode
fixtures pass with incremental mode off and on at the small trigger.

This broadens coverage; it does not certify every native mutation. Native/FFI extensions, additional
runtime constructors, legacy emitters and generated C still need auditing. A separate full-tracing
validation pass at final remark remains the next correctness gate before software-only mode is exposed.
Linux tracking remains required as the safety net.

### Final-remark tracing validator

Set `HL_GC_INCREMENTAL_VALIDATE=1` to independently trace the reachable heap whenever an incremental
cycle reaches final remark. The validator runs with mutators stopped, before marks are published or
anything is swept. It starts from registered roots, captured stacks/registers and extra stack data,
using fresh per-page bitmaps and its own worklist. It does not seed its traversal from incremental marks,
black allocations, software dirty flags or Linux dirty results. It compares every independently reached
object with the incremental mark bitmap; extra incremental marks are allowed.

The oracle follows the incremental collector's conservative pointer model: exact object references in
heap payloads and interior pointers in roots. It deliberately does not use the ordinary collector's typed
field filtering, which could otherwise hide omissions relative to incremental scanning. It shares allocator
address/block classification and the runtime root/suspension contract, so it is a barrier/mark-completeness
check rather than independent proof of those foundations.

On a mismatch it prints the number of missing objects and the first missing address, then terminates
before reclamation. It does not repair the marks or silently continue. The mode is off by default and
adds a full synchronous trace, temporary bitmaps and a worklist at completion; it is intended for debugging
and coverage validation, not frame-latency measurements. Tracking failures and emergency full collections
still use their existing fallback rather than running an incremental final-remark check.

The integration guard enables validation with kernel dirty bits masked. Its negative control disables
software barriers as well and requires the validator's diagnostic before the survival checks can run.
The normal masked-kernel mutation and shared-JIT probes pass. All 355 existing program bytecode fixtures
also pass with incremental collection and validation enabled at the small trigger. Linux tracking remains
required; this option does not enable software-only collection or certify unknown FFI writers.

### Test-only software tracking backend

On the currently validated Linux allocator/JIT configuration, select the experimental backend with:

```sh
HL_GC_INCREMENTAL=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 .tools/hashlink/hl program.hl
```

`HL_GC_INCREMENTAL_TEST_SOFTWARE=1` is an internal coverage-testing switch, not a production support
promise. It selects software page flags instead of Linux discovery before the heap is initialized. This
mode does not open/read pagemap, write clear_refs, probe soft-dirty support or reserve the guard mappings
needed to avoid Linux VMA dirty-bit false positives. Begin/end still enable/disable native and shared-JIT
barriers; collecting atomically consumes per-page flags while mutators are stopped. Rearm has no kernel
work. Allocation-pressure fallback, explicit full collection and cancellation retain existing behavior.

Startup rejects this mode unless `HL_GC_INCREMENTAL_VALIDATE=1` is also set. Once selected, every
incremental final remark requires the independent tracing validator even if the environment variable is
later removed. The full validation pause therefore remains part of these runs; their frame percentiles
must not be presented as production software-barrier latency. Without the test switch the existing Linux
backend and its capability/failure checks remain selected. Other platforms are not enabled by this change.

The integration suite checks one/four marking workers, mutation survival/finalizers, allocation-pressure
fallback, the shared-JIT/runtime mutation probe and the frame scheduler. A test interposer fails any
attempt to open either proc tracker. Separate checks reject disabled validation at startup and deliberately
remove barriers to require a final-remark diagnostic before sweeping. Another run denies proc permissions
to the normal backend and verifies that the software tests still run when Linux tracking is unavailable.
All 355 existing program bytecode fixtures passed both normal Linux tracking and software-only tracking,
with validation enabled and a 64 KiB trigger; the software run forbade proc tracking opens.

Remaining work is to expand native/FFI write coverage and stress validation across more workloads, then
validate atomics, shared-JIT calls, stack capture and suspension on another platform. This mode does not
make arbitrary native modules safe or remove the validator from the software-only path.

### Haxeon native/runtime write audit

The runtime audit adds destination recording for iterator array captures, StringBuf backing replacement,
String wrapping, split/string-array construction, directory/environment/argument string arrays, managed
Bytes view owners and structure root arrays, callback captures and pointer/aggregate dynamic boxes. The
String wrapping boundary explicitly records the object initialized by `hl_alloc_string`; character data
itself remains pointer-free. Existing explicit roots for Bytes views, structure roots and callbacks remain
in place. Clearing references during finalization does not introduce a reachable object and needs no
insertion recording.

| Runtime area | Managed-reference handling |
| --- | --- |
| Arrays and maps | Existing typed array helpers and migrated HashLink map helpers |
| Reflection | Existing migrated dynamic setters and object-copy paths |
| Strings, iterators, files and system | Native stores/initialization now record destinations |
| Bytes views and HXI root storage | Typed owner/root stores plus existing registered roots |
| FFI callbacks and result boxes | Typed capture/box stores; aggregate byte payloads stay pointer-free |
| Processes, native allocation and byte I/O | OS resources, malloc/realloc buffers and scalar payloads; no managed writes to instrument |
| Regex, Int64 and module wrappers | Delegated matching, scalar operations or stack out-parameters; no retained managed-reference assignments in these wrappers |

Foreign pointers, library controls, ffi descriptors and owned UTF-8 buffers use native allocation and are
not managed-reference slots. Writing a raw pointer into foreign Bytes storage does not make it a GC root:
HXI managed ownership still requires its companion managed root array. Arbitrary foreign code writing
into managed heap storage must use the barrier helpers or retain production Linux tracking; this audit
does not certify external modules, asynchronous foreign writers or other platform suspension/JIT paths.

A dedicated native guard makes a previously unreachable array reachable solely through a newly created
runtime iterator between slices. It checks survival and exactly-once finalization with one/four workers;
dropping barriers must make the final-remark validator fail. A separate VM probe exercises native StringBuf,
String wrapping/splitting, environment and argument construction between slices. Both run with software-only
tracking, mandatory validation and forbidden proc tracking. All 355 existing program bytecode fixtures
pass with normal and software-only tracking plus validation at the small trigger. The ordinary C native-call
bridge test also passes in software-only mode. Linux-specific tests do not validate the Windows branches.

### Software-only FFI boundary stress

`tests/integration/test-gc-ffi-stress.sh` is now part of the incremental integration guard. It runs only
on the currently validated Linux configuration, with mandatory final-remark validation and a proc-open
interposer that rejects kernel tracking. One and four marking workers each run three fresh-process
rounds of the FFI/borrowed-storage cases. Fresh processes preserve the existing fixture's exactly-once
native-release assertions rather than resetting or weakening those assertions.

The HXI call generator has an opt-in `HAXEON_GC_BOUNDARY_STRESS=1` mode. A large pointer-bearing ballast
keeps a cycle pending across the existing scalar, pointer, aggregate, UTF-8, retained callback and callback
error-contract tests. Binary callbacks assert that a cycle is pending and request a tiny GC slice from
inside the callback. The test finishes marking, then invokes a captured callback and rechecks structured
values after validation. The retained-structure generator's matching mode constructs nested borrowed
item/path/byte arrays during a pending cycle, performs allocation churn, finishes marking and asks the C
fixture to verify the retained container and extracted view. Default generator behavior is unchanged.

The native boundary guard mutates a managed root-array slot after initial marking, retaining either a
finalizable value or a bound closure that captures that value. Its Bytes view must retain the owning
buffer, and dropping all holders must eventually finalize the target exactly once. The negative-control
interposer suppresses only the selected slot's barrier, leaving other writes instrumented: the validator
must report one missing object for the direct value, or two for the closure/captured value, before sweeping.
Explicitly rooted callback captures need not fail when their redundant insertion barrier is removed, so
the negative controls target a mutation where the barrier is required.

The module probe runs twelve generations per worker setting. Load and disposal are entered with a cycle
pending; a retained captured closure must remain callable after tracing and after module disposal. Releasing
the capture, unwinding its frame, collecting and retrying retirement must leave no outstanding generations.
Existing lifecycle operations may synchronously collect/cancel a cycle as part of safe disposal; the probe
preserves that behavior. The complete incremental integration suite, including these stress cases and
both targeted negative controls, passes. These tests extend coverage without certifying unknown FFI writers
or providing a realtime latency bound.

### Experimental Apple AArch64 backend preparation

The software tracking implementation is shared with a build-gated Apple AArch64 backend.
Normal Apple builds still report incremental GC unavailable. To build the experimental backend
on Apple Silicon, use:

```sh
cmake --preset release -DHL_JIT_AARCH64_OLD=OFF -DHAXEON_GC_APPLE_SOFTWARE_TEST=ON
cmake --build --preset release --target libhl hl haxeon_runtime
bash tests/integration/test-gc-apple-software.sh
```

The build rejects other targets and the legacy AArch64 JIT, which lacks the shared JIT's
software barriers. Runtime activation additionally requires `HL_GC_INCREMENTAL_TEST_SOFTWARE=1`
and `HL_GC_INCREMENTAL_VALIDATE=1`; validation remains mandatory for that process even if the
environment changes. Apple tracking has no Linux soft-dirty safety net. It uses the same dirty
page flags and stop-the-world collection protocol as Linux's software-only test mode.

The manual `experimental-apple-software-gc` workflow builds on an Apple Silicon runner and
runs native survival/pressure guards, the validator requirement check, JIT/runtime mutation
probes, HXI callback/borrowed-storage stress and module retirement checks with one/four workers.
The HXI test generators accept an explicit target ABI for this runner. Linux's targeted
missing-barrier interposers are not ported by this change.

The Linux build and complete incremental integration suite pass after sharing the backend.
A host-side backend contract probe also compiles the Apple selection branch and checks
cross-page writes, dirty-flag consumption and backend lifecycle; the Linux suite runs it.
These checks do not validate Apple's ABI, stack capture, suspension or shared AArch64 JIT.
No macOS runtime execution has been performed in this Linux workspace, and the manual
workflow has not been dispatched. Apple support remains experimental and gated pending
successful runner validation; this is not a realtime latency guarantee.

### Frame-work latency benchmark and phase diagnostics

Run `bash tests/bench/incremental-gc/run.sh [output-directory]`. It writes raw per-frame
CSV samples, environment information, phase logs and a summary; the default destination is
`out/bench/gc-latency`. `GC_BENCH_FRAMES` (default 1200) and `GC_BENCH_NODES` (default 500000)
control duration and live graph size. It alternates full/incremental/incremental/full runs
with one and four marking workers, requesting a 1000 microsecond slice. Automatic collection
is disabled to isolate explicit collection and allocation-path work.

Each simulated frame allocates 256 pointer-bearing 128-byte objects and 16 finalizable
128-byte objects, mutates three old-object reference slots through the write helpers, and
requests collection every 30 frames or continues a pending incremental cycle. Samples include
allocation time (including lazy sweeping), GC call time and their combined frame work. They
exclude CSV output and do not include rendering, sleeping, event processing or a UI application's
other work. The live graph is a linked list: four marking workers do not imply four-way useful
parallelism for this topology. Finalizers are deliberately trivial, so their timings do not
predict expensive application finalizers.

`HL_GC_LATENCY_TRACE=1` enables incremental phase diagnostics on stderr. `GC-LATENCY` records
suspension, bitmap preparation, dirty-page scanning, root capture, mark draining, validation,
completion, finalizers, rearming and resume times. `finish_ms` includes `finalizers_ms`; do not
sum both. Preparation and final completion remain synchronous. Diagnostic output occurs after
resuming mutators but while the collector lock is held, so it can delay callers. The benchmark
therefore uses separate diagnostic runs; comparative timed runs disable logging and validation.
The clocks for these phases use the runtime's existing clock, and individual tiny phase samples
may be below its effective resolution. Full/fallback collections have no per-phase records.

Local Linux results from this change (two timed runs per mode/worker setting):

| Live objects | Mark workers | Full frame p99 / max (ms) | Incremental frame p99 / max (ms) | Completed cycles, full / incremental |
| --- | --- | --- | --- | --- |
| 500,000 | 1 | 3.542 / 6.326 | 1.101 / 1.131 | 80 / 80 |
| 500,000 | 4 | 5.343 / 5.827 | 1.111 / 1.143 | 80 / 80 |
| 2,000,000 | 1 | 15.633 / 24.096 | 1.783 / 4.117 | 40 / 18 |
| 2,000,000 | 4 | 16.660 / 22.765 | 1.713 / 3.599 | 40 / 19 |

The large run used 600 frames per process. Pending cycles can cross a scheduled collection
boundary and remain unfinished at the end of a process, so larger-heap comparisons are not
matched-throughput results. No incremental frame work exceeded 16.67 ms in these runs; this
leaves no guarantee for a real application's total frame time. The large diagnostic run found
bitmap preparation as high as 3.836 ms and a 4.073 ms slice despite its 1 ms budget. Dirty-page
scanning reached 0.916 ms and rearming 0.265 ms in separate slices. These observations prioritize
budgeting bitmap preparation, followed by dirty discovery/rearming, before optimizing the cheap
finalizers in this workload. Raw data remains in `out/bench/gc-latency` and
`out/bench/gc-latency-large`; these generated artifacts are not source files.

The rebuilt runtime passes the complete incremental integration suite. A separate software-only
benchmark run with mandatory validation and phase logging also passes; comparative timings above
exclude that validator overhead.

### Resumable bitmap preparation

Bitmap preparation now has its own resumable phase. A cycle increments a per-page epoch and
walks allocator page lists across slices, checking the deadline after each page. Each page
finishes its previous lazy sweep before replacing its bitmap. The cursor does not snapshot
all page addresses: active cycles do not reclaim pages, and new pages are inserted as already
prepared list heads. This avoids an additional unbounded preparation-list construction pass.

Allocations into an older page prepare that page on demand under the allocator lock and mark
the new object black. New pages are born in the current epoch. The collector's active flag
continues to disable allocation fast paths throughout preparation. The background page cursor
skips pages already prepared by allocation, preserving their new black objects. This can move
one page's preparation cost into an allocation call; allocation timings remain part of the
frame benchmark. One page's lazy sweep/bitmap allocation remains indivisible.

Write tracking begins before preparation yields and retains dirty state across all preparation
slices. Neither roots nor dirty-page marks are scanned until every page is ready. Preparation
and tracing occupy separate slices even at the transition, avoiding a dirty-page scan stacked
onto the final preparation slice. The first tracing slice consumes the accumulated writes,
including references installed in black allocations during preparation. No partial bitmap is
published for sweeping. Full collection, allocation pressure and shutdown can cancel preparation
through the ordinary discard/fallback path. The native diagnostic
`hl_gc_incremental_preparing()` distinguishes this phase from the rest of a pending cycle;
it is not a Haxe primitive. `GC-LATENCY` now includes `preparing=1` for preparation-only slices.

The complete incremental integration suite passes with both hybrid Linux and mandatory-validated
software-only tracking. Tests cover mutation/allocation during preparation, previous-cycle lazy
sweeps, cancellation during preparation and marking, pressure fallback and exact-once finalization.
The FFI root-array fixture now runs mutations both during preparation and after tracing begins.
Targeted omitted-barrier controls run after preparation so that root tracing cannot accidentally
make the missing barrier redundant; both direct-value and captured-closure controls still fail
validation with the expected missing-object counts.

The same two-million-object, 600-frame benchmark was rerun in
`out/bench/gc-latency-prepared-large`:

| Mark workers | Before incremental p99 / max frame work (ms) | After incremental p99 / max (ms) | Before / after completed cycles |
| --- | --- | --- | --- |
| 1 | 1.783 / 4.117 | 1.225 / 1.520 | 18 / 20 |
| 4 | 1.713 / 3.599 | 1.237 / 2.544 | 19 / 20 |

Preparation's maximum diagnostic phase fell from 3.836 ms to 1.020 ms. The largest final-run
diagnostic pause was 2.433 ms, with 2.261 ms spent discovering/rescanning dirty pages. Timing
runs are local observations rather than deterministic bounds, and logging runs are separate
from the frame comparisons. The next remaining budgeting target is dirty discovery/rescanning;
root scans, tracking setup/rearm, final completion and arbitrary finalizers also remain synchronous.
All 355 existing program bytecode fixtures also pass with automatic incremental collection,
validation and the small allocation trigger, once in hybrid mode and once in software-only mode.

### Persistent dirty queue and resumable discovery/rescanning

Software barriers now enqueue dirty pointer-bearing pages into an intrusive atomic stack,
with a per-page queued flag preventing duplicates. Mutators allocate no tracking records and
take no collector lock. The collector pops with the world stopped, detaches the link, then
clears the queued flag before rescanning. A mutator can therefore enqueue the page again while
its prior scan is suspended; the current scan keeps a separate page/block cursor. Cancellation
and cycle end detach the queue before allocator pages can be reclaimed. Begin resets queued
flags for the new cycle; this initialization pass remains synchronous.

Rescanning checks the slice deadline every 64 bitmap blocks and at page boundaries. It only
enqueues marked pointer-bearing objects; their fields still use the resumable mark drain,
including its word budget for large objects. A write to the currently suspended mark object
restarts that object's field cursor when its dirty page reaches the rescan cursor. Software-only
discovery no longer traverses all allocator pages each slice: the barrier-populated queue is
its pending work. Root scanning remains synchronous.

Linux retains kernel tracking for uninstrumented native writes. Kernel discovery has a persistent
page/offset cursor and checks its deadline after each bounded pagemap read (at most 256 OS pages).
The process-wide soft-dirty clear is deferred until the walk is complete. If mutators ran during
that walk, a final synchronous full kernel capture collects changes to already-visited pages
and newly inserted page-list heads before clearing any kernel bits. **This final capture remains
unbudgeted**: partial discovery must not erase writes that arrived behind its cursor. Moving the
walk across slices does not eliminate this Linux safety-net cost or establish a hard pause bound.

Kernel capture now runs when root/dirty/mark work reaches an apparent fixed point, rather than
on every tracing slice. A completed capture rearms kernel tracking, queues any newly discovered
sources, and requires another root/rescan/mark fixed point in that same pause before publishing
marks. If that work yields, another final capture is required before completion. Errors still
cancel partial state and use full collection. Software barriers remain active throughout.

Phase records distinguish `dirty_ms` (queued bitmap rescans) from `capture_ms` (kernel discovery,
including the final synchronous capture). Rearm time is accumulated separately. These labels
supersede the earlier combined dirty timing. The native diagnostic
`hl_gc_incremental_rescanning()` reports a suspended dirty-page scan; it is not a Haxe primitive.

The integration suite adds a live software-only mid-rescan mutation probe and a Linux probe
that deliberately bypasses the software barrier after its source page has already been visited
by a partial kernel capture. Both preserve the target and finalize it exactly once after release,
with one/four workers. Both also exercise full-collection cancellation of their suspended phase
and a subsequent incremental cycle. Hiding the final kernel revisit must make the independent
validator report exactly one missing reachable object. The host-side Apple backend contract probe
also checks requeueing after pop and duplicate suppression with four concurrent writers; this is
not an Apple ABI/runtime test. Existing targeted value/closure barrier omissions still fail as
expected. The complete integration suite and all 355 existing bytecode fixtures pass in hybrid
and mandatory-validated software-only modes with automatic incremental collection and the small
trigger for the bytecode runs.

The same two-million-object, 600-frame benchmark now writes to
`out/bench/gc-latency-dirty-large`:

| Mark workers | Previous incremental frame p99 / max (ms) | New frame p99 / max (ms) | Previous / new completed cycles |
| --- | --- | --- | --- |
| 1 | 1.225 / 1.520 | 1.038 / 1.429 | 20 / 21 |
| 4 | 1.237 / 2.544 | 1.038 / 1.135 | 20 / 26 |

In the separate diagnostic runs, queued rescanning peaked at 0.404 ms, kernel capture at
0.690 ms and the entire incremental pause at 1.123 ms. These are observations from this workload,
not hard bounds; comparative frame maxima include host scheduling effects, and completed-cycle
counts are not a parallel scaling claim. Remaining synchronous work includes initial tracking
setup, root capture, Linux final capture/global rearm, mark publication, sweeping/finalizers and
full-collection fallback. Expensive application finalizers and much larger/more mutable heaps
remain outside this benchmark's latency evidence.

### Sustained-mutation convergence benchmark

`tests/bench/incremental-gc/run-convergence.sh [output-directory]` runs four workloads with
one/four marking workers and two fresh-process repetitions by default. It records raw frame
samples, native GC metrics, heap pages, allocation totals, environment/source fingerprints,
separate post-load drain results and a text summary. Defaults are 600 simulated frames,
500,000 stable 64-byte linked nodes, a 1000 microsecond explicit slice every frame, and the
normal 64 MiB minimum allocation trigger. Rendering, event processing and frame sleeps are
excluded. Wall-clock cycle age includes workload work, sampling and CSV output between slices;
it is not a cycle duration measured in a sleeping 60 Hz application.

The workloads are:

- `rewrite`: 256 new 64-byte objects and 4096 pointer writes to a stable set of 4096 old objects
  per frame. This tests sustained insertion into already traced storage.
- `arrays`: replace a 1 MiB pointer array every frame and store it into an old object's field.
  Array entries refer to the stable old object set. Bulk initialization has no allocating
  conversions or safepoints, and records its destination range before publishing the array.
- `graphs`: construct a fresh 4096-node graph (256 KiB) per frame and retain eight generations.
  Link and ownership-slot writes use the managed-reference helpers.
- `overload`: combine rewrites, a 4 MiB replacement array and an 8192-node fresh graph per frame.
  This deliberately exceeds the lighter workloads' allocation/scan rate.

Configure with `GC_STRESS_FRAMES`, `GC_STRESS_NODES`, `GC_STRESS_SCALE` (1–16),
`GC_STRESS_BUDGET_US`, `GC_STRESS_REPEATS`, `GC_STRESS_MIN_TRIGGER`, `GC_STRESS_AUTO`,
`GC_STRESS_VALIDATE` and `GC_STRESS_SOFTWARE`. Automatic pacing is disabled by default to
isolate the fixed explicit allowance. `GC_STRESS_AUTO=1` additionally enables the existing
allocation-driven incremental pacing; that mode may spend more GC time during allocation.
Software-only mode still requires validation and is for correctness runs, not production timing.
For example:

```sh
bash tests/bench/incremental-gc/run-convergence.sh
GC_STRESS_AUTO=1 GC_STRESS_REPEATS=1 bash tests/bench/incremental-gc/run-convergence.sh out/bench/gc-convergence-auto
GC_STRESS_BUDGET_US=2000 GC_STRESS_REPEATS=1 bash tests/bench/incremental-gc/run-convergence.sh out/bench/gc-convergence-2ms
GC_STRESS_FRAMES=120 GC_STRESS_NODES=100000 GC_STRESS_REPEATS=1 GC_STRESS_VALIDATE=1 GC_STRESS_SOFTWARE=1 GC_STRESS_AUTO=1 bash tests/bench/incremental-gc/run-convergence.sh out/bench/gc-convergence-validated
python3 tests/bench/incremental-gc/plot-convergence.py out/bench/gc-convergence out/bench/gc-convergence-auto out/bench/gc-convergence-2ms
```

The optional plot script requires Matplotlib and exports PNG/SVG comparisons. The summary only
reads repetitions named by the current metadata, avoiding stale runs if a directory is reused.
It rejects missing/short runs, tracking failures, unexplained full collections and unsuccessful
quiescent drain/retained-data verification. A final drain stops mutation and finishes the pending
cycle, with a 10,000-slice guard, before a separate full collection and retained graph/array checks.
These operations are excluded from frame timing and from under-load completion counts. Merely
having a pending cycle at the last frame is not evidence of non-convergence.

`hl_gc_incremental_stats()` is a native diagnostic snapshot with started/completed incremental
cycles, pressure/tracking fallbacks, queued dirty pages (including a suspended rescan), pending
mark objects, current cycle age and last completed cycle duration. Queue length uses a maintained
atomic count instead of a diagnostic heap walk. Object counts are not pending bytes: a huge array
can be one object, and unharvested kernel bits and outstanding preparation pages are not included.
The metrics are diagnostic progress measures, not an exact scan-cost estimate. Mutator barrier
publication can be in flight during a snapshot. Cycle counters reset at global shutdown. Pressure
counts cover both explicit-step overflow and allocation-driven full-collection recovery; they do
not count a caller's explicit major collection. Native guards verify successful completion versus
pressure/read/clear failure counts and zero pending counts after completion.

Local Linux results below show the first repetition with one marking worker, a 35.44 MiB starting
heap and 600 frames. The fixed-1-ms run includes two repetitions per worker setting; automatic
and fixed-2-ms comparisons use one. All raw samples remain available, so these single-run values
should not be interpreted as deterministic timing limits or cross-worker scaling evidence.

| Workload, fixed 1 ms | Incremental completions | Pressure fallbacks | Peak heap pages (MiB) | Frame work p99 / max (ms) |
| --- | --- | --- | --- | --- |
| Rewrite old objects | 39 | 0 | 37.44 | 1.145 / 1.263 |
| Replace large arrays | 0 | 2 | 293.44 | 2.499 / 19.079 |
| Allocate fresh graphs | 21 | 0 | 73.44 | 1.662 / 2.481 |
| Combined overload | 0 | 10 | 306.44 | 18.416 / 29.726 |

Array replacement and overload therefore do not converge incrementally at this workload rate
and allowance: memory is periodically recovered through synchronous pressure fallbacks. Stopping
mutation lets their pending cycles drain (28 and 92 additional 1-ms requests respectively in these
samples). Heap-page totals include cached pages and conservatively retained allocations from an
unfinished cycle; they are not live-object size or RSS. Array replacement's final explicit major
collection reduces its heap pages to about 36.44 MiB, illustrating the difference.

Automatic pacing improves fresh graphs (32 completions, 49.44 MiB peak), but array replacement
still has zero incremental completions/two fallbacks and overload zero/ten. A fixed 2-ms allowance
improves graph throughput (69 completions, 44.94 MiB peak), but arrays still need two fallbacks
(despite two incremental completions), and overload still needs ten. Their frame-work p99 rises
to 5.330 and 24.490 ms in that comparison. Raising a fixed allowance alone does not solve these
workloads. The next investigation should focus on allocation-aware pacing and the repeated
scan cost of newly allocated pointer arrays, using both heap-growth and frame-latency evidence.
No production pacing defaults were changed by this benchmark work.

The complete incremental integration suite passes, including queue/capture controls and native
metrics assertions. Shorter runs of every workload with one/four workers also pass the independent
validator in hybrid mode and in software-only mode with automatic pacing. Validator-run timings
are not used in the comparisons above.

### Large-object boundary versus pointer-bearing GC work

`tests/bench/incremental-gc/run-large-object.sh [output-directory]` compares requested sizes
1 MiB minus 8 bytes, exactly 1 MiB, and 1 MiB plus 8 bytes. It runs pointer-free buffers,
reference-filled pointer arrays and all-null pointer arrays at each size, with one/four marking
workers and two fresh-process repetitions (600 frames and 500,000 stable nodes by default).
Order reverses on the second repetition. Timed runs use a 1-ms explicit allowance, automatic
pacing disabled, validation disabled and the normal 64 MiB minimum trigger.

Every frame allocates one primary object plus one pointer-free filler object. The filler
compensates for the primary object's **actual rounded payload size**, measured with
`hl_gc_get_memsize()`. Both the benchmark and summarizer check allocation-counter deltas:
exactly 4 MiB of allocator-reported payload is allocated every frame, including the first frame.
Object count is also constant (two per frame). This controls allocation pressure rather than
pretending that equal requested bytes imply equal allocator-reported or mapped bytes.

| Primary request | Actual primary payload | Primary allocator page | Pointer-free filler payload |
| --- | --- | --- | --- |
| 1 MiB − 8 B | 1 MiB | 2 MiB, variable-size path | 3 MiB |
| 1 MiB | 1 MiB | 1 MiB, dedicated large-object path | 3 MiB |
| 1 MiB + 8 B | 1 MiB + 64 KiB | 1 MiB + 64 KiB, dedicated large-object path | 3 MiB − 64 KiB |

Below the boundary, the allocator rounds the object to 8192-byte blocks, needs space for its
variable-size metadata, and chooses a power-of-two page large enough for the request plus
metadata. The result is a 2 MiB page holding a 1 MiB payload, with insufficient space for a
second payload of that size. At/above the boundary, the dedicated path rounds the page itself
to 64 KiB. Heap-page consumption therefore differs even when accounted allocation payload is
identical. The below/exact pair also has identical primary scan size; above has 64 KiB more
pointer-bearing payload in the pointer-array cases.

Reference-filled arrays and pointer-free buffers use the same initialization loop and address
values of separately rooted stable objects. The latter stores those values as opaque bytes
(`MEM_KIND_NOPTR`), so they are not GC edges. Both touch the complete rounded payload and filler,
record the destination range, and publish the primary through the same old managed slot.
The all-null control keeps the pointer-bearing allocation kind while removing non-null edges;
its initialization cost may differ, so allocation/initialization and GC-call timings are reported
separately. Allocator zeroing, faults and native initialization are included in frame work.

The publication slot is an isolated 8-byte managed object, in a different size class from the
stable 64-byte graph nodes. An initial version published through an old 64-byte node sharing a
page with the graph: dirtying that page repeatedly rescanned unrelated graph objects and
confounded the allocation/type comparison. Those exploratory samples are preserved separately
in `out/bench/gc-large-object-shared-slot`; the controlled results are in
`out/bench/gc-large-object`. This finding also shows why page-granularity dirty tracking can
make an apparently small mutation expensive. Original convergence workloads retain their
original publication behavior; this experiment controls that effect rather than silently
rewriting their results.

The controlled one-worker results, across two repetitions, are:

| Primary kind | Request | Incremental completions | Pressure fallbacks | Peak heap pages (MiB) |
| --- | --- | --- | --- | --- |
| Pointer-free, address-shaped data | 1 MiB − 8 B | 54–57 | 0 | 171.50–215.50 |
| Pointer-free, address-shaped data | 1 MiB | 55 | 0 | 139.50–151.50 |
| Pointer-free, address-shaped data | 1 MiB + 8 B | 53–58 | 0 | 127.50–147.50 |
| Pointer array, all null | 1 MiB − 8 B | 6 | 7 | 460.50–465.50 |
| Pointer array, all null | 1 MiB | 8–9 | 6 | 375.50–395.50 |
| Pointer array, all null | 1 MiB + 8 B | 4–7 | 7 | 379.50–395.50 |
| Pointer array, references | 1 MiB − 8 B | 0 | 9 | 362.50 |
| Pointer array, references | 1 MiB | 0 | 9 | 296.50 |
| Pointer array, references | 1 MiB + 8 B | 0 | 9 | 296.56 |

This is evidence against the large-object allocation threshold alone causing the convergence
failure: reference arrays fail on both sides, while pointer-free allocations converge at the
same payload rate. All-null pointer arrays also struggle, showing that walking pointer-bearing
slots has a cost even when no child is discovered. The experiment isolates pointer-bearing GC
work from allocation volume, but does not apportion every cost between dirty tracking, kernel
capture, repeated field scanning and conservative retention of black allocations.

The allocation boundary does have a substantial footprint effect: reference-array peak heap
pages increase by about 66 MiB below the threshold in these runs. Allocation/initialization p99
is generally around 1.8–2.1 ms across the boundary, with one noisier sample; there is no consistent
allocation-time discontinuity comparable to the loss of convergence. Frame/GC p99 can jump when
six versus seven fallbacks cross the 1% percentile boundary, so those percentile changes should
not be mistaken for a direct allocator latency cliff. Heap pages include allocator waste,
caches and floating garbage, rather than measuring live objects or RSS. These are local finite
runs, not realtime guarantees or a claim that all large-object workloads behave this way.

Run and visualize with:

```sh
bash tests/bench/incremental-gc/run-large-object.sh
python3 tests/bench/incremental-gc/plot-large-object.py out/bench/gc-large-object
python3 tests/bench/incremental-gc/plot-large-object.py out/bench/gc-large-object 4
GC_BOUNDARY_FRAMES=120 GC_BOUNDARY_NODES=100000 GC_BOUNDARY_REPEATS=1 GC_BOUNDARY_VALIDATE=1 GC_BOUNDARY_SOFTWARE=1 bash tests/bench/incremental-gc/run-large-object.sh out/bench/gc-large-object-validated
```

Other controls are `GC_BOUNDARY_BUDGET_US` and `GC_BOUNDARY_BYTES_PER_FRAME` (4 MiB default;
64-KiB-aligned, 4–64 MiB). The runner checks that the runtime library hash remains unchanged
during a matrix. The summary reads only configured repetitions, checks completion/data integrity,
equal allocation volume and fallback accounting, and exports `comparison.csv`. Optional
Matplotlib plots export PNG/SVG means with observed repeat ranges, separately for each worker
setting; they are not confidence intervals.

All size/type controls pass the independent validator in shorter hybrid and software-only runs,
including final retained-payload checks and quiescent drain. All four existing convergence
workloads also pass a shorter software-only validated regression run after extending their shared
benchmark driver. This task changes benchmark code and documentation, with no collector or
allocator policy changes. The evidence prioritizes pointer-array tracing/retention and finer
mutation tracking; reducing below-threshold page waste is a separate allocator opportunity.

### Attributing incremental field reads

`HL_GC_SCAN_PROFILE=1` enables diagnostic counters for actual incremental heap-field reads.
The collector records first reads and repeated reads **within each collection cycle**, using a
per-object high-water position. A partial scan that restarts counts its already-read prefix as
repeated work, rather than treating every resumed slice as a new scan. Counts include cycles
cancelled for a major collection. They exclude root walks, bitmap walks, kernel discovery,
independent validation, and major-collection tracing.

Dirty notifications carry software (`1`) and kernel (`2`) provenance, including notifications
that arrive while a page is already queued. Coalesced work uses a separate `both` (`3`) bucket;
it is counted once. `0` means discovery through roots/heap edges without a pending dirty reason.
These buckets describe why the queued scan/pass exists, not independent causal attribution to
individual writes. Sources can merge while an object is queued or its partial scan restarts.
The page queue's deduplication and marking policy are unchanged.

The opt-in profiler allocates private per-object metadata, adds atomic provenance updates to
barriers, and writes stderr records inside collector pauses. It changes scheduling and memory
use. **Do not use these runs to claim frame latency improvements.** The metadata is released
when the next cycle prepares that page, when incremental marks are discarded, or when the page
is freed. With profiling disabled there are no diagnostic metadata allocations or log records.

`GC-SCAN-TOTAL` reports the eight first/repeat × source counters for each completed or cancelled
cycle. `GC-SCAN-LARGE` reports scan chunks for objects at least 1 MiB, including whether they were
allocated black during this cycle. The boundary benchmark emits `GC-SCAN-PUBLISH` records and a
quiescent-drain boundary. Its summarizer checks complete cycle reports, first reads bounded by
object size, and large-object reads bounded by the corresponding aggregate category.

Publication records distinguish arrays in the current publication slot from arrays already
replaced in that slot **at scan time**. Replaced does not prove unreachable: conservative stack
roots or other heap edges could still retain an array. Black means retained by the incremental
allocation policy, not independently proven live. This avoids equating a GC mark bit with
current reachability.

Reproduce the 600-frame, 500,000-node, 4 MiB/frame boundary matrix, with one repeat and both worker
settings, using:

```sh
bash tests/bench/incremental-gc/run-scans.sh out/bench/gc-scans-hybrid
GC_BOUNDARY_SOFTWARE=1 GC_BOUNDARY_VALIDATE=1 \
  bash tests/bench/incremental-gc/run-scans.sh out/bench/gc-scans-software
GC_BOUNDARY_VALIDATE=1 \
  bash tests/bench/incremental-gc/run-scans.sh out/bench/gc-scans-hybrid-validated
```

Each output directory contains raw frame samples and scan logs, source/runtime fingerprints,
`scan-summary.csv`, and `scan-summary.txt`. Existing boundary settings also control shorter
validated runs. The software-only backend still requires its independent validator. Compare
validated hybrid/software controls when examining backend differences; validation itself
changes cycle scheduling. Frame timings from these diagnostic runs are not comparable to the
previous uninstrumented measurements.

In the first hybrid matrix, the exact-threshold, one-worker reference-array case read 1,014.79
MiB of incremental fields: 874.73 MiB first reads and 140.05 MiB repeat reads. Dirty-source reads
were 569 MiB software, 140.05 MiB kernel, and 4 MiB coalesced; the rest were ordinary discovery.
Large-array reads during frames were 555.23 MiB from the current array and 152.82 MiB from arrays
already replaced in the publication slot, with another 5 MiB during quiescent drain. All these
large-array reads were from allocations made black during their cycle.

The matching null-array control read 1,397.99 MiB, including 514 MiB repeated reads. Its current
and replaced array reads during frames were 493 MiB and 592 MiB respectively. Pointer-free
payloads produced no large-object field reads. These controls show duplicate scanning and
retained replaced arrays contribute real work, independently of discovering child references.

The software-only reference-array case at the same threshold had zero repeated field reads;
it still read 580 MiB of large arrays, including 23.61 MiB after replacement during frames.
Its total first-read volume also includes retracing the stable graph across more cycles, so
aggregate first-read totals are not a per-allocation cost comparison. Removing duplicates is a
promising next optimization, but does not eliminate the cost of initially scanning new
pointer-bearing allocations. Kernel discovery cannot simply skip software-dirty pages: later
unbarriered native writes still require the existing correctness protections.

The validated hybrid matrix confirms the same pattern. At the exact threshold with one worker,
reference arrays produced 187.05 MiB of repeat reads and null arrays produced 538 MiB; the
corresponding validated software-only controls produced zero and less than 0.01 MiB. Replaced
reference-array reads during frames were 208.87 MiB hybrid versus 23.61 MiB software-only.
These are diagnostic read volumes from one repeat, not a measured speedup or a production
recommendation to disable kernel tracking. All three complete matrices finished successfully
across all payload types, all three threshold sizes, and both worker settings; every aggregate
counter and retained-payload check passed.

The regular incremental integration suite passes with profiling disabled and enabled, including
missing-barrier controls, suspended-rescan mutations, final kernel revisits, pressure fallback,
FFI lifetime checks, and the independent validator. The host Apple backend contract test also
checks that software/kernel provenance merges on an already queued page. Normal unsupported,
`GC_DEBUG`, and `GC_MEMCHK` source configurations pass syntax checks.

### Captured dirty batches coalesce software and kernel notifications

Dirty-page tracing now consumes a frozen batch, separate from the incoming software notification
queue. The existing final capture merges kernel dirties into incoming notifications, performs
its required rearm, then transfers the incoming queue to the next tracing batch. Software
arrivals between pauses cannot extend a batch already being traced. The initial roots/mark
queue drains before the first batch capture; later captures occur after the previous batch and
its mark work drain. Roots are still revisited on every tracing pause.

The same per-page queued bit covers both queues. A write to a page still awaiting its batch
scan coalesces into that scan. Popping detaches the link and clears the queued bit before any
mutator resumes; writes after that point can queue the page for the next capture, independently
of a suspended bitmap or field cursor. Queue metrics count incoming and captured pages together,
plus the existing suspended-page adjustment. Completion still requires roots, captured dirty
work and marking to converge after a capture in the same pause. There are no new mutator locks
or tracking allocations.

This changes scheduling, not the kernel safety contract. Partial Linux capture still retains
soft-dirty bits and makes the final synchronous full revisit before `clear_refs`. Every capture
and rearm must succeed before its batch is published. Failure, pressure fallback, explicit
major collection and shutdown discard both queues without publishing partial marks. Software-only
and gated Apple test backends use the same batching, with their existing mandatory validator.

A new native test, `tests/native/gc_dirty_batch.c`, waits for a captured 1 MiB array to enter its
field scan, advances its cursor past the first 256 fields, then writes a previously unreachable
finalizable target into field zero **without a software barrier**. The next kernel capture must
revisit the already-scanned prefix. It checks survival, exact-once finalization after release,
and cancellation while the scan is suspended. Masking later kernel captures makes the
independent validator fail with exactly one missing object, confirming this is a meaningful
lost-write control. Both collector worker settings pass. Existing suspended bitmap/capture,
missing-barrier, kernel-revisit, tracking-failure and FFI tests also pass. The host Apple contract
test checks frozen-batch isolation, writes to pending versus popped pages, concurrent writer
deduplication, merged provenance, and discarding incoming and captured queues together. Actual
macOS execution remains untested locally.

The validated scan matrix in `out/bench/gc-scans-coalesced` uses the same 600 frames, 500,000-node
baseline and 4 MiB/frame allocation controls as the previous matrix. Exact-threshold, one-worker
incremental field-read totals changed as follows (MiB; these diagnostic timings are excluded
from performance claims):

| Payload | Before first / repeat reads | After first / repeat reads |
| --- | --- | --- |
| Reference-filled pointer array | 878.90 / 187.05 | 870.17 / 0 |
| Null-filled pointer array | 888.99 / 538.00 | 880.99 / 0 |

At and above the dedicated-allocation threshold, repeat reads were zero for both pointer-array
controls and both worker settings. Below the threshold, kernel-triggered repeats remain: the
one-worker reference-array case fell from 215.04 MiB to 29.83 MiB, and the null-array case from
512 MiB to 5 MiB. This optimization does not discard kernel notifications merely because a
software barrier ran. Deferred batch scanning also moves most array reads until after their
publication slot has been replaced: in the exact-threshold reference case, 557.18 MiB of reads
during frames were from replaced arrays. They still require tracing under the current black
allocation policy; replacement alone does not establish unreachability.

Uninstrumented before/after runs used a preserved pre-change `libhl.so`, the same benchmark
driver, sequential processes, two repeats, all three boundary sizes and both worker settings.
Before artifacts are under `out/bench/gc-coalescing-before/timing`; after artifacts are under
`out/bench/gc-coalescing-timing`. Exact-threshold, one-worker ranges across the two repeats:

| Payload / measure | Before | After |
| --- | --- | --- |
| Null array: completed incremental cycles | 7 | 38 |
| Null array: pressure fallbacks | 7 | 0 |
| Null array: p99 frame work (ms) | 14.526–15.718 | 4.045–4.087 |
| Null array: peak allocator pages (MiB) | 379.5 | 171.5–175.5 |
| Reference array: completed incremental cycles | 0 | 2–5 |
| Reference array: pressure fallbacks | 9 | 7–8 |
| Reference array: p99 frame work (ms) | 15.216–15.221 | 14.469–15.463 |
| Reference array: peak allocator pages (MiB) | 296.5 | 391.5–415.5 |

The null-array improvement is consistent at the exact threshold with four workers too: pressure
fallbacks fell from seven to zero and frame p99 from 16.892–17.715 ms to 3.635–3.972 ms. The
reference-filled case remains overloaded; removing duplicate reads does not make its first
scan fit the 1 ms budget. Some reference-array runs complete cycles and trigger fewer pressure
recoveries but retain more allocator pages. This is a material workload-dependent memory
tradeoff, not a universal convergence or latency guarantee. Below-threshold allocator waste
and residual kernel rescans remain separate opportunities.

The original 1 MiB/frame array workload, which shares its publication node's page with the
stable graph, completed zero cycles with two pressure fallbacks before batching. In the new
one-repeat run it completed 14 cycles with one fallback at one worker, and 25 cycles with no
fallbacks at four workers. One-worker peak pages rose from 293.44 to 332.44 MiB during the initial
long cycle; four-worker peak fell to 86.44 MiB. The mixed overload workload still completed zero
cycles and required ten pressure fallbacks. Raw results are in
`out/bench/gc-coalescing-before/convergence` and `out/bench/gc-coalescing-convergence`.

The lighter two-million-object, 600-frame latency workload was also rerun, with two incremental
runs per worker setting and separate phase diagnostics:

| Workers | Before p99 / max frame work (ms) | After p99 / max (ms) | Before / after completed cycles |
| --- | --- | --- | --- |
| 1 | 1.046 / 1.603 | 1.051 / 1.356 | 28 / 35 |
| 4 | 1.056 / 1.316 | 1.040 / 1.212 | 30 / 39 |

These are local observed timings, not hard pause bounds. Synchronous root scans, the final
kernel revisit, tracking setup/rearm, finalizers, and full fallback can still exceed a requested
slice. Raw latency results are under `out/bench/gc-coalescing-before/latency` and
`out/bench/gc-coalescing-latency`. The before runtime SHA-256 is
`fc588804402ba86624ce42ff18b6721e81a9db74aafc9ebbb2f266325a633cdb`; the measured after runtime is
`7d923d79f71b01e9a0cf810beadf647ce7d68dcbe14833c38404bbbf85293a67`. Before-run workspace source
hashes describe the edited workspace at measurement time; the preserved library hash identifies
the actual pre-change binary. Benchmark metadata now also fingerprints the write-tracking
source, and the latency runner explicitly disables scan profiling.

The complete incremental integration suite passes with scan profiling off and on. All 355
available program fixtures pass at their expected exits with automatic incremental collection,
independent validation and a 64 KiB trigger, once with hybrid tracking and once with software-only
tracking. Short automatic-pacing runs of all four convergence workloads pass in both backends
with validation and both worker settings. Normal unsupported, `GC_DEBUG`, and `GC_MEMCHK`
configurations pass syntax checks. First-time pointer-array tracing and black-allocation
retention are the next bottlenecks to investigate; the batch change does not introduce reference
counting or relax the independent validation controls.

### First-pass field traversal and pointer lookup

The first-scan path now avoids repeated address-decoding work while preserving the existing
marking and black-allocation policies. A `perf` CPU-clock profile of a clean reference array
placed about 85% of sampled execution in `gc_inc_trace_slice`, which includes the inlined field
visitor. Annotated assembly showed the exact-object lookup repeatedly using integer division.
The allocator's `size_bits` initialization had its loop comparison reversed: starting at zero,
ordinary block sizes never advanced to their power-of-two exponent. Correcting the comparison
restores shift-based exact-pointer lookup for power-of-two blocks. Non-power-of-two blocks
retain division. Unsigned shifts avoid overflowing a signed shift while classifying large
non-power-of-two blocks. Allocation sizes, classes and page geometry are unchanged. This shared
metadata correction also benefits exact-pointer lookup in ordinary full collections; interior
root lookup retains its existing algorithm.

Incremental traversal additionally keeps a last-target-page cache within each stopped-world
drain. An unsigned address-range check can reuse that page for clustered references; misses
use the existing page map and range validation. Every candidate still passes exact object-start,
size-table and mark-bit checks. A cache hit does not turn an interior heap pointer into a valid
reference. The cache is discarded at each pause boundary, and allocator pages cannot be
reclaimed while a drain is running.

The field cursor and end pointer stay local inside the inner loop, with the resumable cursor
published before yielding. Source-page/block metadata is decoded once per scanned object or
resumed slice, using a shift where possible, and reused for its extent and queued-bit cleanup.
This removes repeated global cursor traffic, page lookup and source-block division. Deadline
checks remain every 256 fields and 64 completed objects. Dirty-prefix restarts, captured batches,
kernel revisits and final validation keep their prior behavior.

`first-scan.c` isolates a clean, rooted pointer array from allocation pressure. It allocates and
initializes outside the measured cycles, then measures first traversal of a 64 MiB array over
16 incremental cycles at a 1 ms allowance. Patterns cover clustered valid references, scattered
valid references, rejected interior references, non-heap values, and nulls. The effective source
array throughput includes per-cycle root, preparation, kernel and completion work; it is not a
raw memory-bandwidth number. Separate wall-clock and main-thread CPU times distinguish work
from descheduling. Optional `perf stat` counters cover the whole process, including initialization
and the initial full collection, rather than only the timed field loop.

Initial unrestricted wall-clock runs became noisy as other workloads occupied the machine.
The primary comparison alternates before/after order across three repeats and pins both
versions to CPU 12, an efficiency core on this machine without an SMT sibling. Both versions
use the same freshly compiled driver. Median CPU throughput from
`out/bench/gc-first-scan/paired`:

| Array contents | Before (MiB/s) | After (MiB/s) | Throughput ratio | Whole-process instruction change |
| --- | --- | --- | --- | --- |
| Clustered valid references | 1,305.2 | 2,352.5 | 1.80× | −19.8% |
| Scattered valid references | 1,285.1 | 1,568.2 | 1.22× | +10.6% |
| Rejected interior references | 1,673.3 | 2,590.1 | 1.55× | −23.3% |
| Non-heap values | 3,482.6 | 3,879.3 | 1.11× | +3.1% |
| Nulls | 4,151.7 | 7,708.2 | 1.86× | −7.5% |

The scattered pattern executes more instructions due to the extra range-cache miss checks,
but its measured CPU throughput still improves. This is a workload- and architecture-dependent
tradeoff. These results do not establish a hard pause bound or guarantee a frame-rate gain
under contention.

The preserved before runtime is `out/bench/gc-scan-before/libhl.so`, SHA-256
`2044f1a3fca816fdcfef19d628f7cb0383d2649e924309410191623b15cde94d`; the measured after runtime is
`931a341fec6f80f80eb8e6c462069196c35b09c7699d20cf7d6650bf46426305`. The paired runners verify both
library fingerprints stay unchanged and record driver/source fingerprints. Before-library runs
use the preserved binary; workspace source fingerprints describe the current edited checkout.
Reproduce using a CPU allowed on the host:

```sh
GC_FIRST_SCAN_CPU=12 GC_FIRST_SCAN_PERF=1 \
  bash tests/bench/incremental-gc/run-first-scan-paired.sh \
  out/bench/gc-scan-before out/bench/gc-first-scan/paired

GC_BOUNDARY_CPU=12 GC_BOUNDARY_SIZES=1048576 GC_BOUNDARY_REPEATS=3 \
  bash tests/bench/incremental-gc/run-boundary-paired.sh \
  out/bench/gc-scan-before out/bench/gc-first-scan/boundary-paired

GC_BOUNDARY_CPU=12 GC_BOUNDARY_SIZES=1048576 GC_BOUNDARY_REPEATS=2 \
GC_BOUNDARY_NODES=100000 \
  bash tests/bench/incremental-gc/run-boundary-paired.sh \
  out/bench/gc-scan-before out/bench/gc-first-scan/boundary-small-paired
```

Omit `GC_FIRST_SCAN_PERF` to run without hardware counters. The standalone
`run-first-scan.sh` measures one runtime across all five patterns, reporting both CPU and wall
throughput. The paired boundary runner defaults to all three allocator threshold sizes; the
commands above select the exact threshold for the controlled same-core comparison. It uses
one collector worker, 600 frames, a 1 ms tracing allowance and 4 MiB/frame of actual payload,
with automatic collection disabled. It validates allocation volume, pressure-only full
collections, and retained payloads after quiescent drain.

End-to-end behavior remains limited by the live graph and retention policy. On the pinned
500,000-node reference-array workload, both versions completed zero incremental cycles and
needed nine pressure fallbacks in all three repeats; peak allocator pages stayed at 296.5 MiB.
Frame p99 remained roughly 20–24 ms under shared-machine load. Faster individual field scans
did not make that workload converge within its wall-clock budget.

The separately labeled 100,000-node control exposes the array improvement more clearly:

| Exact-threshold reference array, two repeats | Before | After |
| --- | --- | --- |
| Completed incremental cycles | 0 | 44–76 |
| Pressure fallbacks | 9 | 1–4 |
| p99 frame work (ms) | 16.956–18.358 | 3.874–4.436 |
| Maximum frame work (ms) | 18.594–20.419 | 16.912–20.284 |
| Peak allocator pages (MiB) | 268.5 | 295.5–303.5 |

With one to four fallback frames out of 600, full collections fall outside the p99 quantile;
the maximum still exposes those pauses. The null-array control had no pressure fallbacks in
either version, with cycles increasing from 111–112 to 149 and peak pages decreasing from
47.5 MiB to 35.5–39.5 MiB. These measurements are observations under shared-machine load,
not confidence intervals. **The goal of reducing reference-array fallbacks without increasing
peak heap was not consistently met.** This is consistent with black allocations surviving
incremental completion and fewer full recovery sweeps; these measurements do not independently
attribute every retained byte. This change does not weaken black retention or alter pressure
fallback thresholds to conceal that tradeoff.

Full unrestricted threshold/type matrices and a validated diagnostic matrix also completed at
`out/bench/gc-first-scan/boundary` and `out/bench/gc-first-scan/validated`. They confirm the scan
counters and retained payloads, but their wall-clock results overlap other machine workloads
and should not be treated as a clean before/after frame comparison. The two-million-object
latency results are retained under `out/bench/gc-scan-before/latency` and
`out/bench/gc-first-scan/latency` with the same limitation. The same-core paired CPU results
above are the primary evidence for the traversal optimization.

The new `tests/native/gc_block_sizes.c` guard covers fixed and variable classes, power-of-two
and non-power-of-two sizes, and both sides of the large-allocation boundary. Targets survive
through interior incremental roots, then through exact ordinary explicit roots. Unaligned and
word-aligned interior heap edges to an otherwise unreachable finalizable target must be
rejected, including a repeated target-page cache hit. Releasing the roots finalizes every
remaining target exactly once. The guard passes with hybrid and mandatory-validated software
tracking at both worker settings.

The complete incremental integration suite passes with profiling off and on, including writes
behind paused field cursors and kernel-revisit negative controls. All 355 available program
fixtures pass at expected exits with automatic incremental collection, validation and a 64 KiB
trigger in both hybrid and software-only modes. All four short automatic-pacing convergence
workloads pass with validation in both backends and both worker settings. Normal unsupported,
`GC_DEBUG`, and `GC_MEMCHK` configurations pass syntax checks. Large-live-graph tracing and
black-allocation retention remain separate bottlenecks after this first-scan optimization.

### Black-allocation retention completion snapshots

`HL_GC_RETENTION_PROFILE=1` enables scan metadata and an independent conservative
reachability walk at each successful incremental completion. The walk starts
from registered roots, thread stacks and saved registers, with fresh bitmaps and
a separate libc worklist. It never seeds reachability from incremental marks.
Missing reachable marks still fail validation. Profiling does not change marks,
allocation pacing, black-allocation policy or sweep decisions.

`GC-RETENTION` rows partition **marked object payload bytes**, not committed heap
pages, by `black` (allocated during this cycle), `reachable` (independent walk at
completion), and `age_bucket`. For black allocations, age is allocation volume
since birth: buckets 0–3 mean below 1 MiB, 1–16 MiB, 16–64 MiB, and at least
64 MiB. Birth counters use the allocator's total-allocated counter. Objects
already present when the cycle started have unknown birth age and use bucket 0;
that bucket must not be interpreted as their actual age. Sizes include allocator
rounding. Metadata is private, contains no GC roots, and is freed with the existing
scan metadata. The disabled path adds no per-object metadata allocation.

Reproduce with:

```sh
bash tests/bench/incremental-gc/run-retention.sh out/bench/gc-retention-final
```

The runner verifies a controlled fixture on hybrid and software-only backends:
32 bytes of unreachable black allocation survive completion, 1 MiB of rooted
black allocation remains reachable, and the unreachable finalizable object is
reclaimed by later full collection exactly once. It checks the allocation-age
bucket as well. The boundary workload runs 600 frames, 100,000 retained nodes,
1 MiB primary arrays, 4 MiB allocation per frame, one GC worker, and a 1 ms
requested manual allowance. Runtime and source hashes are saved in
`environment.txt`; `retention-summary.csv` separates under-load completions from
the final mutation-free drain.

Observed on this Linux machine:

| Payload | Under-load completions | Unreachable black MiB per completion, min / median / max |
| --- | ---: | ---: |
| Reference array | 23 | 32 / 48 / 96 |
| Null pointer array | 39 | 36 / 44 / 60 |
| Pointer-free bytes | 59 | 28 / 28 / 56 |

These are objects independently unreachable **at completion**, including the
workload's short-lived filler allocations. They are retained by the black marks
for that cycle. The figures are snapshots, not unique bytes summed across the
whole run, and do not by themselves explain committed-page fragmentation or all
peak-heap growth. Conservative roots can overestimate reachability. This mode
adds a full heap walk, allocation metadata and synchronous logging; its timings,
cycle counts and pressure fallbacks are diagnostic results, not comparisons with
profiling disabled. Cancelled cycles have no completion snapshot. Age is measured
within the current cycle, not across subsequent cycles or in wall time.

The evidence supports measuring earlier cycle starts or allocation-sensitive
pacing before changing black allocation. Making new objects white requires a
separate correctness design for initialization and references created while
tracing; these diagnostics do not justify that policy change on their own.
The existing complete incremental integration suite and the unsupported-platform
syntax check also pass with this implementation.

### Experimental allocation pacing controls

Two opt-in controls now separate incremental start timing from allocation-driven
slice frequency. Both are read at GC initialization:

- `HL_GC_INCREMENTAL_START_PERCENT`: integer 1–100, default 100. With automatic
  incremental GC enabled and a supported tracker, scale both the byte and object
  count start thresholds by this percentage. 50 requests a start at half the
  ordinary allocation threshold, including its minimum floor.
- `HL_GC_INCREMENTAL_STEP_BYTES`: integer 65536–16777216, default 262144. While a
  cycle is active, allocation checks request the existing 1 ms slice after this
  many bytes have been allocated since the preceding explicit or automatic step.

Unset or invalid values preserve the defaults. These controls do not change
black marking, write barriers, explicit `hl_gc_step()` allowances, or the existing
full-collection pressure limits. A denied/unsupported tracker uses the ordinary
full-GC start threshold even with an earlier-start setting. More slices can
increase the total GC work within one frame: the 1 ms allowance is per slice,
not per frame, and is still soft.

The convergence driver accepts automatic mode `2` for allocation-driven pacing
alone. Mode `0` remains explicit steps only, and mode `1` remains automatic pacing
plus an explicit step per frame. Automatic work happens inside allocation calls,
so frame time, rather than the driver's separate `gc_ms` column, measures the
whole cost in mode 2. Retention profiling now emits publication/drain markers
without also requiring `HL_GC_SCAN_PROFILE=1`.

Reproduce the four-way comparison (baseline, earlier start, twice as frequent
steps, and both):

```sh
GC_PACING_CPU=12 bash tests/bench/incremental-gc/run-pacing.sh out/bench/gc-pacing-final
GC_PACING_CPU=12 GC_PACING_NODES=500000 bash tests/bench/incremental-gc/run-pacing.sh out/bench/gc-pacing-large-final
GC_PACING_CPU=12 GC_PACING_RETENTION=1 GC_PACING_REPEATS=1 bash tests/bench/incremental-gc/run-pacing.sh out/bench/gc-pacing-retention-final
```

Choose an available CPU on other machines, or omit pinning. Each timing comparison
uses three repetitions per policy, reverses policy order on alternating repeats,
600 frames, a 1 MiB primary allocation and 4 MiB total allocation per frame,
one GC worker, and no explicit per-frame GC step. Validation, retention profiling
and scan profiling are disabled for timing. The runner checks allocation volume,
tracking failures, full-collection accounting, successful payload verification
and unchanged runtime hashes. It records the environment and source/runtime
fingerprints beside the CSVs. Diagnostic and timing runs should run separately.
“Peak heap” here means the maximum heap sampled at frame boundaries, rather than
an instrumentation of every within-frame allocation peak. Host contention can
still affect wall-clock results even when pinned.

On the final build, medians across three repetitions with 100,000 retained nodes
were:

| Payload | Start setting | Completed cycles | Sampled peak heap MiB | Frame p99 ms | Total frame time ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| References | 100% | 36 | 91.5 | 6.227 | 1485.0 |
| References | 50% | 70 | 51.5 | 5.209 | 1541.3 |
| Null array | 100% | 36 | 87.5 | 6.741 | 1379.9 |
| Null array | 50% | 70 | 51.5 | 5.530 | 1490.3 |
| Pointer-free | 100% | 36 | 79.5 | 6.602 | 1324.1 |
| Pointer-free | 50% | 70 | 47.5 | 5.127 | 1426.7 |

All these runs had zero pressure/tracking fallbacks. Earlier starts reduced
sampled heap and p99, but increased total measured frame time by approximately
4–8%. Halving the step interval alone produced the same cycle counts and sampled
heap medians as the baseline at this graph size. More frequent collections have
a throughput cost even when individual slow frames improve.

With 500,000 retained nodes, the final-build medians were less consistent:

| Payload | Start setting | Pressure fallbacks | Sampled peak heap MiB | Frame p99 ms | Maximum frame ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| References | 100% | 3 | 291.5 | 6.217 | 25.850 |
| References | 50% | 3 | 294.5 | 8.302 | 27.537 |
| Null array | 100% | 0 | 142.5 | 6.569 | 8.672 |
| Null array | 50% | 0 | 146.5 | 6.949 | 9.735 |
| Pointer-free | 100% | 0 | 146.5 | 7.756 | 11.525 |
| Pointer-free | 50% | 0 | 106.5 | 5.582 | 6.909 |

For reference-heavy churn, twice-as-frequent steps alone reduced the median
pressure fallback count from 3 to 1, but kept sampled peak heap near 294.5 MiB
and maximum frame time near 25.6 ms. Combining both controls still had a median
of two pressure fallbacks and approximately 28 ms maximum frames. For null
arrays, the combined policy lowered sampled heap to 114.5 MiB, at increased
total measured frame time. None of these results establishes a generally better
default or a bounded frame pause. The defaults therefore remain unchanged.
Earlier starts are a workload-specific memory/latency versus throughput tradeoff;
revisiting the full rooted graph more often can outweigh their benefit.

A separate final-build retention run with 100,000 nodes measured median
unreachable black payload per under-load completion of 27 → 26 MiB for references,
22 → 20 MiB for null arrays, and 19 → 22 MiB for pointer-free allocations when
changing only the start threshold from 100% to 50%. This is not a uniform reduction
in black garbage per cycle. Earlier starts shorten the allocation interval before
the next collection; they do not change black-object liveness rules. Instrumented
snapshot runs perturb cycle pacing and must not be used as latency comparisons.

Validation on the final build: the complete incremental integration suite passes
with both controls enabled, including automatic-threshold checks on hybrid and
software-only backends, invalid-setting fallback tests, and a denied-proc tracker
regression verifying that early starts do not trigger early ordinary full GC.
All 355 available expected-exit bytecode fixtures pass on both backends with
validation and earlier/denser pacing enabled. Automatic-only validation stress
runs cover all four existing convergence workloads with one and four workers on
both backends. Unsupported-platform, `GC_DEBUG`, and `GC_MEMCHK` syntax checks
pass. Actual Apple hardware remains untested.

### Shared incremental GC allowance per host frame

`hl_gc_frame_begin(microseconds)` / `hl.Gc.beginFrame(microseconds)` reset a
process-wide allowance at a host frame boundary. Automatic allocation-triggered
slices and explicit `Gc.step()` calls share it, including calls from different
registered threads. The GC lock serializes accounting and collection. The host
owns frame boundaries: there is no timer-based refill or implicit 60 Hz window.

A valid allowance is 0–100,000 microseconds, or -1 for unlimited work with frame
metrics enabled. Zero defers incremental work immediately. NaN, infinity and
other invalid values return false without resetting the current allowance.
`Gc.frameRemaining()` returns remaining microseconds, clamped to zero, or -1 for
unlimited operation. `Gc.endFrame()` disables frame accounting and the limit;
it is idempotent. Beginning the next frame resets its counters and allowance.
The native `hl_gc_frame_stats()` snapshot exposes requested and spent microseconds,
automatic and explicit slice counts, deferred check counts and full collections.
Calling neither API preserves the previous unbudgeted behavior without clock
reads for frame accounting. Wasm accepts these controls as no-ops, consistent
with its other HashLink GC controls; it has no HashLink frame allowance.

Before a slice starts, its requested allowance is clamped to the frame's
remaining allowance. After the slice returns, its actual elapsed time is charged.
On Linux and modern Apple targets the frame clock is monotonic; Windows uses
QueryPerformanceCounter. Exhaustion defers subsequent slices without resetting
the active mark cursor, marks, dirty tracking or allocation accounting. A deferred
`Gc.step()` returns false and does not start a new cycle. When a frame budget is
active, callers should use `Gc.incrementalPending()` to distinguish a pending
cycle from an attempted step that was deferred before starting one.

This is a **soft scheduling allowance**, not a hard pause cap. A running slice
can exceed it during root capture, kernel capture/rearm, finalizers or other
synchronous work. Allocation-pressure recovery and tracking-failure full
collections bypass deferral, and their time is charged. Unsupported platforms
continue to collect fully. Explicit `Gc.major()` remains synchronous and outside
frame accounting. Spent time measures collector calls after acquiring the GC
lock, including stop/resume coordination and diagnostics, not the caller's wait
for the lock. Deferring work can increase heap usage and cause more full recovery
collections; those collections can dominate worst-frame latency.

The desktop `FrameGcScheduler` now opens the allowance at `beginFrame()` and
closes it after its boundary collection. It preserves the existing behavior of
disabling automatic collection during rendering. Explicit steps during rendering
consume the same allowance as the boundary step; an exhausted allowance skips
that additional boundary slice. Duplicate scheduler begin/end calls preserve the
allowance rather than refilling it, and error cleanup releases it. Idle and
emergency full collections remain synchronous.

The convergence driver accepts `GC_STRESS_FRAME_BUDGET_US` and emits per-frame
spent time, automatic/explicit slices, deferred checks and full collections. Its
final drain runs with the frame limit disabled so idle completion cannot be
confused with convergence under load. Reproduce the comparison with:

```sh
GC_FRAME_CPU=12 bash tests/bench/incremental-gc/run-frame-budget.sh out/bench/gc-frame-budget-final
GC_FRAME_CPU=12 GC_FRAME_NODES=500000 bash tests/bench/incremental-gc/run-frame-budget.sh out/bench/gc-frame-budget-large-final
```

Choose an available CPU on other machines or omit pinning. The runner compares
unlimited, 1 ms and 2 ms frame allowances with automatic pacing alone, the
unchanged 100% start threshold and 256 KiB step spacing, 600 frames, one GC worker,
1 MiB primary allocations and 4 MiB total allocation per frame. It runs three
repetitions with reversed policy order on alternate repetitions. Timing runs have
validation and scan/retention/latency profiling disabled and run separately from
correctness tests. Baseline frames use the unlimited recording mode for matched
accounting overhead. Allocation volume, completed payload checks, full-collection
accounting, tracking failures and runtime hashes are checked; fingerprints and
raw CSVs are retained with the summary. Heap peaks are sampled at frame boundaries.

Final-build observations (medians of three repetitions):

| Retained nodes / payload | Frame allowance | Completed cycles | Pressure fallbacks | Sampled peak heap MiB | Frame p99 ms | Maximum frame ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 100,000 / references | Unlimited | 36 | 0 | 87.5 | 6.079 | 7.296 |
| 100,000 / references | 1 ms | 0 | 9 | 267.5 | 20.144 | 21.591 |
| 100,000 / references | 2 ms | 36 | 0 | 91.5 | 6.164 | 7.011 |
| 500,000 / references | Unlimited | 35 | 0 | 155.5 | 5.889 | 6.288 |
| 500,000 / references | 1 ms | 0 | 9 | 295.5 | 24.335 | 31.564 |
| 500,000 / references | 2 ms | 35 | 0 | 154.5 | 5.897 | 6.221 |
| 500,000 / pointer-free | Unlimited | 35 | 0 | 134.5 | 6.843 | 7.353 |
| 500,000 / pointer-free | 1 ms | 35 | 0 | 167.5 | 5.822 | 6.316 |
| 500,000 / pointer-free | 2 ms | 35 | 0 | 131.5 | 6.754 | 7.236 |

The 1 ms allowance deferred a median of 349 checks in the larger reference case,
but could not keep up: it reached nine pressure full collections and no under-load
incremental completions. Pointer-free allocation still converged under 1 ms, with
257 deferred checks and increased sampled heap. The 2 ms policy had zero median
deferrals in these cases; its benefit is retaining more headroom, not a demonstrated
latency improvement over the unlimited baseline. Individual charged calls still
exceeded either allowance: for example, the larger reference case with a 2 ms
allowance had a median maximum charged GC time of 4.296 ms. Full recovery pauses
can also fall outside p99, so maximum frames and fallback counts matter.

These results validate deferral/accounting and expose its capacity tradeoff. They
do not establish a default allowance for allocation-enabled rendering. Global
frame limiting remains opt-in through the frame API. The desktop scheduler's
existing 1 ms boundary slice now shares its allowance with manual in-frame work;
it continues to disable automatic GC during rendering. Black allocation, retention
policy and all recovery thresholds are unchanged.

Final validation: the complete incremental integration suite passes, including
zero-budget deferral, shared exhaustion across registered allocation threads,
renewal, invalid-input no-ops, unlimited/end behavior, zero-budget pressure
recovery, unsupported-tracker full fallback, and the real desktop scheduler's
idempotent frame boundaries. Native cases cover hybrid/software-only backends
with one and four workers. The updated incremental API program compiles for
HashLink, wasm32 and Wasm GC, runs on both native backends with one/four workers,
and passes both Wasm smoke runs. All 355 existing bytecode fixtures pass on both
backends. Automatic-only stress with a 1 ms shared allowance and independent
validation passes all four existing convergence workloads with one/four workers
on both backends. Unsupported-platform, GC_DEBUG and GC_MEMCHK syntax checks pass.
Apple and Windows runtime execution remain untested on this Linux machine.

### Resumable empty-page reclamation after mark publication

Phase profiling identified completion bookkeeping, rather than root scanning, as
the largest repeatable overrun in the 500,000-node reference workload. With the
previous runtime, the diagnostic completion pauses had median `finish_ms` 2.115
(maximum 2.469 ms), median root scanning 0.001907 ms, kernel capture 0.373 ms and
rearm 0.448 ms. Most of that completion work was synchronous empty-page release.
Diagnostic logs are in `out/bench/gc-frame-phases-before/refs.log`; they perturb
caller timing and are used to locate work, not to establish frame-time gains.

Incremental completion now publishes the independently validated marks, sweeps
owner metadata, calls finalizers and stops dirty tracking before releasing empty
pages. Page reclamation uses the remainder of that slice and continues in later
budgeted slices. Finalizers, root/kernel capture and the same-pause correctness
fixed point are unchanged. No page is reclaimed while tracing is active. Ordinary
full collections still perform synchronous reclamation with the same empty-page
cache policy and budget calculation. A new incremental mark cycle waits until
reclamation finishes; forced/pressure full collection cancels the cursor before
replacing marks or releasing pages.

The cursor points to a live page-list link, so new pages prepended between slices
cannot be accidentally dropped when an old page is removed. Reclamation skips
pages whose allocator free lists were flushed after publication (`need_flush` is
false). This matters for newly allocated fixed-size slots and TLAB reservations:
the old bitmap can still look empty even though those pages now contain live
objects. Variable-size allocation already marks its new object starts, but does
not replace the need for the fixed-page guard. Newly created pages are also
ineligible. Collection remains serialized by the GC lock with the world stopped
for each slice; allocator-page release is the yielding unit. A single very large
page release or other synchronous kernel operation can still exceed the allowance.

`Gc.incrementalPending()` now includes committed marks with reclamation still
pending. `Gc.incrementalReclaiming()` / `hl_gc_incremental_reclaiming()` distinguish
that phase. `Gc.step()` returns false until its remaining cleanup finishes, or
until a full collection replaces it. The cumulative completed-cycle/collection
counters advance when marks are committed, before deferred page reclamation.
The recorded cycle duration ends at publication; pending queue/age metrics describe
active tracing, not this cleanup cursor. Cleanup slices update the existing pause
counters and consume the shared frame allowance. They emit `GC-RECLAIM` latency
rows; the publication row reports `reclaim_ms` separately from `rearm_ms`.
`GC-LATENCY`'s `done=1` denotes the marking fixed point/publication, which may still
leave a reclamation cursor. The stress driver emits `GC-LATENCY-DRAIN` so future
phase summaries can exclude the final mutation-free drain.

The diagnostic after-run had median publication `finish_ms` 0.012875 ms, median
publication pause 1.487 ms versus 3.344 ms before, and separate cleanup pauses up
to 1.145 ms. Overall diagnostic marking pauses still reached 3.674 ms, demonstrating
that this removes one source of overruns rather than establishing a hard limit.
That logged run completed fewer cycles under instrumentation, so phase timings
alone must not be interpreted as an end-to-end throughput comparison.

Summarize the captured diagnostic runs with:

```sh
python3 tests/bench/incremental-gc/summarize-phases.py out/bench/gc-frame-phases-before/refs.log out/bench/gc-frame-phases-after/refs.log
```

Paired timing runs disable phase/scan/retention logging and validation. They use
the preserved previous runtime (`0c21b0c4db4487a465b8fa833f626561e9afbb357625990a7a605daf8548b638`)
and the new runtime (`b7f22f55b0b54242765e04777ae4a1b10308b7594774f4741796b476d77e9e37`),
three alternating-order repetitions per payload, CPU 12, 600 frames, 1 MiB primary
allocations, 4 MiB total allocation per frame and one GC worker. Automatic pacing
uses unchanged 100% start thresholds / 256 KiB spacing and a 2 ms shared allowance.

```sh
GC_RECLAIM_CPU=12 bash tests/bench/incremental-gc/run-reclaim-paired.sh out/bench/gc-frame-phases-before out/bench/gc-reclaim-paired
GC_RECLAIM_CPU=12 GC_RECLAIM_NODES=100000 bash tests/bench/incremental-gc/run-reclaim-paired.sh out/bench/gc-frame-phases-before out/bench/gc-reclaim-small-paired
GC_RECLAIM_CPU=12 GC_RECLAIM_NODES=100000 GC_RECLAIM_AUTO=0 bash tests/bench/incremental-gc/run-reclaim-paired.sh out/bench/gc-frame-phases-before out/bench/gc-reclaim-manual-paired
```

Choose an available CPU or omit pinning on other machines. The runner saves hashes,
settings and raw samples, checks constant allocation volume, payload validity,
tracking failures and full-collection accounting. The shared allowance can be
changed with `GC_RECLAIM_BUDGET_US`. Sampled heap peaks are at frame boundaries;
CPU pinning cannot eliminate external scheduler contention.

For 500,000 retained nodes, medians across the three automatic-pacing repetitions:

| Payload | Version | Completed cycles | Pressure fallbacks | Sampled peak heap MiB | Frame p99 ms | Maximum frame ms | Maximum charged GC ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| References | Before | 35 | 0 | 174.5 | 6.038 | 7.220 | 5.087 |
| References | After | 35 | 0 | 170.5 | 4.403 | 4.563 | 2.628 |
| Null array | Before | 35 | 0 | 146.5 | 6.604 | 6.881 | 4.979 |
| Null array | After | 35 | 0 | 150.5 | 4.316 | 4.724 | 2.655 |
| Pointer-free | Before | 35 | 0 | 135.5 | 6.804 | 7.383 | 5.404 |
| Pointer-free | After | 35 | 0 | 135.5 | 4.177 | 4.337 | 2.407 |

With 100,000 nodes, automatic-pacing p99 improved from 5.844 → 4.069 ms for
references, 6.663 → 4.061 ms for null arrays, and 6.567 → 4.023 ms for pointer-free
payloads. Both versions completed 36 cycles without pressure fallback for each
payload, with equal median sampled heap peaks (91.5 / 87.5 / 83.5 MiB).

Explicit-only pacing still exposes the capacity tradeoff. With one requested
1 ms step per frame and 100,000 nodes, references improved p99 from 4.475 → 3.546
ms but completed fewer cycles (67 → 44), had more median pressure fallbacks
(1 → 2), increased sampled heap (311.5 → 327.5 MiB), and did not improve maximum
frames (21.255 → 22.179 ms). Null/pointer-free workloads had no fallbacks and lower
p99/max frames, with a small increase in sampled heap. Spreading reclamation cannot
make a too-small total collection allowance keep up with arbitrary allocation.

Validation: the complete integration suite and all 355 available bytecode fixtures
pass on both backends. A dedicated fixture pauses immediately after publication,
reuses fixed and variable candidate pages, keeps new fixed slots/TLAB reservations
and a finalizable target live, verifies reclamation over multiple slices and
zero-budget deferral, then verifies eventual exact-once finalization. It also
covers cancellation by explicit full GC and automatic pressure recovery with an
exhausted frame allowance. Native cases run hybrid/software-only backends, one/four
workers, and fast allocation enabled/disabled. An isolated negative build removing
the reused-page guard fails with exit 13 (a live fixed-slot page was unmapped);
the unsafe library was never installed as the runtime. The updated API program
passes native one/four-worker runs and both Wasm smoke runs. Independent-validator
automatic stress covers all four existing workloads with one/four workers on both
backends. Unsupported-platform, GC_DEBUG and GC_MEMCHK syntax checks pass. Actual
Apple/Windows runtime execution remains untested on this machine.
