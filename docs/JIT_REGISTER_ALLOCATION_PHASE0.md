# Register allocator Phase 0

Static baseline counts; `HL_JIT_REGSTATS=2`, default allocator, stock-Haxe-built seed compiler.
Counters are compile-time observations, not runtime instruction counts. Diagnostic workload timings were collected during other work and are not acceptance timings.

| Workload | Inliner | Instructions | Stack values | Loop stack phis | Phi moves | Code bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| binarytrees | 1 | 678 | 12 | 3 | 24 | 2704 |
| nbody | 1 | 1350 | 20 | 9 | 49 | 5664 |
| spectral-norm | 1 | 1099 | 19 | 8 | 45 | 4144 |
| fasta | 1 | 1226 | 43 | 5 | 41 | 5440 |
| merkletrees | 1 | 821 | 17 | 3 | 29 | 3184 |
| lru | 1 | 949 | 19 | 4 | 27 | 3776 |
| compiler-self | 1 | 865405 | 46051 | 1974 | 40033 | 5094768 |
| binarytrees | 0 | 664 | 12 | 3 | 24 | 2608 |
| nbody | 0 | 1332 | 33 | 11 | 53 | 5792 |
| spectral-norm | 0 | 1063 | 20 | 7 | 45 | 3968 |
| fasta | 0 | 1191 | 43 | 5 | 41 | 5136 |
| merkletrees | 0 | 805 | 17 | 3 | 29 | 3072 |
| lru | 0 | 921 | 16 | 4 | 27 | 3584 |
| compiler-self | 0 | 865405 | 46051 | 1974 | 40033 | 5094768 |

The seed compiler bytecode is built by stock Haxe, so its own JIT counters are the same in both inliner modes; the option changes the compiler it produces.

## Scratch prototype gate (preliminary)

Nine alternating pairs, CPU 0, 300,000,000 iterations, identical Haxeon bytecode with inlining disabled. These exploratory pairs ran at load above 4; controlled acceptance pairs must repeat them.

| Pattern | Baseline seconds | Phi prototype seconds | Change |
| --- | ---: | ---: | ---: |
| baseline | 0.492498 | 0.255253 | 48.2% faster |
| hot | 0.491375 | 0.496935 | -1.1% faster |
| cold | 0.502601 | 0.506632 | -0.8% faster |
| pressure | 0.622261 | 0.684425 | -10.0% faster |
| nested | 4.829154 | 2.265712 | 53.1% faster |
| conditional | 1.169464 | 0.700307 | 40.1% faster |

The first stock-Haxe/inlined trials did not establish a valid prototype comparison: the pre-existing switch disappeared before rebuild, and Haxeon inlined the purported hot call. They are excluded. Controlled prototypes use backend flags and `HAXEON_INLINE=0`; disassembly confirms a real call.

Phi pinning alone improves the no-call accumulator, nested loops and conditional updates by over 10%, but does not improve call-crossing floats. A naive save-around-call prototype slows the hot call by 11.1% and improves the cold call by 36.6%. The initial weighted cost model rejected the hot micro case and retained 37.0% on the cold case, but failed the real nbody workload with inlining off (0.32048s to 0.45366s, 41.6% slower). It was rejected. The revised candidate excludes values crossing mandatory returning calls in loops; exploratory nbody pairs returned to baseline and the cold case improved 23.9% (0.48777s to 0.37108s). This narrower gap is the call-saving gate carried into controlled acceptance. The cold-call benefit requires register phis (bit 4) together with call saving (bit 1).

## Stage decisions

- Stage 1: proceed to validation, with weighted reads/definition stores versus weighted save/reload pairs. Prefer existing callee-saved locations; address-taken values retain stack locations; functions containing try/catch conservatively retain the old call policy.
- Stage 2: no independent 10% opportunity demonstrated. The rare branch returns to the loop, so it does not meet the proposed cannot-reach-backedge heuristic. Do not implement without evidence.
- Stage 3: proceed to validation; retain pinning and existing debug liveness in debugger mode.
- Stage 4: dropped. A conservative scratch prototype removed almost no moves and demonstrated no 10% gain. A broader CFG-based prototype slowed baseline/hot micros and crashed the nested case. Neither prototype is published.

## Debugger baseline

- `test-dap-scopes.sh`: existing failure, local `after` is visible too early.
- `test-dap-stepping.sh`: initial run blocked by stale haxelib repository configuration. Repeat baseline with `HAXELIB_PATH=$PWD/.tools/haxelib-repo` to compare actual behavior.

Raw diagnostic logs and scratch prototypes live under ignored `out/regalloc/`.

## Correctness probes

The stock Haxe Eval oracle gives 1981.5 for both direct and indirect call-save
accumulation, 420 for the opaque seven-object root checksum, and 42 for the
complete fixture. The phi fixture checks conditional updates (1.5), an old value
still read after an update (92), an early exit (3), and nested loops (46).

Scratch mutation VMs that omit the store or reload both make the direct-call
fixture return 4 instead of 42 with inlining off. Shortening a phi's own-loop
extent to its header makes the phi fixture return 2 and
`loop-live-across-calls` return 1 instead of 42. Production sources were never
mutated for these probes. A diagnostic VM confirms 1,904 emitted pointer saves
while compiling a fixture with `HL_GC_MIN_TRIGGER=65536`; compilation succeeds.

The original GC pacing fixture's fixed 60-collection bound fails at the requested
64 KiB floor in the baseline too. Its committed correction derives the bound
from the explicitly configured floor and allocation volume; live-object and
allocated-byte checks remain intact.

## Rejected broad candidate: compiler allocation counts by mask

The stock-built compiler compiles a small input; all 4,942 seed functions are
JIT-compiled, so the instruction total is 865,405 in every row.

| Mask | Stack values | Loop stack phis | Phi moves | Code bytes |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 46051 | 1974 | 40033 | 5094768 |
| 1 | 43930 | 1965 | 39757 | 5076272 |
| 4 | 37891 | 1781 | 27882 | 4913792 |
| 5 | 35791 | 1667 | 27449 | 4891600 |

The retained candidate conserves phi pinning across mandatory loop calls; the
unrestricted version's integer-pressure micro was 5.2% slower and was discarded.

## Micro allocation and disassembly (before the headroom guard)

Counts below are per micro function. The emit-IR instruction count is unchanged;
stack values, edge moves and encoded size can change during allocation.

| Pattern | Emit instructions | Stack values 0 / 5 | Loop stack phis 0 / 5 | Phi moves 0 / 5 | Bytes 0 / 5 |
| --- | ---: | ---: | ---: | ---: | ---: |
| baseline | 37 | 1 / 0 | 1 / 0 | 3 / 2 | 96 / 80 |
| hot | 38 | 1 / 1 | 1 / 1 | 4 / 4 | 128 / 128 |
| cold | 56 | 1 / 0 | 1 / 0 | 4 / 3 | 176 / 176 |
| pressure | 89 | 7 / 7 | 7 / 7 | 16 / 16 | 288 / 288 |
| nested | 63 | 2 / 0 | 2 / 0 | 6 / 4 | 160 / 128 |
| conditional | 49 | 1 / 0 | 1 / 0 | 3 / 2 | 112 / 96 |

GDB stops at `__jit_debug_register_code`, finishes registration, then disassembles
`RegallocBench.<pattern>` before executing it. The baseline accumulator uses a
stack load/store dependency each iteration; mask 5 uses XMM values and an edge
move. The hot-call accumulator remains in a stack slot. The cold case stores its
XMM accumulator before the call and reloads after it only on the conditional
path. Seven integer phis in the pressure case retain the baseline stack policy.
Nested-loop accumulators and conditional updates use registers; existing edge
moves remain, so this does not claim ideal move-free code.

## Macro rejection and final scope

The broad phi candidate passed correctness but failed performance: inlining-on
nbody was 3.84% slower in the median paired ratio (all nine pairs slower by
3.67–4.09%), and merkletrees was 2.57% slower (all nine pairs slower). Isolating
bits 1 and 4 identified phi allocation/liveness, rather than call saving, as the
cause. Restricting the change to floats fixed merkletrees but still slowed nbody;
that scratch variant was also rejected.

The retained design selects each register bank only with substantial headroom:
baseline peak live intervals must fit in half the available bank. Nbody's floating
peak was 13 of 15 registers, and merkletrees' general peak was 13 of 13; both keep
their baseline policy. Winning micros peak at three or four floating values.
Banks accepted by the guard recompute own-loop liveness; rejected banks preserve
baseline liveness exactly. Try/catch and debugger functions keep the old policy.

See `JIT_REGISTER_ALLOCATION_RESULTS.md` for controlled final timings and the
complete validation record. Broad prototype counts above are not claimed as
counts of the retained implementation.
