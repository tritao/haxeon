# Wasm GC scalar-lane word benchmark

Compile `tests/programs/struct-array-word-access.hx` with a control compiler and
the candidate, using `--target=wasm-gc --wasm-gc-allocation-count`,
`--entry=struct-array-word-access --root=tests/programs`, and exports for
`ArrayWordBench.prepare`, `ArrayWordBench.perform`, `ArrayWordBench.readRects`,
`ArrayWordBench.writeRects`, `ArrayWordBench.reverseRects`,
`ArrayWordBench.readTiny`, `ArrayWordBench.writeTiny` and `ArrayWordBench.reverseTiny`.
Repeat with `HAXEON_INLINE=0` and `HAXEON_INLINE=1`.

Run with Node supporting Wasm GC:

```sh
node tests/bench/value-array-words/run.mjs control.wasm candidate.wasm 4096 8 9
```

Preparation and three warmup calls are outside the measured windows. Each pair
alternates which build runs first, checks equal results and requires zero guest
allocations. JSON output includes every observation, medians, artifact hashes
and an observable checksum. Rect-like elements occupy four scalar words;
three-byte elements exercise packed lane offsets. The program fixture and
parity census also check the same operations on all targets, with and without
inlining. This benchmark measures engine code as well as generated code; keep
the Node version and machine fixed for each pair.
