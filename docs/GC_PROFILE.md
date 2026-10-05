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
