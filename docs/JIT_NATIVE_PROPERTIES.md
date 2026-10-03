# HashLink native properties

`DEFINE_PRIM_NORETURN(result, name, arguments)` exports the normal `hlp_<name>` primitive entry and an `hlnr_<name>` data marker. It works in libhl and in external HDLLs using `HL_NAME`. The loader resolves the marker from the same library as the primitive and stores its presence in `hl_module.native_noreturn`, indexed by the module's native table. Each module generation resolves its own flags; patch functions retain their module's native table. Optional missing or disabled primitives have no flag. Libraries without markers remain compatible.

The marker declares that the callee cannot return normally, even when called without a preceding bounds test. The JIT emits `M_NORET` and the x86 backend traps if the callee unexpectedly returns. Throwing into a handler still works. This avoids treating a cold throw-only call as a returning call when allocating registers across loops.

The audit found `std.array_out_of_bounds` as the exported unconditional throwing helper, and `std.sys_exit` as an unconditional process exit. Both are marked. Public casts, array checks, growing writes, string index operations, and runtime module wrappers can return on valid input and stay unmarked. The private `invalid_cast`, `realtime_array_retype_mismatch`, and `realtime_raise_module_exception` helpers declare their C non-returning behavior. `hl_throw`, `hl_rethrow`, `hl_null_access`, fatal helpers and JIT assertion helpers are direct C/JIT calls, not resolved `hlp_` primitives; they need no new primitive exports.

An external test HDLL exports flagged and unflagged throwing functions and an ordinary returning function. The runtime test catches both exceptions and checks live floats across the ordinary call in a loop. Forcing marker lookup to false changes spectral-norm's debug JIT dump from eight non-returning bounds calls and 34 floating-point stack accesses to zero such calls and 40 stack accesses.

## Intrinsics

The documented table in `vendor/hashlink/src/jit_intrinsics.h` matches the exact library, name, argument count, argument modes and result mode. The initial entries are `haxeon_runtime.__math_sqrt`, `__math_abs`, `__math_floor`, and `__math_ceil`. Their emitters use JIT-only operation tags; the bytecode format is unchanged. Other architectures keep native calls.

Absolute value uses an aligned 16-byte constant sign mask; it does not depend on the alignment of a spilled operand. Floor and ceil use SSE4.1 `roundsd` with an explicit rounding direction, followed by the existing truncating double-to-int conversion. CPUID gates these entries; `HL_JIT_NO_SSE41=1` exercises the native fallback. `HL_JIT_NO_AVX=1` also passes the fixtures.

Min/max remain native because the direct SSE instructions do not preserve both Haxe's NaN propagation and signed-zero rules. `__string_char_code_at` returns -1 for null or out-of-range inputs; a direct character load is not equivalent. It and addChar remain native under the restriction against branching expansions. Consequently these changes do not add a string fast path for fasta.

The stock interpreter supplies the integer-rounding fixture's expected pairs. Integer conversions stay in range; NaN, infinities and signed zero are checked through Float rounding APIs. The signed-zero checks exposed an existing `ffloor`/`fceil` issue, fixed by returning a zero input unchanged. Mutating each of sqrt, abs, floor and ceil makes its fixture fail.

## Fused array reads

The C0 scratch prototype reused `OGetArray` for Int, Float and pointer elements. Nine alternating runs pinned to CPU 0, with load around 4, produced:

| Benchmark | Existing lowering | Scratch fused reads | Change |
| --- | ---: | ---: | ---: |
| nbody, 5,000,000 steps | 0.2516s | 0.2172s | 13.7% faster |
| spectral-norm, 2,000 | 0.2609s | 0.2602s | 0.3% faster, within noise |

The nbody result passes the 8% gate. Pointer reads matter here because its bodies are an `Array<Planet>`. Both executable outputs matched.

Production lowering emits ordinary `OGetArray` for typed Int/Float reads. On x86-64, the JIT-only `OJitArrayGet` tag emits an unsigned compare against array size, `jae` to one failure stub per function, a backing-pointer load, and one scaled element load. Spilled inputs get scratch-register saves/reloads. The stub calls the declared non-returning bounds helper once and traps if it returns. No bytecode opcode, bytecode reader, patch reader, writer, validator, or debugger-adapter format change is needed.

C-array abstract storage keeps its original path. Other scalar element widths and non-x86-64 architectures keep the generic runtime check. Pointer elements, including nullable boxes, use the existing pointer representation. Writes retain their growth checks and `array_ensure` path, including writes at or beyond the logical length. They reload backing storage after a growing callee.

The lowerer tracks historical validation separately from cached offsets. That preserves the existing relaxed compound-write behavior: after a read validates an index, a callee can shrink the logical length, and the compound write can still land in retained capacity without restoring length. Reads recheck size after the callee and raise for removed elements. Wasm and Eval retain their growing-write semantics; the fixture checks the documented target-specific lengths.

Four new fixtures cover boundary reads and writes, exceptions with a Float live in the handler, growth, aliases, objects, strings, Bool, nullable Int/Float elements, NaN, and shrinking callees. Stock Haxe Eval supplies their expected checksums. Its invalid reads normally return null, so `#if eval` guards model HL/Wasm's existing throwing contract; they are absent in the code under test. Changing `jae` to `ja` makes the boundary fixture fail with exit 5. All new fixtures pass Wasm parity.

Validation and measurements are retained under `out/jit-validation/`, including the C0 source/executable, paired timing data, JIT dumps, interpreter references, mutation results and suite logs. The temporary analyses and prototypes are not committed.

## Final validation

All 18 suite/mode combinations passed with defaults and with `HAXEON_INLINE=0`:

| Suite | Inliner on | Inliner off |
| --- | --- | --- |
| Every non-Wasm manifest program on HashLink | 320 passed | 320 passed |
| Compiler/runtime driver, `build.hl test 8` | 463 passed | 463 passed |
| `scripts/test-wasm-backend.sh` | passed | passed |
| `scripts/test-wasm-gc-parity.sh` | 317 passed, 14 existing skips | 317 passed, 14 existing skips |
| `tests/differential/run.sh` | passed (10 cases) | passed (10 cases) |
| `scripts/check-self-hosting.sh` | byte-identical stages 1/2 | byte-identical stages 1/2 |
| `tests/integration/test-workspace.sh` | passed | passed |
| `tests/integration/test-compiler-embedding.sh` | passed | passed |
| `tests/integration/test-git-package-lock.sh` | passed | passed |

The existing `ArrayBoundsMain` and `loop-live-across-calls` tests are included. The external HDLL runtime test passes;
its marker also exports correctly when compiled as C++. A supplemental typed throwing native returns no value to
its caller, which preserves the prior local through the catch. SSE4.1-disabled and AVX-disabled fixtures pass.
The refreshed checked-in bootstrap rebuilds itself byte-identically. The formatter and whitespace checks pass.

The initial driver failure exposed a missing native table in temporary patch code; borrowing the module's native
table fixed the existing plugin regression test. Self-hosting also exposed an unsupported array key/value
comprehension in a concurrent type-resolution commit; equivalent indexed iteration preserves that fix and passes
its compiler unit test and self-hosting. The concurrent commit's original identity is preserved.

The final cross-language run completed all 24 rows: four languages, six benchmarks, nine timed runs, CPU 0, load
3.96 at start and 6.88 at finish. The before/after comparison and a low-load prototype/production comparison are
reported in the benchmark README. Production nbody matches the prototype (0.215s versus 0.216s); spectral-norm
remains around 0.261s. Fasta's array-read gain is reported separately from the omitted string intrinsics.

Not run: AArch64, other non-x86-64 architectures, x86-32, or Windows native execution. The existing 14 Wasm parity
exclusions remain in `tests/programs/wasm-parity-skips.tsv`; none of the new fixtures is excluded. Min/max,
`__string_char_code_at`, and addChar were deliberately left native under the stated semantic/branching restrictions.
No new bytecode opcode or debugger format was introduced. No remote branch was pushed and no PR was merged.

Fork commits: `1ca7faa4` (native declarations), `e1688343` (intrinsic table and patch metadata), `880a4228` (fused reads).
Root commits: `73c34413` (A and external test), `a5484cf9` and `ef3e11e9` (B and patch fix), `5f85a33a` (C lowering/bump),
`f8f01495` (C fixtures), `5472f7ea` (self-hosting compatibility), and `b3d396f8` (bootstrap). All task commits carry the
requested co-author trailer. Measurements and this report are committed separately.
