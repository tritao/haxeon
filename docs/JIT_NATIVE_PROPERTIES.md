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
