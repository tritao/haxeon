# Guarded integer boxing and the LRU layout regression

The integer-box prototype's LRU regression came from the library change, not the new VM or the boxing fast path.
Separating the new cold JIT helpers from ordinary runtime text removed it. The corrected prototype passed the full
correctness suites and the six-benchmark gate. Startup/JIT paired timing is complete; compiler self-compilation
timing is still pending. This report does
not yet mark Stage 3 accepted. The opt-in implementation is committed in fork `d7f0620a`; main-repository
commit `dc1a3985` bumps the submodule and adds the tests. Nothing was pushed.

## Diagnosis

The first prototype added descriptor preparation and refill helpers to `gc.c`. Even with boxing disabled, it shifted
later library functions. Grouping helpers at the end of that source kept allocator addresses stable but displaced
native map/cast code by 336 bytes. Profiles of LRU identified integer-map lookup, removal, insertion and dynamic
casts as its largest native hotspots. Their instructions had not changed, but their addresses and alignment had.

Nine alternating pairs per comparison, core 0, load <=4 before and after accepted samples:

| Controlled LRU comparison | Baseline (s) | Changed (s) | Improvement |
|---|---:|---:|---:|
| Library only, boxing disabled | 0.092988 | 0.095426 | -2.62% |
| VM only, boxing disabled | 0.092339 | 0.092217 | +0.13% |
| Ordinary cold annotation, library only | 0.091396 | 0.093363 | -2.15% |
| Separate cold section, library only | 0.091403 | 0.091209 | +0.21% |

The VM-only comparison used compatibility stubs for the new exports, with boxing disabled. Ordinary GCC `cold`
annotations place helpers before normal text and still moved hot functions. The separate `.hl_jit_cold` executable
section places the new helpers outside ordinary runtime text in this build. It restored the accepted allocator,
map and cast addresses. Lookup, removal and cast instruction bytes matched the accepted library exactly; insertion's
only remaining byte difference referenced a throw-path error string. No workload detection or function padding was
added. The code does not depend on these addresses for correctness.

Three separate diagnostic hardware-counter samples per library, on a ten-million-iteration LRU workload, executed
almost identical instruction counts. Median cycles rose about 1.6% with the displaced-code library, versus about
0.2% with the separate cold section. These were not load-qualified acceptance measurements. They support a code
placement effect but do not establish whether decode/uop-cache behavior or another CPU effect caused the slowdown.
We do not claim that L1 cache misses or branch misprediction were the proven cause.

## Optimization and safety

`HL_JIT_ALLOC_BOX=1` independently enables guarded allocation of unowned 16-byte `HI32` dynamic boxes on Linux
x86-64 SysV. It shares Stage 1's machine-code expansion and policy list, obtains space from the thread-local run,
initializes the header and padding, and stores the integer payload. Refill preserves live registers and enters a
safepoint before ordinary allocation. Debug mode, owned types, other primitive representations and unsupported
configurations use ordinary calls. Profiling callbacks, census, tracking and pending collection requests are checked
at execution time. No bytecode opcode, compiler IR, compile fingerprint or cross-function state was added.

Descriptor preparation and rare boxing refill are annotated as cold and placed in the separate ELF section on
Linux x86-64 GCC-compatible builds. Other configurations keep ordinary allocation. This isolates newly added cold
helper code from existing hot runtime text; it is not a promise of fixed addresses across arbitrary future builds.

The [census](ALLOCATION_CENSUS.md) found 14,985,902 integer boxes in merkletrees, 97,098 in LRU and 15,372,371 during
compiler self-compilation. The representation is general even though workloads spend different amounts of time
boxing. Arrays, float/pointer boxes and initialization-store elimination are outside this change.

## Corrected six-benchmark results

Nine alternating pairs, core 0, identical frozen bytecode, one-minute load <=4 before and after each accepted sample.
The accepted Stage 1 VM/library was compared with the corrected VM/library, with object allocation and bounded
empty-page retention enabled on both sides and the cap fixed at 64 MiB. Outputs matched; no task builds or tests
overlapped timing. Positive improvement denotes faster execution.

| Benchmark | Accepted Stage 1 (s) | Corrected boxing (s) | Improvement | Median peak RSS off / on (KiB) |
|---|---:|---:|---:|---:|
| binarytrees | 0.576401 | 0.574771 | +0.28% | 97116 / 97112 |
| merkletrees | 0.259076 | 0.207330 | +19.97% | 81760 / 81760 |
| nbody | 0.227339 | 0.224938 | +1.06% | 6240 / 6240 |
| fasta | 0.427961 | 0.426812 | +0.27% | 81120 / 81120 |
| spectral-norm | 0.184609 | 0.185452 | -0.46% | 7520 / 7520 |
| lru | 0.094389 | 0.093915 | +0.50% | 7840 / 7956 |

Merkletrees cleared its 3% gate. RSS was essentially unchanged, and no other benchmark regressed beyond noise.
The separate library-only LRU control and the full corrected runtime both removed the earlier repeated regression.

## Compiler, JIT latency and code size

Nine alternating startup pairs on core 0, load <=4 before/after accepted samples, are complete. Whole-process
trivial-input compilation medians were 0.229652 -> 0.231868 s (0.96% longer).
Initial-JIT process CPU medians were 205.064 -> 206.434 ms (0.67% longer).
These small differences are within normal timing variation. Bytecode outputs matched across all samples.

The scratch timer measures process CPU from `hl_jit_init` through `hl_jit_code`, separately from whole-process
compilation time; it is not part of the production patch. Paired full compiler self-compilation remains pending:
pairs crossing the load limit are discarded. No noisy samples substitute for that missing acceptance measurement.

The corrected VM executable is identical to the earlier prototype, so its recorded code-size counters are unchanged:
merkletrees JIT code 4336 -> 5312 bytes (+22.51%); compiler JIT code on the trivial-input workload 5,856,464 ->
6,191,840 bytes (+5.73%). These are code-size measurements, not compilation-time measurements. Hot-patch latency
has not been measured.

## Validation

The corrected source passed the following, with the box switch enabled/default compiler optimizations and disabled
with `HAXEON_INLINE=0 HAXEON_LOADSTORE=0 HAXEON_STRENGTH=0` where both modes are listed:

- Non-Wasm fixture sweep: 327/327 in both modes, including `jit-boxed-allocation`.
- Compiler/runtime driver: 479/479 in both modes, including the stock-Haxe-bytecode native boxing probe.
- GC controls, collection pacing and thread stress: each x20 in each mode, at both default trigger and
  `HL_GC_MIN_TRIGGER=65536`, totaling 240 stress executions.
- Differential suites in both modes; disabled differential also disabled inlining and load/store forwarding.
- Self-hosting to a fixed point in both modes.
- Wasm backend; Wasm GC parity: 324 fixtures agreed across HL/Wasm32/Wasm GC, 14 existing skips.
- Workspace, compiler embedding/incremental execution, Git package lock and DAP inline-configuration integration.

The behavioral fixture's reference came from stock Haxe's interpreter. The native probe uses stock Haxe bytecode
and checks integer limits, null, live integer/float/pointer values, dirty padding reuse, low-trigger GC, type-owner
eligibility, and callback/census/tracking changes after compilation. The isolated section variant also passed that
probe in both modes before the full corrected-source run.

The unchanged VM expansion previously passed isolated mutation checks for census, tracking, callback, padding,
bounds, type header and register reload; owner/type guard mutations also failed. These were restored. They were not
repeated for the section-only correction. Additional DAP stepping/scope comparisons on the earlier prototype
failed identically off/on (exit 5 / exit 1, missing loop variables), matching existing failures. Those additional
checks were not repeated here. Other DAP tests, AArch64, Windows, 32-bit, Clang and GC_DEBUG/memcheck are untested.

## Evidence

The earlier rejection remains documented in [JIT_BOXED_ALLOCATION.md](JIT_BOXED_ALLOCATION.md). Evidence for this
follow-up is under `out/boxed-allocation/`: `isolate-final.json`, `cold-lru.json`, diagnostic profiles/counters,
`cold-final-six.json`, `startup-jit.json`, `cold-validation.log`, suite logs, and `cold-final-hashes.json`. The final VM SHA-256 is
`de6d0ff23543079c99d5a3074d7911d755d0377fcfe8530ab49b2a01e2954b91`, its library is
`cb9a22ca1108ffbf2f533ed25f69347eb29059830c3d8d1d7381966fd9fbdf43`, and the unchanged native HDLL is
`aaa3e4576dd17bc0d7b491161a0937cb4969227b5d322115e70e19766ad3240f`.
