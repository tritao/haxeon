# Allocation microbenchmarks

`AllocationBench.hx`, `allocation.dart` and `Allocation.cs` allocate objects with one, two or four double fields.
On HashLink, including the type header, these are 16, 24 and 40 bytes. Other runtimes have different layouts;
these labels describe the HashLink size, not equal allocated bytes across languages.

Pass the size label and iteration count, for example `24 5000000`. A 256-entry typed ring keeps allocations
escaping to heap memory; the checksum consumes the objects. This includes initialization, ring stores, reads,
loop work and GC, so ns/iteration is not isolated allocator latency. Verify actual allocation instructions in
optimized code before comparing. The programs are benchmarks, not normal test-suite fixtures.

Compile Haxeon with the usual compiler CLI, entry `AllocationBench`, root `tests/bench/bump-allocation`.
For the independent reference:

```sh
.tools/haxe/haxe -cp tests/bench/bump-allocation --run AllocationBench 24 1000
.tools/dart-sdk/bin/dart compile exe tests/bench/bump-allocation/allocation.dart -o /tmp/allocation-dart
/tmp/allocation-dart 24 1000
```

Use a Release net9.0 executable project containing `Allocation.cs` for C#. All three sizes give 722604 at
1000 iterations, as checked against the stock Haxe interpreter. Use nine alternating language-order runs,
core 0, load <=4 before and after, a discarded warmup, and frozen binaries. Measure a zero-iteration process
separately to show startup overhead. Collect `perf stat` instructions/cycles separately from wall-time runs.

The Stage 0 report is [BUMP_ALLOCATION_PROFILE.md](../../../docs/BUMP_ALLOCATION_PROFILE.md).

`measure.py` reproduces the nine-round census after preparing the frozen binaries under
`out/bump-allocation/` as described in the report. It records load, RSS, timing, counters and runtime hashes.
`estimate.s` is an assembled instruction-shape sketch with placeholder offsets; it is not a runnable allocator.
