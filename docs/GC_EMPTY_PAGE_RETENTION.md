# Bounded retention of empty GC pages

The accepted change avoids repeatedly unmapping and faulting in reusable GC pages. Binarytrees improves
from 1.082926 s to 0.810813 s (25.13%), and merkletrees from 0.448802 s to 0.374593 s (16.53%).
Both improve in all nine alternating pairs. Peak RSS is effectively unchanged. This supersedes the earlier
cache-miss explanation in `GC_PROFILE.md`: releasing and refaulting pages was a substantial cost, which also
explains why mark prefetching and address-ordered runs were flat.

## Policy

At a collection, `gc_flush_empty_pages` retains reusable, completely empty pages up to:

```
min(64 MiB, 4 * maximum nonempty-page capacity over the last four collections)
```

Nonempty-page capacity counts whole mappings, not exact live payload bytes. Cached empty pages do not contribute
to that peak, so the cache cannot sustain its own budget. Four quieter collections age out a previous working set.
Dedicated large-allocation pages are always released: the allocator cannot reuse them. Retained pages stay in the
existing page/free lists; excess pages use the original unmapping path.

The default is enabled on Linux x86-64 only. `HL_GC_KEEP_EMPTY=0` restores the original release policy;
`HL_GC_KEEP_EMPTY=1` enables retention explicitly on other platforms. `HL_GC_EMPTY_BUDGET` overrides the cap with
decimal bytes, from 0 through 1 GiB. Zero disables retention; malformed or out-of-range values use 64 MiB.
Options are read once, on the first empty-page sweep. No compiler fingerprint changes are needed because this
is a runtime policy and bytecode is unchanged.

This is a bounded cache, not immediate idle trimming: a process without further collections can retain up to the
cap. `madvise` and a young generation are separate future experiments. Keeping mapped pages affects the existing
mapped-capacity collection threshold as well as mapping/fault costs; the timing gain should not be attributed
exclusively to fewer syscalls.

## Zeroing and lifetime audit

The collector holds the global GC lock here, and stop-the-world collection has already invalidated thread-local
allocation buffers. Reuse goes through the ordinary free-list/TLAB refill paths. `flush_free_list` clears dead
variable-size metadata; finalizers clear their entries before sweeping. Both `gc_tlab_clear` and the full allocator
honor `MEM_ZERO`; raw pointer padding is cleared even without it. Existing allocation already reuses dirty blocks
inside nonempty pages, so payload initialization does not rely on fresh kernel pages.

`tests/native/gc_empty_pages.c` deliberately dirties pages on an independently registered thread, then joins it
before collecting, avoiding stale stack roots. With a 4 MiB cap it checks bounded mapped capacity, actual dirty-page
reuse, zeroing of sizes 1–40, pointer padding, exactly-once finalizers, and shedding of a previous heap peak.
The integration script runs retention off, on, and on with a zero cap. `GcEmptyPagesMain` includes it in the driver.
Mutation checks independently bypassed the cap, froze the recent peak and skipped TLAB zeroing; the guard failed
with exit codes 4, 9 and 7 respectively. Production code was restored and tested.

## Measurements

Frozen original and candidate libraries, identical bytecode and native HDLL, core 0, size-0 inputs, nine alternating
pairs. Every accepted sample had one-minute load average <=4 before and after execution. Crossing pairs were
discarded. No project build/test jobs overlapped acceptance timing. Whole-process medians include startup.

| Benchmark | Release empty pages (s) | Bounded retention (s) | Improvement | Median peak RSS off/on (MiB) |
|---|---:|---:|---:|---:|
| binarytrees (18) | 1.082926 | 0.810813 | 25.13% | 94.83 / 94.77 |
| merkletrees (16) | 0.448802 | 0.374593 | 16.53% | 79.46 / 79.55 |
| nbody (5000000) | 0.216135 | 0.215526 | 0.28% | 6.09 / 6.09 |
| fasta (2500000) | 0.433939 | 0.434363 | -0.10% | 79.22 / 79.22 |
| spectral-norm (2000) | 0.192204 | 0.181829 | 5.40% | 7.34 / 7.34 |
| lru (100 1000000) | 0.090270 | 0.091326 | -1.17% | 7.49 / 7.50 |

Nbody, fasta and LRU differences are within timing noise. Spectral-norm's median improvement is not consistent
across pairs (five improve, four regress slightly); it is not evidence of a GC benefit in that loop. The acceptance
result rests on the repeatable tree gains and absence of regression beyond noise. An earlier independent tree
run gave 1.084008 → 0.811718 and 0.449500 → 0.375031, confirming their results.

Diagnostic counters, collected separately with `perf stat` and `strace -c`:

| Counter | Binarytrees off/on | Merkletrees off/on |
|---|---:|---:|
| Software page faults | 394342 / 59909 | 203244 / 107674 |
| `munmap` calls | 3767 / 389 | 2562 / 970 |
| `mmap` calls | 3819 / 572 | 2614 / 1166 |
| Retired instructions | 17.052 G / 16.624 G | 6.230 G / 6.157 G |

These diagnostic runs had external contention; their elapsed, cycle and user-time values are not acceptance
measurements. Recorded kernel time fell from 0.38 s to 0.08 s for binarytrees and 0.26 s to 0.09 s for merkletrees.
The remaining instruction count is substantial. No new Dart or C# comparison was run.

The user's unlimited three-line experiment was backed up before replacement. Its installed library initially
contaminated a diagnostic baseline; that run was archived and excluded. Acceptance uses the original release
library (SHA-256 `91be19c444ed5d62f4c6af8f8ff5a522e533784e06325e08872d2daed43adbd7`).
The unlimited experiment's reported 0.77 s / 0.29 s is faster than this bounded policy; retaining all pages forever
was deliberately not made the default.

Local artifacts: `out/empty-page-retention/final-six.json`, `final-six.log`, `final-runtime-hashes.json`,
`measure.json`, counter/strace logs, `mutations.log`, and `validation.log` with individual suite logs.

## Commits

- HashLink fork: `f5a88a3f`, bounded page retention.
- Main repository: `7cde8097`, submodule bump and memory guards.

## Validation

All of these passed:

- HashLink fixture sweep: 325 fixtures with defaults and 325 with retention, allocation fast path, inlining,
  load/store forwarding and strength reduction disabled.
- Compiler/runtime driver: 475 tests in each of those two modes, including the new empty-page guard,
  array bounds, address-taken values and dynamic unboxing.
- `thread-gc-stress`, `gc-collection-pacing` and `gc-controls`: each ×20 at the default trigger and ×20 with
  `HL_GC_MIN_TRIGGER=65536`, in each mode (240 stress executions total).
- Differential tests, self-hosting to a fixed point, Wasm backend tests and Wasm GC parity (322 fixtures agree,
  14 existing skips).
- Workspace, compiler embedding, git package-lock and DAP inline-configuration integration tests.
- Native cap, decay and zeroing mutation checks.

Differential, self-hosting, Wasm and integration suites ran once with defaults, not twice. Other DAP suites,
AArch64, Windows, 32-bit and other platforms were not run. Retention remains opt-in outside Linux x86-64.
