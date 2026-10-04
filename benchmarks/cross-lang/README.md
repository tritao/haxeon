# Cross-language benchmarks

Runtime speed of Haxeon-compiled code against stock Haxe/HashLink, .NET and Dart,
on identical algorithms.

```sh
./benchmarks/cross-lang/run.py --test-only             # build + verify output only
./benchmarks/cross-lang/run.py --runs 10 --size 0      # time everything available
./benchmarks/cross-lang/run.py --langs haxeon,csharp --problems nbody
```

Results go to `out/cross-lang.json`. Languages: `haxeon` (`scripts/haxeon build`),
`haxe-hl` (pinned stock Haxe to HashLink), `csharp` (needs `dotnet` 9 SDK),
`dart` (needs `dart`, AOT `compile exe`). Missing toolchains are skipped.

Timed runs are pinned to one core with `taskset` (the first P-core on hybrid CPUs;
override with `--cpu N` or disable with `--no-pin`), which also makes the
multi-threaded C# variants single-threaded, matching the single-threaded Haxe.
The load average is printed and saved in the JSON, with a warning on a busy
machine: other builds running alongside skew timings, so compare runs only when
the load is low.

Method: each build is checked against the expected output, then one discarded
warmup run and `--runs` timed runs. Times are whole-process wall clock (startup
and JIT warmup included) with peak RSS; there is no in-process warmup yet.

Caveats: the C# `spectral-norm` and `fasta` variants are multi-threaded, so
compare them with that in mind; `size` indexes each problem's two input sizes.

## Results

Median of 9 whole-process runs (startup included), pinned to core 0, `--size 0` inputs, load average 3.96 at the start and 6.88 at the end on
20 CPUs (expect roughly ±5% noise). Seconds; peak RSS in MiB in parentheses.

| Problem (input) | Haxeon | Haxe/HL | C# (.NET 9) | Dart AOT |
|---|---|---|---|---|
| binarytrees (18) | 1.246 (95) | 1.235 (95) | 0.992 (93) | 0.636 (72) |
| nbody (5000000) | 0.231 (6) | 0.783 (7) | 0.182 (25) | 0.209 (7) |
| spectral-norm (2000) | 0.180 (7) | 0.269 (8) | 0.170 (27) | 0.132 (6) |
| fasta (2500000) | 0.474 (79) | 0.550 (79) | 0.403 (127) | 0.254 (9) |
| merkletrees (16) | 0.501 (79) | 0.506 (79) | 0.370 (76) | 0.267 (49) |
| lru (100 1000000) | 0.094 (8) | 0.100 (8) | 0.140 (27) | 0.119 (9) |

The spectral-norm and fasta Haxe sources were rewritten to match the C# and Dart variants (a local accumulator per row;
integer generator state, a plain array and a byte buffer per output line). Before that the Haxeon column read 0.359s and
0.831s, and stock Haxe 0.459s and 1.659s. Redirected stdout now buffers by default: fasta makes about 6,200 `write`
calls instead of 416,000, bringing Haxeon from the earlier 0.655s to about 0.502s and stock Haxe from 0.817s to 0.541s.
`HL_STDOUT_FLUSH=1` restores flushing after each print. The remaining gap includes a native call per generated character
and the quality of the JIT's loop code.

### Load/store forwarding

`HAXEON_LOADSTORE=0` disables block-local field/array reload forwarding independently of the inliner. A fresh comparison
with the same buffered-stdout runtime (nine runs, core 0, size 0) gives these medians in seconds:

| Problem | Forwarding off | Forwarding on |
|---|---:|---:|
| binarytrees | 1.192 | 1.189 |
| nbody | 0.251 | 0.248 |
| spectral-norm | 0.259 | 0.259 |
| fasta | 0.504 | 0.502 |
| merkletrees | 0.503 | 0.503 |
| lru | 0.090 | 0.090 |

The initial differences are small. Alternating nine on/off pairs on the same core confirmed nbody gains at both sizes:
forwarding was faster in all nine pairs at 5,000,000 steps and all nine at 20,000,000, with median paired improvements
of 3.3% and 4.1%. Fasta showed no repeatable gain (paired differences below 1%). No benchmark regressed beyond noise.
The larger fasta improvement in the main table comes from stdout buffering, which both sides of this A/B use.

The pre-pass post-inliner analysis predicted 9/53 loads removed in nbody (advance 4/23, energy 3/17, offsetMomentum 2/10)
and 2/15 in fasta (genRandom 1/2, randomFasta 1/3). The other totals were binarytrees 0/7, spectral-norm 2/9,
merkletrees 0/19 and lru 2/46. These static counts justified trying the pass; they were not a prediction of runtime gains.

### Exact division strength reduction

`HAXEON_STRENGTH=0` disables the post-inline rewrite of `x / 2^k` to `x * 2^-k`. The raw IEEE-754 bits must describe a
finite, nonzero normal power of two, and the reciprocal must also be normal and exactly representable. Constants on the
left and divisors such as 3 or 10 remain divides.

Nine alternating pairs on core 0 measured spectral-norm at 0.258599s with the pass off and 0.180365s with it on, a
30.3% improvement. Nbody measured 0.214460s and 0.215242s respectively, a 0.36% difference within noise. In
`App.eval_A`, disassembly changes the constant divide from `vdivsd` to `vmulsd`; the remaining data-dependent `vdivsd`
is unchanged.

Read the Haxe/HL column with care: both HashLink columns run on the same `.tools/hashlink` VM, which is the Haxeon
fork (thread-local allocation buffers, a 64 MB minimum collection trigger, cheaper allocation zeroing, `hl_dyn_castp`,
a `sqrtsd` intrinsic for `Math.sqrt`, constant operands as immediates and division or remainder by a constant as a
multiply). With stock HashLink 1.16 the stock-Haxe column was binarytrees 2.75,
nbody 0.79, spectral-norm 0.47, fasta 2.40, merkletrees 1.01 and lru 0.10. The larger collection trigger trades memory
for speed: binarytrees peaks at 95 MiB instead of 55. `HL_GC_MIN_TRIGGER=<bytes>` lowers it.

### Native properties, intrinsics and fused array reads

The fork now resolves declared non-returning native markers instead of recognizing a bounds helper by its address.
A signature-checked x86-64 intrinsic table handles sqrt, abs, floor and ceil (with a native fallback without SSE4.1).
Min/max and string operations stay native to preserve their edge-case behavior without branching expansions.
Int, Float and pointer array reads use fused checks and scaled loads through the existing `OGetArray` opcode;
growing writes keep their current path.

Nine alternating before/after pairs, core 0 and size 0, gave these Haxeon medians in seconds. The baseline uses the
existing forwarding pass and buffered stdout; it predates the intrinsic and fused-read changes. Load began at 3.93
and rose to 7.44, so the neutral rows should be read within the usual ±5% noise:

| Problem | Before | After | Change |
|---|---:|---:|---:|
| binarytrees | 1.200 | 1.220 | 1.7% slower |
| nbody | 0.257 | 0.229 | 10.9% faster |
| spectral-norm | 0.262 | 0.261 | 0.2% faster |
| fasta | 0.507 | 0.466 | 8.0% faster |
| merkletrees | 0.507 | 0.513 | 1.3% slower |
| lru | 0.093 | 0.091 | 2.9% faster |

C0 initially measured nbody at 0.252s → 0.217s (13.7%), passing the 8% gate; spectral-norm was neutral at 0.261s.
A later nine-run, three-way comparison at load 3.14–3.37 measured the same baseline at 0.242s, the retained prototype
at 0.216s, and production at 0.215s: production matches the prototype's gain under the same conditions (about 11%).
No other benchmark regressed beyond noise. Fasta improves by about 8% in the alternating comparison; this comes
from fused array reads, since string intrinsics were not added. The full four-language table above is a separate
nine-run measurement, starting at load 3.96; it also verifies every benchmark's output.

Validation passed with the inliner both on and off. Details, mutation evidence and the native audit are in
[`docs/JIT_NATIVE_PROPERTIES.md`](../../docs/JIT_NATIVE_PROPERTIES.md).

Haxeon's IR inliner is on by default (`HAXEON_INLINE=0` turns it off). It matters mostly for nbody (0.34s without it)
and spectral-norm (0.295s without it). The HashLink debugger shows inlined callee lines under the caller's frame and a
function breakpoint on a fully inlined function does not stop, so build with `HAXEON_INLINE=0` when debugging.

Where the time goes (`perf record` on HashLink, one core, measured before the inliner and JIT changes):

| Problem | JIT code | GC and allocation | Runtime natives | Notes |
|---|---|---|---|---|
| binarytrees, merkletrees | 13% | about 65% | 0% | mark 30%, allocation 20%; limited by cache misses, not instruction count |
| nbody, spectral-norm | 91-98% | 0-3% | 0-5% | IPC 3.8-4.6; the gap to C#/Dart is instruction count in the HL JIT, and for spectral-norm a loop-carried accumulator held in memory |
| fasta | 42% | 19% | 25% | `Float %`, `StringBuf.add`, `String.charAt`, `List` iteration |
| lru | 34% | 57% | 1% | HL's int-keyed hash map and its dynamic casts |

Haxeon is level with or ahead of stock Haxe on this VM on every problem (merkletrees and binarytrees are within 4% and
2%). The merkletrees gap used to be 10%: Haxeon typed `Null<Int>` as a plain dynamic, so every unbox called the runtime
cast, where stock Haxe reads the box inline. The IR now has a nullable primitive type that HashLink lowers to `HNull`.

## Haxeon compile status

`haxeon` builds and verifies `binarytrees/1`, `nbody/1`, `spectral-norm/1`,
`fasta/1`, `merkletrees/1` and `lru/1`. Not yet built: the alternate variants
that use `using` static extensions (`binarytrees/2`, `nbody/2`, `nbody/3`),
because static extensions are not implemented.

Haxeon deliberately differs from stock Haxe here, so the sources were adapted
(see `NOTICE.md`): value-returning functions and ordinary parameters need type
annotations (signatures are part of live-patch classification), and arithmetic
on a `Null<Int>` needs a null check.

### Small-allocation entry and zeroing

The x86-64 TLAB allocator now handles ready small-allocation slots through a thin entry and clears up to five
words with explicit stores. Special modes share the original full allocator's eligibility policy.
`HL_GC_ALLOC_FAST=0` restores the full entry and original zeroing loop. This changes the shared HashLink runtime;
no new cross-language comparison is implied.

Nine alternating pairs against a frozen unmodified library, identical bytecode, core 0, size-0 inputs and
one-minute load <=4 gave:

| Benchmark | Original (s) | Fast entry + clearing (s) | Improvement | Peak RSS change |
|---|---:|---:|---:|---:|
| binarytrees | 1.210434 | 1.097347 | +9.34% | +0.00% |
| merkletrees | 0.499628 | 0.451617 | +9.61% | +0.00% |
| nbody | 0.215978 | 0.216932 | -0.44% | +0.00% |
| fasta | 0.455936 | 0.451276 | +1.02% | +0.00% |
| spectral-norm | 0.181919 | 0.181254 | +0.37% | +0.00% |
| lru | 0.090623 | 0.089936 | +0.76% | +0.00% |

Both trees improved in all nine pairs. RSS was unchanged, and the sub-1% nbody difference is within noise.
Full validation and the rejected intermediate variants are recorded in
[GC_ALLOCATION_PROFILE.md](../../docs/GC_ALLOCATION_PROFILE.md).

### Short ASCII byte decoding

The native Bytes-to-String decoder now widens ASCII ranges of at most 128 bytes directly from a stack snapshot taken
before allocating the String. Unicode and larger ranges keep the existing decoder. `HL_TEXT_ASCII=0` restores the
original path. Nine alternating pairs on core 0 measured fasta at 0.454398s before and 0.438277s after (3.55% faster);
the other five benchmarks changed by −0.33% to +1.08%, within noise, with peak RSS level. The snapshot is required
because allocation callbacks and finalizers can mutate or invalidate the input.
See [the measurement and validation report](../../docs/FASTA_OUTPUT_PROFILE.md). The cross-language table above was
not regenerated.

### Bounded empty-page retention

The GC now keeps reusable empty pages up to a 64 MiB cap and four times the recent nonempty-page capacity,
aging out old peaks over four collections. It is enabled by default on Linux x86-64; `HL_GC_KEEP_EMPTY=0`
restores immediate release, and `HL_GC_EMPTY_BUDGET=<bytes>` changes the cap.

Nine alternating pairs on core 0, identical bytecode, load <=4, measured binarytrees at 1.082926 → 0.810813 s
(25.13% faster) and merkletrees at 0.448802 → 0.374593 s (16.53%). Their peak RSS was essentially unchanged.
The other benchmarks had no regression beyond noise. Reduced page release/refaulting corrects the earlier
cache-miss explanation. See [the full measurement and validation report](../../docs/GC_EMPTY_PAGE_RETENTION.md).
The cross-language table above was not regenerated.

### Guarded JIT object allocation (opt-in)

`HL_JIT_ALLOC_INLINE=1` enables guarded inline allocation of eligible objects up to 40 bytes on Linux x86-64 SysV.
Nine alternating pairs on core 0, identical bytecode and load <=4 measured binarytrees at 0.810601 → 0.574274 s
(29.15% faster) and merkletrees at 0.293442 → 0.248573 s (15.29%). Peak RSS was essentially unchanged and none of
the other four benchmarks regressed. The feature remains off by default; its per-site cold stubs increase code size.
See [the full report](../../docs/JIT_INLINE_ALLOCATION.md) for validation, startup limitations and all six results.
The cross-language table above was not regenerated.
