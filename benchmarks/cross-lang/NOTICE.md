# Third-party benchmark sources

The `*.hx`, `*.cs`, `*.dart` programs and `*_out` expected outputs here are
copied unmodified from
[hanabi1224/Programming-Language-Benchmarks](https://github.com/hanabi1224/Programming-Language-Benchmarks)
(`bench/algorithm/<problem>/`), MIT licensed (`LICENSE.plb-mit`). Programs that
originate from The Computer Language Benchmarks Game keep their Revised BSD
header. Not vendored: `json-serde` (needs input files and NuGet/pub packages).

## Local changes to the Haxe sources

Haxeon requires explicit signatures and proven non-null arithmetic, so these
files differ from upstream (everything else is verbatim):

- `spectral-norm/1.hx`: removed a duplicated `return`; added `:Float`. Accumulate each row in a local and store it once, as the C# and Dart variants do, instead of updating `Au[i]` in the array on every iteration.
- `fasta/1.hx`: annotated the untyped parameters and return types. Integer generator state, a plain array of cumulative probabilities and a byte buffer per output line, as the C# and Dart variants use, instead of a `Float` state, a `List` iterator and a one-character string per symbol.
- `merkletrees/1.hx`: unwrap `Null<Int>` hashes with an explicit null check.
- `nbody/1.hx`: added `:Float` return types.
