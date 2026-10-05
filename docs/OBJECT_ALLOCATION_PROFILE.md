# Fixed-size object allocation follow-up

This experiment follows the accepted allocation and ASCII decoding changes (main `8d9a4fa1`, fork `2f49c4d4`). No speed prototype passed; all experimental code and switches were removed. The gate is at least 5% on binarytrees or merkletrees, no regression beyond noise elsewhere, and peak RSS growth no greater than 5%.

## Updated profile

A separate library recompiles only gc.c with the release -O3 flags plus debug information. Four runs per benchmark sample cpu_core cycles at 1999 Hz with DWARF inline frames, on core 0. Benchmark output matches the unchanged runtime. No diagnostic counters or behavior changes are present in this library; these sampled runs are diagnostic, not timing evidence.

Categories are exclusive. Collection frames take precedence over allocation. Allocation includes work identified through allocator/inline frames; object setup counts resolved hl_alloc_obj / object-prototype leaf work. Unresolved JIT/native/kernel samples remain, so percentages are approximate workload attribution rather than precise instruction costs.

| Category | binarytrees | merkletrees |
|---|---:|---:|
| Allocation (excluding object setup and collection) | 49.76% | 58.43% |
| Object setup | 8.82% | 5.21% |
| Mark | 11.89% | 5.45% |
| Sweep / finalizers | 4.24% | 3.49% |
| Other / unresolved | 25.30% | 27.42% |

Core-cycle samples: 8,795 / 3,650. Object setup remains material: 8.82% / 5.21%. The original hl_alloc_obj entry saves four general registers for its initialization/binding paths, even for small nodes with no bindings.

## Prototypes

1. **Thin native entry.** A scratch gc.c separates the original initializer into a noinline fallback. Already initialized small HOBJ types without bindings allocate through the existing generic allocator and store their type header through a smaller entry. Runtime checks still read size and pointer-kind metadata. The prototype uses HL_GC_OBJECT_FAST=1 and reduces saved-register overhead, but adds eligibility checks on every allocation. It fails the timing gate.
2. **Direct JIT preparation, discarded before timing.** An initial probe created method tables during JIT emission, then called the allocator directly with known size/flags and stored the object type. This was incorrect: method tables can be initialized before function pointers are ready, leaving null virtual-call targets. A small tree run crashed. This probe is rejected and supplies no performance evidence.
3. **JIT-prepared helper.** The corrected probe resolves layout with hl_get_obj_rt, preserving lazy prototype initialization. Only x86-64, small HOBJ types without bound-method initialization are eligible. The JIT passes the known type, size and GC flags to a helper. That helper calls the original hl_alloc_obj until the method table is ready; subsequent allocations call the ordinary hl_gc_alloc_gen and store the type header. Structs, binding-bearing and larger objects retain the original initializer. HL_JIT_OBJECT_ALLOC=1 selects this scratch probe.

Both speed probes retain the existing allocator's zeroing, GC accounting, profiling, census and allocation callback paths. The JIT-prepared probe does not inline TLAB/collector policy or change object layout. Module type metadata includes fields, inheritance and bindings in the patch compatibility hash; method setup must still happen at runtime, independently of that layout information.

## Timing gates

Both speed probes use core 0, identical frozen bytecode, original unmodified runtime versus a frozen candidate, one output-checking warmup and nine alternating pairs per tree. Thin-entry candidates change only the library; prepared-helper candidates change the VM and library. One-minute load must be at most 4 before/after each sample; pairs crossing the threshold are discarded. Accepted observations reached at most 3.945. External load interrupted the prepared-helper run, and one accepted pair was noticeably slow on both sides despite remaining below load 4. Medians retain all accepted pairs; no sample was discarded based on its timing.

| Probe | Benchmark | Original seconds | Candidate seconds | Gain |
|---|---|---:|---:|---:|
| Thin native entry | binarytrees | 1.087736 | 1.100058 | -1.13% |
| Thin native entry | merkletrees | 0.450342 | 0.451988 | -0.37% |
| JIT-prepared helper | binarytrees | 1.102967 | 1.077692 | +2.29% |
| JIT-prepared helper | merkletrees | 0.450987 | 0.453526 | -0.56% |

Neither probe reaches 5% on either benchmark. Peak RSS stays level: approximately 97,108 KiB for binarytrees and 81,368 KiB for merkletrees, with median changes below 0.05%. The prepared helper reduces binarytrees instruction count appreciably, but that does not turn into the required wall-time improvement. All probes are discarded, including the helper/API and JIT metadata path. There is no fork commit or submodule bump.

Supporting single perf-stat runs for the prepared helper (cpu_core events; diagnostic, not acceptance timing):

| Benchmark / variant | Instructions | Cycles |
|---|---:|---:|
| binarytrees / original | 16,949,278,585 | 5,629,793,603 |
| binarytrees / prepared | 15,650,502,872 | 5,452,228,694 |
| merkletrees / original | 6,185,524,342 | 2,324,587,566 |
| merkletrees / prepared | 5,896,946,622 | 2,292,630,657 |

## Checks, skips and restoration

- All four profiling runs per tree match the unchanged runtime's output.
- Both speed probes' warmups match original output at the full acceptance inputs (18 / 16).
- The corrected prepared helper matches stock Haxe interpreter output for both tree programs at input 8. The initial incorrect direct probe is explicitly excluded.
- Six existing fixtures pass with HL_JIT_OBJECT_ALLOC=0 and =1: dynamic-method-call, bound-method, value-class-method, gc-controls, gc-collection-pacing and thread-gc-stress. These are targeted checks, not full validation; each ran once per mode.
- Native disassembly verifies the reduced entry frame and prepared helper; GDB confirms the JIT calls the helper for Node construction.
- Timing was explicitly suspended during additional stock-reference, targeted-fixture and perf-stat checks. No own builds or tests ran concurrently with accepted timing pairs.
- Scratch thin-entry source never modified the repository. Direct/prepared JIT changes were saved as rejected patches and restored byte for byte from clean-file backups. The fork is clean. Rebuilt VM, libhl and native HDLL SHA-256 hashes exactly match the original frozen runtime. After restoration, both tree outputs at input 8 still match the stock references.
- `./scripts/format.sh` and `git diff --check` ran before committing the report.

Full fixture/driver sweeps, mutation checks, repeated GC/thread stress, differential, self-hosting, Wasm parity, integration/DAP, the other four benchmark gates, startup/JIT latency acceptance, AArch64, 32-bit and Windows were not repeated: the first performance gates failed, and no implementation or fixture is retained. The accepted runtime's previous full validation remains recorded in GC_ALLOCATION_PROFILE.md and FASTA_OUTPUT_PROFILE.md.

Raw profiles, inline scripts, categories, runtime hashes, bytecode, original/candidate disassembly, rejected sources/patches, timing pairs, RSS/load observations and restoration logs remain under `out/object-allocation/`. `measure.json` records the thin-entry gate, and `jit-measure.json` records the corrected prepared helper; the direct probe crashed before producing timing results. The committed artifact is this report. The benchmark README remains unchanged because no speed change was accepted.
