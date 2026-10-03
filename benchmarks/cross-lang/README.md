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

Median of 9 whole-process runs (startup included), pinned to one core, `--size 0` inputs, load average about 4 on
20 CPUs (expect roughly ±5% noise). Seconds; peak RSS in MiB in parentheses.

| Problem (input) | Haxeon | Haxe/HL | C# (.NET 9) | Dart AOT |
|---|---|---|---|---|
| binarytrees (18) | 1.202 (95) | 1.182 (95) | 0.943 (93) | 0.585 (72) |
| nbody (5000000) | 0.255 (6) | 0.778 (7) | 0.178 (25) | 0.190 (6) |
| spectral-norm (2000) | 0.259 (7) | 0.263 (8) | 0.157 (27) | 0.131 (6) |
| fasta (2500000) | 0.655 (79) | 0.817 (79) | 0.407 (126) | 0.253 (9) |
| merkletrees (16) | 0.501 (79) | 0.480 (79) | 0.329 (76) | 0.263 (49) |
| lru (100 1000000) | 0.093 (8) | 0.097 (8) | 0.134 (27) | 0.108 (9) |

The spectral-norm and fasta Haxe sources were rewritten to match the C# and Dart variants (a local accumulator per row;
integer generator state, a plain array and a byte buffer per output line). Before that the Haxeon column read 0.359s and
0.831s, and stock Haxe 0.459s and 1.659s. A large part of the remaining fasta gap is output (about 0.2s): `Sys.println` flushes every
line, which is 416,000 `write` calls into the harness's pipe where C# and Dart write in 16 to 64 KB chunks. The rest
is a native call per generated character and the quality of the JIT's loop code.

Read the Haxe/HL column with care: both HashLink columns run on the same `.tools/hashlink` VM, which is the Haxeon
fork (thread-local allocation buffers, a 64 MB minimum collection trigger, cheaper allocation zeroing, `hl_dyn_castp`,
a `sqrtsd` intrinsic for `Math.sqrt`, constant operands as immediates and division or remainder by a constant as a
multiply). With stock HashLink 1.16 the stock-Haxe column was binarytrees 2.75,
nbody 0.79, spectral-norm 0.47, fasta 2.40, merkletrees 1.01 and lru 0.10. The larger collection trigger trades memory
for speed: binarytrees peaks at 95 MiB instead of 55. `HL_GC_MIN_TRIGGER=<bytes>` lowers it.

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
