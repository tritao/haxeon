# Allocation census for bump-allocation Stage 3

The next measured target is 16-byte integer boxes, rather than arrays. Merkletrees creates one box per node;
Stage 1 only expands `ONew` object allocation and leaves these boxes on the native call path. The census also
shows substantial boxing in the compiler and lru, so their behavior and performance belong in the acceptance gate.

## Method

A scratch VM starts the existing exact per-type census immediately before running bytecode, and dumps before exit.
An allocation callback separately counts requested sizes and allocated bytes by runtime kind. The census includes
program initialization and execution, but excludes VM/module/JIT initialization before the bytecode entry point.
Call stacks are sampled with the census's jittered one-MiB byte interval. The size callback uses atomic counters.
No production source changes were needed for this instrumentation.

`HL_JIT_ALLOC_INLINE=1`, bounded retention and the 64 MiB cap were set. Census and callbacks deliberately force
ordinary allocator paths so every allocation is counted, including ones normally handled inline. Consequently,
these are allocation counts, not timings or direct measurements of fast-path hit rates. Separate uninstrumented
Stage 1 profiles below establish that boxing remains a runtime cost.

All six benchmark census outputs matched their uninstrumented outputs. Inputs were binarytrees 18, merkletrees 16,
nbody 5000000, fasta 2500000, spectral-norm 2000, and lru 100 / 1000000. The compiler was the stock-Haxe-built
`HaxeonCompiler`, compiling its own 461 source files to HashLink with the source list from the self-hosting script.
Its compilation completed successfully; instrumented compiler phase times are not performance evidence.

## Exact counts

| Workload | Total allocations | Integer boxes | Box count share | Array allocations |
|---|---:|---:|---:|---:|
| binarytrees | 68,332,307 | 0 | 0% | 2 |
| merkletrees | 29,971,907 | 14,985,902 | 50.00% | 2 |
| nbody | 31 | 0 | 0% | 5 |
| fasta | 1,666,706 | 0 | 0% | 18 |
| spectral-norm | 409 | 0 | 0% | 398 |
| lru | 97,359 | 97,098 | 99.73% | 2 |
| compiler | 157,033,514 | 15,372,371 | 9.79% | 32,256,676 |

Every counted `i32` allocation requested 16 bytes. Merkletrees additionally allocated 14,985,902 40-byte Nodes;
boxes account for about 28.57% of its allocated bytes, versus half its allocation count. This is allocation volume,
not live heap size. Binarytrees is almost entirely 24-byte Nodes, already addressed by Stage 1.

Fasta predominantly allocates byte buffers and Strings (833,343 and 833,342 respectively). Nbody allocates almost
nothing in its hot computation. Spectral-norm's arrays are relatively few and include varying sizes; its high array
percentage is not evidence of a large allocation bottleneck. The compiler's largest count categories are arrays
(20.54%), Strings (18.70%) and byte buffers (17.71%). Their variable sizes, native emit sites and initialization
semantics would need separate designs and measurements.

## Runtime evidence and decision

Four `perf record` runs of uninstrumented merkletrees with Stage 1 active captured 1977 samples attributed to the VM
process, including 708 stacks through `hl_alloc_dynamic` (35.81%) and 189 through ordinary object allocation.
These are inclusive sampled stacks, not independent costs to sum. They support testing a cheaper integer-box path;
they do not predict a 35.81% runtime saving.

Proceed with a separately switched, Linux x86-64 integer-box prototype that shares Stage 1's TLS, policy, clearing
and slow-call preservation machinery. Keep nullable/null semantics, type headers and all padding initialization.
Do not generalize to pointer-bearing boxes or arrays based solely on these counts. Acceptance requires at least
3% on merkletrees, no regression in all six benchmarks, and acceptable compiler time/memory and full validation.

## Evidence and scope

Scratch collector source/build scripts, exact JSON counts, requested-size CSVs, sampled stacks, output comparisons,
four uninstrumented profiles and the compiler result are under `out/allocation-census/`. `manifest.json` records
bytecode and compiler-output hashes. This census used the accepted Stage 1 fork revision `46705542`; the main
repository baseline was `9333bb65`. Profiling runs are not load-qualified acceptance timings.

This step does not validate a new runtime feature. AArch64, Windows, 32-bit and GC_DEBUG/memcheck were not profiled.
The compiler workload is one fresh compilation, not a long-lived worker memory-retention test.
