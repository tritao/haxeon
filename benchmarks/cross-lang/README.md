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

Method: each build is checked against the expected output, then one discarded
warmup run and `--runs` timed runs. Times are whole-process wall clock (startup
and JIT warmup included) with peak RSS; there is no in-process warmup yet.

Caveats: the C# `spectral-norm` and `fasta` variants are multi-threaded, so
compare them with that in mind; `size` indexes each problem's two input sizes.

## Haxeon compile status

`haxeon` builds and verifies `binarytrees/1`, `nbody/1`, `spectral-norm/1`,
`fasta/1`, `merkletrees/1` and `lru/1`. Not yet built: the alternate variants
that use `using` static extensions (`binarytrees/2`, `nbody/2`, `nbody/3`),
because static extensions are not implemented.

Haxeon deliberately differs from stock Haxe here, so the sources were adapted
(see `NOTICE.md`): value-returning functions and ordinary parameters need type
annotations (signatures are part of live-patch classification), and arithmetic
on a `Null<Int>` needs a null check.
