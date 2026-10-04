# Checked Bytes.set JIT experiment

Measured on 2026-10-04 after the short-ASCII decoder was accepted (`b930ced9`, HashLink fork `2f49c4d4`). The acceptance gate was a repeatable 3% fasta gain, then full validation and no other benchmark regression beyond noise. The prototype gained 1.91%, so it was discarded. No runtime/JIT change, switch, fork commit or submodule bump is retained.

## Target and prototype

The preceding [fasta profile](FASTA_PROFILE.md) attributed 3.03% of sampled cycles to native `Bytes.set`, excluding caller overhead. Fasta calls it once per generated character. The prototype targets this general byte-buffer operation; benchmark source and bytecode were unchanged.

The runtime declared a versioned checked-byte-store contract and its actual data/length offsets beside the native binding. Module loading resolved that optional declaration. The x86-64 JIT required the expected library, name and native signature before replacing the call. An HDLL without the declaration retained the native call.

The emitted path tested null, used an unsigned index-versus-length comparison (rejecting negative indices), loaded the data pointer and stored the low byte. Both failure branches targeted one shared cold stub per function. That stub called the original native with a null buffer to raise the identical existing error and never rejoined. The address was defined only on the successful path, avoiding merged register definitions. No allocation or GC-capable call remained on the successful path.

A scratch `HL_JIT_BYTES_SET=1` flag enabled the prototype only in the x86-64 backend. It was off by default and removed with the rejected code. No Bytes.get optimization was attempted after Bytes.set failed the gate.

GDB confirms that the per-character native call disappeared. The resulting store still loads a stack-resident loop index and saves/restores a temporary register around address formation. Removing the call does not eliminate all overhead of this access. This observation does not justify another register-allocation change without its own measurement.

## Measurement

Core 0, fasta input 2,500,000, identical frozen bytecode, frozen original and candidate runtimes, one discarded output-checking warmup and nine alternating pairs. Pairs crossing load 4 were discarded. Maximum load in accepted observations: 3.833. No own builds or tests ran during acceptance timing.

| Variant | Median seconds | Median peak RSS KiB |
|---|---:|---:|
| Original | 0.433775 | 81120 |
| Checked byte-store prototype | 0.425492 | 81120 |

Gain: **1.91%**, faster in 9/9 pairs. This is below the 3% gate. The original includes the accepted ASCII decoding and allocation optimizations.

Supporting single `perf stat` runs (cpu_core events, diagnostic rather than acceptance timings):

| Variant | Instructions | Cycles |
|---|---:|---:|
| Original | 4,688,877,542 | 2,199,190,200 |
| Prototype | 4,632,135,834 | 2,144,353,825 |

## Correctness checks and restoration

- Valid stores cover 0, 127, 128, 255, 256, negative values and Int limits, aliasing and repeated loop writes. Stock Haxe's interpreter independently returns 42 for the valid-store reference.
- Scratch native-contract checks cover index -1, length, length+1, both Int limits, empty buffers, null buffers, identical error messages and a Float value live across caught failures. Both switch modes and the unchanged runtime return 42. Invalid-access expectations come from the existing checked native; stock Bytes APIs do not uniformly promise those checks across targets.
- Fasta output matches byte for byte at input 1000 and acceptance input 2,500,000.
- With the prototype VM and flag enabled but an unchanged, unmarked HDLL, the native fallback passes the same contract test.
- GDB verifies null/bounds branches, the byte store and the shared non-returning failure stub.
- Experimental files were saved as patches under `out/bytes-set-probe/`, then restored byte for byte from backups taken while both repositories were clean. The rebuilt VM, libhl and native HDLL SHA-256 hashes exactly match the original frozen runtime. The restored runtime passes the contract test.

Full fixture/driver sweeps, mutation checks, GC/thread stress, differential, self-hosting, Wasm parity, integration/DAP, other-benchmark timings and AArch64/Windows tests were not repeated: the first performance gate failed and no code or fixture is retained. Previously accepted code remains covered by [the ASCII decoder validation](FASTA_OUTPUT_PROFILE.md). `./scripts/format.sh` and `git diff --check` ran before the report commit.

Raw pairs, loads, RSS and hashes are in `out/bytes-set-probe/measure.json`; disassembly, perf logs, scratch tests, rejected patches and restoration build logs remain in that directory. The committed artifact is this report. Benchmark acceptance numbers remain unchanged.
