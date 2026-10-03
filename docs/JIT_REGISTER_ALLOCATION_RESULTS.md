# JIT register allocator results

## Decision

Phase 0 justified save-around-call allocation for conditional calls and register
allocation for low-pressure loop phis. Both are enabled by default on SysV
x86-64 as `HL_JIT_REGOPT=5`; `HL_JIT_REGOPT=0` restores the prior allocator.
AArch64, x86-32 and Windows retain the prior allocator.

Cold-exit weighting was dropped because no independent microbenchmark cleared
the 10% gate. Phi coalescing was dropped because the conservative prototype
removed almost no moves, while the broader prototype slowed two micros and
miscompiled the nested-loop probe. An unrestricted phi implementation also made
nbody 3.8% and merkletrees 2.6% slower. The retained implementation rejects hot
returning calls and register banks whose baseline peak liveness exceeds half the
available registers.

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

Two independent nine-pair A/B runs compared identical bytecode under masks 0
and 5. Values are the mask-5 change; positive is faster. The second run suffered
system-wide frequency variation, so paired ratios are reported rather than its
absolute times. No benchmark changed consistently beyond noise. Fasta emitted
identical code under both masks, confirming its observed variation is unrelated
to the allocator.

| Benchmark | Inline run 1 | Inline run 2 | No-inline run 1 | No-inline run 2 |
| --- | ---: | ---: | ---: | ---: |
| binarytrees | -0.03% | +0.13% | -0.07% | +0.49% |
| nbody | -0.59% | -0.59% | -0.41% | -0.11% |
| spectral-norm | -0.11% | +0.22% | +0.19% | +0.47% |
| fasta | -0.22% | +0.11% | -1.60% | -0.98% |
| merkletrees | +0.14% | +0.23% | -0.02% | -1.10% |
| lru | +0.29% | +3.19% | -0.15% | +3.65% |

The standard nine-run cross-language suite with the accepted default measured
spectral-norm at 0.258 s and nbody at 0.215 s. The other Haxeon medians were
binarytrees 1.194 s, fasta 0.467 s, merkletrees 0.491 s and lru 0.090 s. These do
not justify changing the published benchmark table.

Compiling the compiler from its own sources took 19.378 s with mask 0 and
19.453 s with mask 5, a 0.39% increase. A small compiler invocation took
0.223794 s and 0.233749 s respectively, a 4.45% increase, within the 5% startup
budget. The retained compiler-wide allocation counts are:

| Mask | Stack values | Loop stack phis | Phi moves | Code bytes |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 46,051 | 1,974 | 40,033 | 5,094,768 |
| 1 | 43,930 | 1,965 | 39,757 | 5,076,272 |
| 4 | 46,038 | 1,961 | 40,006 | 5,094,368 |
| 5 | 43,916 | 1,951 | 39,730 | 5,075,872 |

## Validation

The complete gate passed with masks 5 and 0, each with the inliner enabled and
disabled: 322 HashLink fixtures, 465 compiler/runtime driver tests, differential
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
