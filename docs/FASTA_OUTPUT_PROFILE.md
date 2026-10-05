# Fasta byte-to-String conversion

The preceding [fasta profile](FASTA_PROFILE.md) identified UTF-8 decoding and stdout formatting as a smaller remaining cost after two hot-loop experiments failed their gates. This experiment changes the general native Bytes-to-String decoder, used by `Bytes.toString`, `Bytes.getString` and `BytesInput.readString`.

## Candidate and correctness

For at most 128 bytes of ASCII, take a bounded stack snapshot, classify its bytes and widen directly into the UTF-16 String allocation. This avoids the temporary heap buffer and the UTF-8 length/decode passes. Larger ranges and non-ASCII retain the original decoder. The existing NUL rejection and bounds checks still apply. Printing, buffering and flush ordering are unchanged.

The snapshot must precede allocation. Allocation can trigger finalizers or allocation callbacks that mutate or invalidate the input. A preliminary direct-read prototype gained 3.55%, but was discarded for this reason; its timings and validation are not acceptance evidence for the snapshot version.

`HL_TEXT_ASCII=0` selects the original decoder. The setting is cached atomically at the first eligible conversion in each native-library instance. This is a runtime switch; bytecode and compiler fingerprints do not change.

The portable C implementation does not change the HashLink fork or JIT. It was tested on Linux x86-64; AArch64, Windows and other platforms were not run.

## Initial timing gate

Nine alternating pairs on core 0, input 2,500,000, identical frozen bytecode and VM libraries, original native library versus the snapshot candidate. Full stdout matched in the discarded warmup. Every accepted sample had one-minute load at most 4.

| Fasta | Original | Snapshot | Gain |
|---|---:|---:|---:|
| Median seconds | 0.448930 | 0.431832 | 3.81% |

This clears the 3% gate. Raw measurements and library/bytecode hashes are in `out/fasta-output/measure.json`.

## Tests and reference values

`bytes-ascii-decode` covers empty input, ASCII controls, vector and 128-byte threshold boundaries, large fallback ranges, Unicode, sliced buffers with NUL/high-bit bytes outside the slice, round trips and independent String ownership. The stock Haxe interpreter returns 42 for the same program.

`BytesAsciiMain` covers malformed UTF-8, NUL rejection, range errors, unchanged input position on failure and mutation during String allocation. Malformed expectations come from stock Haxe bytecode on the unchanged VM. NUL rejection is the existing native String contract; the unchanged native library also passes the allocation-callback guard.

Four isolated mutation builds fail as intended: ignoring high bits, bypassing NUL rejection, reading the original buffer after allocation, and corrupting the widening copy. Each mutation was restored; only isolated scratch native libraries were changed.

## Validation

All of the following passed on the snapshot implementation:

- HashLink fixture sweep: 325 fixtures in each mode. Disabled mode also set `HAXEON_INLINE=0`, `HAXEON_LOADSTORE=0`, `HAXEON_STRENGTH=0` and `HL_GC_ALLOC_FAST=0`.
- Compiler/runtime driver: 474 passed, zero failed in each mode, with the same disabled settings.
- GC controls, collection pacing and thread-GC stress: 20 repetitions each with the default threshold and `HL_GC_MIN_TRIGGER=65536`, in both modes (240 runs).
- Stock-Haxe differential suite and compiler self-hosting to a fixed point.
- Wasm backend suite and Wasm GC parity: 322 fixtures agreed across HL, Wasm32 and Wasm GC; 14 existing exclusions were skipped.
- Workspace, compiler embedding, git package-lock and DAP inline-configuration integration tests.
- Stock interpreter fixture reference; unchanged-runtime malformed UTF-8 reference and allocation-callback test; four mutation checks described above.
- `./scripts/format.sh` and `git diff --check`.

The differential, self-hosting, Wasm and integration suites ran once with default settings. The other DAP suites, AArch64 and Windows were not run. No cross-language benchmark table was regenerated. Logs are under `out/fasta-output/`; the rejected direct-read prototype's logs are separately archived under `direct-validation/`.

## Final regression gate

Nine alternating pairs per benchmark on core 0, original native library versus snapshot, using identical frozen bytecode for each pair. One discarded warmup verified equal full output for each benchmark. All accepted samples stayed below load 4 (maximum 3.714). No validation/build jobs ran concurrently.

| Benchmark | Original seconds | Snapshot seconds | Gain |
|---|---:|---:|---:|
| binarytrees | 1.100963 | 1.103210 | -0.20% |
| merkletrees | 0.452362 | 0.453858 | -0.33% |
| nbody | 0.220203 | 0.217834 | +1.08% |
| fasta | 0.454398 | 0.438277 | +3.55% |
| spectral-norm | 0.184217 | 0.184277 | -0.03% |
| lru | 0.090635 | 0.090491 | +0.16% |

Fasta clears the 3% acceptance gate again. The other changes are within noise; no performance benefit is attributed to them. Median peak RSS stays level (fasta 81,120 KiB on both sides). The optimization is enabled by default, with `HL_TEXT_ASCII=0` available for diagnosis and A/B runs.

Raw pairs, observed loads, RSS and bytecode hashes are in `out/fasta-output/final-six.json`. Native-library hashes are also recorded in the initial `measure.json`; the candidate remained unchanged through final validation and timing. The native disassembly (`decode-disassembly.txt`) confirms vector widening from the stack snapshot without the fallback's temporary allocation or UTF-8 decoder calls. These are new Haxeon-only A/B measurements, not an update of the cross-language reference table.
