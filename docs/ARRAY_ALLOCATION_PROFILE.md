# Array allocation census and the inline-allocation decision

The measured decision is **not to add a small-array JIT fast path in this iteration**. The compiler creates many
small arrays, but the existing TLAB already handles their ready-run allocations. Profiles put less than 1% of
compiler CPU samples in the directly removable allocation-entry/call work. Most small-array allocation samples
are refill, free-list and synchronization work, which a guarded inline path would still perform.

This is a profiling decision, not a failed implementation or an A/B result. No production allocator, JIT,
compiler, switch or bytecode changes were made. Arrays remain a candidate for future refill/allocator work; this
report does not reject every possible array optimization.

## Correcting the earlier count

The broad [allocation census](ALLOCATION_CENSUS.md) counted **GC blocks**, not array objects. `hl_alloc_array`
allocates a 32-byte header and separate element storage with its own type word. Growth can allocate another
backing block. Thus 32.3 million compiler array GC blocks represent about 16.1 million created arrays.

The header preserves identity when storage grows. Initial capacity is four for lengths 0–3, otherwise
`length + length / 2`. With eight-byte elements, lengths 0–3 use a 40-byte backing block and fit today's fixed
TLAB classes; length 4 uses 56 bytes and goes beyond the 40-byte limit. Calling all arrays of length <=4 equally
eligible would overstate the existing small-allocation mechanism's reach.

## Census method

A scratch shared library instruments successful array creation requests and backing-storage growth in a copy of
`src/std/array.c`. It records element runtime kind, length, capacity, ownership and requested bytes. Lengths 0–64
are exact; larger lengths are grouped into 65–256, 257–1024, 1025–4096, 4097–16384 and >16384. Count, length sum,
capacity sum and requested bytes remain exact within each bucket. Runtime kinds group concrete classes together;
Object does not distinguish String from other object classes. No callback or general GC census is enabled, so
ordinary object/box fast paths remain eligible. The instrumentation uses a mutex and is not used for timings.

The production source and tool installation are untouched. The instrumented library links the existing release
objects except its copied array implementation. It includes initialization and execution, not just hot loops.
`HL_JIT_ALLOC_INLINE=1 HL_JIT_ALLOC_BOX=1`, bounded retention and the 64 MiB cap are set. A production run and
census run have identical output for all six benchmarks. Compiler runs use the same output path and produce
identical bytecode SHA-256 hashes. All workload runs succeeded, so these request counts are completed allocations.

The compiler is stock-Haxe-built `HaxeonCompiler`, compiling its own 461-source-file list with roots `src` and
`stdlib`. This measures the runtime on substantial compiler code, not a self-hosted compiler or a persistent worker.

## All-workload counts

| Workload/input | Created arrays | Growth backing blocks | Array GC blocks | Created at length 0–3 | Requested bytes |
|---|---:|---:|---:|---:|---:|
| binarytrees / 18 | 1 | 0 | 2 | 1 | 72 |
| merkletrees / 16 | 1 | 0 | 2 | 1 | 72 |
| nbody / 5000000 | 2 | 1 | 5 | 2 | 200 |
| fasta / 2500000 | 7 | 4 | 18 | 3 | 1,120 |
| spectral-norm / 2000 | 23 | 352 | 398 | 23 | 1,269,912 |
| lru / 100, 1000000 | 1 | 0 | 2 | 1 | 72 |
| compiler / 461 sources | 16,128,362 | 0 | 32,256,724 | 13,753,982 | 1,596,600,860 |

Requested bytes sum header and storage requests, including repeated growth, rather than live heap size, rounded
allocator bytes or peak RSS. No counted backing allocation had an element-type owner. The compiler's stock Haxe
array implementation grows by creating replacement arrays, so these are counted as creates rather than calls to
`hl_array_reserve`. The prior broad census excluded pre-bytecode initialization and used an earlier source snapshot;
its compiler GC-block total was 32,256,676, versus 32,256,724 here. That small difference does not change the conclusion.

The tree benchmarks and LRU create only the argument array in this runtime. Spectral-norm grows its arrays during
initialization; there is no array allocation in its hot numerical loop. These workloads cannot establish a meaningful
small-array allocation speedup. Compiler workloads are the appropriate target and gate.

## Compiler distribution

| Initial length | Created arrays | Share |
|---|---:|---:|
| 0 | 6,489,003 | 40.23% |
| 1 | 3,994,496 | 24.77% |
| 2 | 2,213,511 | 13.72% |
| 3 | 1,056,972 | 6.55% |
| 4 | 697,096 | 4.32% |
| >=5 | 1,677,284 | 10.40% |

Lengths 0–3 account for 13,753,982 arrays (85.28%) and 990,150,976 requested bytes. Lengths <=4 account for
14,451,078 arrays (89.60%); the length-4 distinction matters for the fixed 40-byte classes.

| Element runtime kind | Created arrays | Share |
|---|---:|---:|
| Dynamic (HDYN) | 7,166,317 | 44.43% |
| Object (HOBJ) | 3,587,354 | 22.24% |
| Enum (HENUM) | 2,038,648 | 12.64% |
| Bytes (HBYTES) | 1,997,722 | 12.39% |
| Virtual (HVIRTUAL) | 1,328,112 | 8.23% |
| Int (HI32) | 8,951 | 0.06% |
| Function (HFUN) | 1,252 | 0.01% |
| Type (HTYPE) | 6 | 0.00% |

## CPU profiles and go/no-go

Two production compiler profiles and three LRU profiles used `perf record -F 999 -g --call-graph dwarf`, pinned
to core 0, with allocation switches enabled and no census. They are diagnostic CPU-sample measurements under
external load, not load-qualified wall-clock timings. Inclusive samples are samples with the named function anywhere
in the captured stack. Missing JIT symbols/unwinding and sampling variability limit their precision.

The pooled compiler profiles contain 39,189 samples: 2,111 (5.39%)
include `hl_alloc_array`, while 17,598 (44.91%) have `gc_flush_mark` as the leaf.
LRU has no array-allocation frames in 2,706 pooled samples.

A second scratch library routes calls to two identical, no-inline copies of the original allocator: eligible
lengths 0–3 with unowned element types of size <=8, and other requests. Allocation semantics are unchanged.
GCC identical-code folding is disabled for this diagnostic object (`-fno-ipa-icf`); `nm` confirms distinct function
addresses. Two profiles isolate the groups, and both compiler outputs match the production bytecode hash.
This adds a dispatch/type-size check, so its percentages are diagnostic rather than an exact decomposition of the
production timings. The first folded-clone run was discarded and is not included in the results.

| Profile group | Samples | Share of compiler samples |
|---|---:|---:|
| Small arrays, inclusive | 1,082 | 2.89% |
| Other arrays, inclusive | 998 | 2.66% |

There are 37,499 samples in the split profiles. Within small-array stacks, `hl_gc_alloc_gen_owner` has
223 leaf samples (0.59% of all samples), and the small allocator itself has 76 (0.20%). Wrapper, type-query and PLT
leaves add only a small amount. Refill/free-list/lock leaves account for most of the remaining small-array samples.

A JIT expansion would still initialize both blocks, preserve roots across refill, execute runtime policy guards,
and use the existing refill machinery. It cannot remove the whole ~2.9% inclusive small-array cost. The likely
saving in this workload is below 1%; that is an estimate, not a measured speedup or a strict upper bound. Call-site
register residence could change too, but these profiles do not establish a worthwhile gain from that effect.
Against that headroom, a two-allocation expansion introduces more per-site code and must keep the first block
rooted if the second allocation takes a safepoint. This does not justify implementation and the full validation cost
at present. We stop after the census; no optimization is accepted or enabled from this work.

The stronger next profiling target is compiler GC marking and refill/free-list work. A larger fixed/TLAB class or
allocation layout change is a separate experiment: neither was implemented or measured here.

## Coverage, skips and evidence

Completed: all six census/production output comparisons; compiler census/production bytecode comparison; two
production compiler profiles, two split compiler profiles and three LRU profiles; bytecode-hash checks for both
repeat profiles and both split profiles; distinct-symbol verification for the split diagnostic.

There is no new runtime behavior, so fixture sweep, driver, differential, self-hosting fixed point, GC/thread stress,
Wasm parity, DAP, mutation tests, paired runtime/startup timing and architecture validation were not rerun for this
profiling-only change. AArch64, Windows, 32-bit and Clang were not profiled. The earlier integer-box compiler/startup
acceptance timing remains pending under its separate load gate; these loaded profiles do not substitute for it.

Scratch sources/build runners, CSVs, compiler outputs, manifests, raw perf data/scripts and summaries are under
`out/array-allocation/`. The production baseline is main `8cb8c632`, fork `d7f0620a`; neither production source nor
installed library was modified. Census source SHA-256 is
`2e3c8ec0d99be69fd748a215776942c1bd9300e1b5fff038a3890ae70b41a586`. Compiler input bytecode SHA-256 is
`6315b26a92a7ff700650c021357c9acbdc8ec4010509655453b5856a57f7a3a2`; output SHA-256 is
`975ea9291b0e380cd92620fb1ded6bfc91ca4b7251c247c00da5693ade6f2454`. The source-list SHA-256 is
`c2e78c0fc457f328746f2f73ac7a6bfe167e7b10ba258c073841b952c1674f76`. Instrumentation timings are not benchmark results.

## Follow-up

[Compiler GC marking and refill experiments](COMPILER_GC_MARKING.md) investigate the larger profile costs.
The candidate reuses non-atomic bitmap updates for configured one-worker marking, behind `HL_GC_MARK_SERIAL=1`.
Correctness validation passed; load-qualified performance acceptance remains pending. Multi-worker marking stays atomic.
