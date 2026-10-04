# Stage 2: redundant initialization experiment

Stage 2 of [the bump allocation plan](BUMP_ALLOCATION_PLAN.md) was measured and dropped. A small local JIT proof
removed redundant leaf-node clearing, but did not clear the required 2% binarytrees gate. The accepted Stage 1
implementation is unchanged. There is no new committed runtime switch, bytecode opcode or compiler change.

## Opportunity and scratch implementation

The post-inliner binarytrees bytecode has two allocation sites in `App.make`:

- Leaf: `ONew`, two null constants, then stores to both pointer fields. These stores completely cover the payload
  before any potentially observing operation.
- Internal node: `ONew`, two recursive calls, then stores to the pointer fields. The calls are barriers, so both
  fields must keep their default initialization.

A scratch `HL_JIT_ALLOC_INIT=1` switch enabled a local bytecode scan, independently of the existing
`HL_JIT_ALLOC_INLINE=1`. It permitted constants and unrelated register moves, stopped at aliases/overwrites,
incoming control-flow edges, reads, calls, allocations, traps, publication or unknown instructions, and collected
field-store byte coverage. Only complete eight-byte words could omit clearing; uncovered bytes and padding retained
their initialization. Packed/struct fields were excluded. Ordinary slow allocation still initialized everything.
This was an experimental screening implementation, not a fully validated proof.

The emitted code confirmed the intended difference: leaf allocation lost two payload-zero stores and their two
zero-immediate loads, while the subsequent field stores and internal-node clearing remained. Total binarytrees JIT
code size fell from 3792 to 3760 bytes. The JIT instruction/value/phi counters were unchanged, since the change was
inside the allocation operation's machine-code expansion.

This scope cannot remove internal-node clearing: recursive allocation can collect, throw or call code before the
parent's fields are assigned. Expanding that scope would require a different initialization/observability proof.

## Performance gate

Nine alternating off/on pairs per tree, pinned to core 0, identical frozen bytecode and runtime artifacts;
one-minute load was at most 4 before and after every accepted sample. Stage 1, bounded empty-page retention and the
64 MiB retention cap were enabled on both sides. No builds or other task validation overlapped these timings.
Benchmark output matched before timing.

| Benchmark | Full initialization (s) | Scratch proof enabled (s) | Improvement | Median peak RSS off / on (KiB) |
|---|---:|---:|---:|---:|
| binarytrees | 0.583091 | 0.592832 | -1.67% | 97112 / 97112 |
| merkletrees | 0.247078 | 0.246234 | +0.34% | 81760 / 81760 |

Binarytrees improved in only two of nine pairs. The measured result fails the 2% gate; it does not justify keeping
the feature. The small merkletrees difference is within noise. RSS was level.

Separate single `perf stat` diagnostic runs measured binarytrees at 11.907 G → 11.770 G retired instructions
(-1.15%), 2.913 G → 3.004 G cycles, and 24121 → 24123 page faults. Removing instructions did not yield a runtime
benefit in the paired gate. These single counters do not establish the cause of the timing difference; code layout
and execution effects remain possible explanations, not demonstrated conclusions.

## Checks and disposition

Completed: bytecode opportunity census, output comparison for both tree benchmarks, nine paired timings for each,
GDB disassembly of `App.make`, JIT code-size counters and separate hardware counters. The existing native dirty-page,
default-value, padding and runtime-hook probe passed with the prototype enabled; it is a screening check, not a full
Stage 2 correctness suite.

Not run for this rejected stage: the remaining four benchmark timings, full fixture/driver sweeps, differential,
self-hosting, Wasm parity, repeated GC/thread stress, full integration/DAP checks, dedicated proof-guard fixtures and
mutation tests, startup/JIT-only latency or hot-patch timings, and unsupported architectures/build configurations.
The failed performance gate made those acceptance checks unnecessary; no claim of a validated Stage 2 is made.

All prototype source changes were removed. The restored VM/library match the accepted Stage 1 artifacts byte-for-byte,
and the native allocation probe passed again. No fork commit or submodule bump is needed. The experiment and results
remain as documentation, with local evidence in `out/alloc-init/` (`gate.json`, `gate.log`, census logs,
`make-{0,1}.asm`, `stat-{0,1}.log`, `regstats-{0,1}.log`, `rejected-prototype.patch`, and `hashes.json`).

Benchmark bytecode SHA-256: binarytrees `77a9eeb4375d6ec7b341ac7be7fa4ec38b55c28c9e2e53ae6929df920ac25ff4`,
merkletrees `c5a5e28667a65b027791306aafa9e6574af17f97cdb1f2c88024fd6008f93a02`.
