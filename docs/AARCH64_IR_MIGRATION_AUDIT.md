# AArch64 IR JIT migration audit

This audit records where behavior from the legacy Haxeon AArch64 backend belongs
while the backend is being migrated to the HL2 IR pipeline. The legacy backend
remains the behavioral reference until the IR backend is validated.

| Existing Haxeon ARM64 behavior | Current owner/location | Destination in IR architecture |
| --- | --- | --- |
| Array backing storage, bounds checks, and growth | Legacy `jit_arm64.c`; current `jit_emit.c` already emits `hl_array_check`, `hl_array_ensure`, and `varray.data` addressing | **Already handled by shared HL2**; verify on AArch64 without duplicating semantics |
| Dynamic casts and function wrappers | Legacy ARM opcode lowering plus generic wrapper helpers in `jit.c` | **Move to shared runtime/IR where possible; port only AAPCS64 wrapper/trampoline ABI** |
| Typed globals (integer widths, pointers, F32/F64) | Legacy ARM global opcode cases; shared IR emits typed `LOAD_MEM`/`STORE` | **Already handled by shared HL2**; backend follows IR modes |
| Unresolved native-call diagnostics | Legacy `op_call_fun` | **Move to shared call lowering/runtime** so all backends diagnose unresolved natives |
| Stable patch entries and staged calls/function references | Legacy ARM calls, closure patch list, and `hl_jit_patch_method`; `module.c` owns slots and stride | **Port to AArch64 backend plus shared staging-aware IR hooks** |
| Staged closure lifetime/ownership | Legacy ARM `OStaticClosure`; shared emitter tracks normal closures | **Move ownership/finalization into shared semantics**; staged closures use GC-owned allocation |
| Android host-native lookup and patch trampolines | `module.c` plus legacy ARM trampoline | **Shared Android lookup; AArch64-specific trampoline encoding and stride** |
| Large-function register-cache fix | Legacy ARM local cache | **Obsolete**; `jit_regs.c` owns allocation and uses full virtual IDs |
| ARM64 GDB JIT metadata (`EM_AARCH64`, sentinel range) | `jit_gdb.c` and legacy ARM metadata generation | **Shared JIT metadata path plus AArch64 ELF machine tag** |
| AAPCS64/Apple ABI, stack args, relocations, I-cache/W^X, frame walking | PR #932 backend and generic `jit_regs.c`, `gc.c`, `module.c` | **Port/adapt PR #932 pieces to current shared API/backend** |

The migration deliberately does not copy high-level HL opcode cases into the
new code generator. The new backend consumes only HL2 IR operations.
