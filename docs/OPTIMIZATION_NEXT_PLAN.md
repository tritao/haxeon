# Next optimization work

Later measurements identify empty-page release/refaulting as a substantial tree-benchmark cost, superseding the
earlier cache-miss hypothesis. See [bounded empty-page retention](GC_EMPTY_PAGE_RETENTION.md) for the accepted
policy, timings and validation. The original experiments below remain historical evidence.

Status at `f4471151`. Medians of 9 pinned runs (seconds): binarytrees 1.21 (C# 0.99, Dart 0.64), merkletrees 0.50
(0.37, 0.27), fasta 0.47 (0.40, 0.25), nbody 0.215 (0.18, 0.21), spectral-norm 0.18 (0.17, 0.13), lru 0.09 (0.14, 0.12).
Do the stages in order. Each stage ends in a measurement gate; if the gate fails, record the result in the docs and
revert the code rather than keeping it.

## Standing rules

- Expected values come from stock Haxe/HL or its interpreter, never from our own output.
- Every rewrite has an environment switch (`HAXEON_*=0`) that is part of the action fingerprint, worker identity and
  inliner memo fingerprint, as `HAXEON_STRENGTH` is.
- Measure on core 0 (`taskset -c 0`), median of 9 alternating pairs, load average low, identical bytecode for A/B.
  Confirm with `perf stat` instructions/cycles and gdb disassembly of the JIT code.
- The self-hosted compiler must compile its own source: qualified static calls, typed empty array literals, null-check
  `Null<Int>`.
- Preserve mixed CRLF/LF line endings. Never `git stash`; never `git checkout <file>` over uncommitted work.
- Separate logical commits with the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Run `./scripts/format.sh`. Do not push the fork's `gc-min-trigger` branch.

## Stage 0: validate HEAD and fix the weak fixture

1. Rerun the full gate on HEAD: `tests/programs` sweep with the manifest, the driver (defaults and
   `HAXEON_INLINE=0 HAXEON_LOADSTORE=0 HAXEON_STRENGTH=0`), Wasm backend and parity, differential tests, self-hosting,
   GC fixtures x10 including `HL_GC_MIN_TRIGGER=65536`.
2. `tests/programs/float-div-pow2.hx` passes `divisor` and `reciprocal` as parameters. After inlining both are constants,
   so the rewrite turns the divide into a multiply and the fixture compares a multiply with a multiply. Make the
   divisors opaque (read them from an array filled at run time, or from a `@:noinline` function) so one side stays a
   real divide. Mutation-check it: change `exactNormalReciprocal` to accept 3.0 and the fixture must fail.
3. Commit the submodule bump if `git status` shows `M vendor/hashlink`.

Gate: all green, fixture fails under the mutation.

## Stage 1: IR opportunity census

Goal: decide which passes are worth building, with numbers. No behavior change.

1. Add a `HAXEON_IR_CENSUS=1` diagnostic (off by default, not fingerprinted because it does not alter output) that
   walks the final post-inline `IrFunction`s and prints per-function and total counts for:
   - array reads and writes, and how many are in a counted loop indexing by the induction variable up to the array's
     length (bounds check provably redundant);
   - loads of the same field or array element repeated without an intervening store or call (remaining after the
     load/store pass);
   - casts and boxed/unboxed conversions (`Nullable`, dynamic) inside loops;
   - allocations (`NewObject`, `NewArray`) that escape no further than the function, including those the scalar
     replacement did not remove and why;
   - loop-invariant pure computations (arithmetic, constant field loads) inside loops;
   - remaining `Div` and `Mod` by non-power-of-two constants.
2. Run it over all six benchmarks and write the table to `docs/IR_OPPORTUNITY_CENSUS.md` with the top five functions by
   dynamic weight (use loop depth as a proxy: weight `8^depth`).

Gate: the document ranks the candidate passes. Stages 2 and 3 proceed only for items whose weighted count is material.

## Stage 2: fused array writes

Reads were fused with the growth path out of line; writes still pay for the bounds and growth check inline.

1. In `HlLower` and the JIT (`jit_x86_64.c`, mirroring the fused `OGetArray` read), fuse `OSetArray` for typed arrays:
   in-bounds store inline, growth and out-of-bounds path out of line and shared.
2. Keep `jit_regs.c` unaware of the cold path other than as a returning call that is not in the hot loop.
3. Tests: fixtures covering in-bounds, growth by one, growth far past the end, negative index, `null` array, and element
   types F64, I32, bytes and pointer (pointer stores must keep the GC write semantics). Add a differential run of stock
   bytecode on our VM.
4. Measure fasta, nbody, spectral-norm, lru.

Gate: at least 3% on fasta or nbody with no regression above noise elsewhere; otherwise revert.

## Stage 3: bounds-check elimination for counted loops

Only if the Stage 1 census shows a material count.

1. Add `IrBoundsCheckElimination` after load/store forwarding. Recognize `for (i in a...b)` where the array is not
   reassigned or resized in the loop and `0 <= a`, `b <= a.length`, and mark the access unchecked.
2. Represent it explicitly in the IR (an unchecked array access flag), not as a JIT pattern. HlLower emits the raw
   access, Wasm lowering keeps its own checks unless proven safe the same way.
3. Document the dependency on the runtime array-cast checks in the pass, and add the missing comment in
   `IrLoadStoreForwarding` about that dependency.
4. Tests: loops that shrink or grow the array, aliasing through a second reference, a call that may resize it,
   exceptions out of the loop, empty arrays. Expected exit codes from stock Haxe.

Gate: at least 3% on a benchmark, zero fixture differences.

## Stage 4: GC and allocation locality (binarytrees, merkletrees)

This is the largest remaining gap and is cache-miss bound. Work in the fork (`vendor/hashlink`, `gc-min-trigger`).

1. Profile first. `perf stat` for cache misses and LLC misses on binarytrees and merkletrees; `perf record` split
   between allocation, mark and sweep. Record in `docs/GC_PROFILE.md`.
2. Candidate changes, each behind `HL_GC_*` environment switches until proven:
   - prefetch during mark for the next object popped from the mark stack;
   - skip the scan of blocks with no pointer fields;
   - allocate TLAB runs from address-ordered free runs so consecutive allocations are contiguous;
   - cheaper sweep for pages that are entirely free.
3. Tests: GC fixtures x20, `HL_GC_MIN_TRIGGER=65536`, thread fixtures, and the heap-corruption checks added with the
   32-bit free-list cursor fix.

Gate: at least 5% on binarytrees or merkletrees with no regression on the others, no change in peak RSS above 5%.

## Stage 5: small items

- `haxeon.json` setting to turn inlining off for debugging, so function breakpoints on inlined functions stop.
- Batch refreshes of `bootstrap/compiler.hl`; refresh the README results table after each stage that changes numbers.
- Known unrelated bugs: `StringBuf.add(null)`, the Wasm `String.fromCharCode` bug, mark `object-map-remove` skipped on
  Wasm.

## Not planned

A callee-saved float strategy for hot returning calls: SysV has no callee-saved XMM registers, and the register
allocator work showed no gain on the real benchmarks for that case.
