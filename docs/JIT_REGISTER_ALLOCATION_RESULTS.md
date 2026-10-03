# JIT register allocator results

## Decision

Phase 0 justified save-around-call allocation for conditional calls and register
allocation for low-pressure loop phis. Register phis in functions without
returning calls are enabled by default on SysV x86-64 as `HL_JIT_REGOPT=4`;
`HL_JIT_REGOPT=0` restores the prior allocator. Call saving is available with
`HL_JIT_REGOPT=5`.
AArch64, x86-32 and Windows retain the prior allocator.

Cold-exit weighting was dropped because no independent microbenchmark cleared
the 10% gate. Phi coalescing was dropped because the conservative prototype
removed almost no moves, while the broader prototype slowed two micros and
miscompiled the nested-loop probe. An unrestricted phi implementation also made
nbody 3.8% and merkletrees 2.6% slower. The retained implementation rejects hot
returning calls and register banks whose baseline peak liveness exceeds half the
available registers. Save-around-call is limited to loop phis, the only measured
pattern that benefited.

## Microbenchmarks

These are medians of nine alternating pairs on CPU 0, with 300 million loop
iterations. Positive changes are faster. Stock Haxe Eval supplied the expected
results. GDB disassembly confirmed that the changed loops keep their accumulator
in XMM registers; the conditional-call case saves and restores it only on the
call path. The hot-call and seven-integer-pressure cases keep baseline code.

| Pattern | Baseline s | Mask 5 s | Change |
| --- | ---: | ---: | ---: |
| Float accumulator | 0.477782 | 0.240797 | +49.6% |
| Hot call each iteration | 0.478449 | 0.478256 | +0.0% |
| Conditional returning call | 0.480020 | 0.359492 | +25.1% |
| Seven live integers | 0.608758 | 0.610326 | -0.3% |
| Nested loops | 4.636254 | 2.193663 | +52.7% |
| Conditional phi update | 0.547308 | 0.244058 | +55.4% |

## Application measurements

The final nine-pair A/B run compared identical bytecode under masks 0 and 4.
Positive changes are faster. No benchmark changed beyond noise.

| Benchmark | Inline | No-inline |
| --- | ---: | ---: |
| binarytrees | +0.03% | -0.39% |
| nbody | +0.02% | +0.26% |
| spectral-norm | -0.12% | +0.25% |
| fasta | +0.25% | +0.55% |
| merkletrees | -0.05% | -0.10% |
| lru | -0.20% | +0.17% |

The final paired run measured the default at 0.261 s for spectral-norm and
0.215 s for nbody with inlining, and 0.258 s and 0.320 s respectively without
inlining. These results do not justify changing the published benchmark table.

Compiling the compiler from its own sources took 19.378 s with mask 0 and
19.453 s with mask 5, a 0.39% increase. The original mask-5 default made a small
compiler invocation 4.45% slower. Restricting call saves to loop phis did not
remove that analysis cost, and a lazy candidate scan measured 4.86%, so both
approaches were rejected as defaults. Across 90 alternating pairs, the final
mask-4 default measured 0.227759 s against 0.228339 s, a 0.25% difference.
The retained compiler-wide allocation counts are:

| Mask | Stack values | Loop stack phis | Phi moves | Code bytes |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 46,051 | 1,974 | 40,033 | 5,094,768 |
| 1 | 43,930 | 1,965 | 39,757 | 5,076,272 |
| 4 | 46,038 | 1,961 | 40,006 | 5,094,368 |
| 5 | 46,037 | 1,960 | 40,006 | 5,094,368 |

## Validation

The complete gate passed with the default mask 4 and both inliner modes. Earlier
complete gates passed with masks 5 and 0, also in both inliner modes. Each gate
included 322 HashLink fixtures, 465 compiler/runtime driver tests, differential
tests, fixed-point self-hosting, workspace, compiler-embedding and git-package
integration tests, the Wasm backend suite, and Wasm GC parity (319 programs, 14
existing skips). The three GC/thread fixtures ran 20 times each plus once with
`HL_GC_MIN_TRIGGER=65536`, for 126 runs per allocator mask.

The tracked-loop DAP probe showed correct values for all iterations under both
masks. `test-dap-stepping.sh` and `test-dap-scopes.sh` retain their pre-existing
failures: the former stops at a different source line and the latter exposes
`after` too early. Neither failure changes with masks 0, 1 or 5.

Mutation VMs that omitted a call save or reload made the direct-call fixture
return 4 instead of 42. Shortening phi liveness to the header made the phi
fixture fail, including the old floating value used after its update. A forced
64 KiB GC floor compiled successfully while diagnostics counted 1,904 pointer
saves.

AArch64, x86-32 and Windows were not run; the backend configuration leaves the
new stages disabled there. No remote branches were pushed.
