# AOT backend: C from Haxeon's IR on the HashLink runtime

Status: proposed; milestone 1 implemented (`--target=hlc`). Depends on the columnar IR (`IR_CORE_COLUMNS.md`): the backend
reads the inliner's bodies as `HlLower` does.

## Problem

Haxeon programs run on HashLink's JIT. Platforms that forbid writable code (iOS, consoles) need ahead-of-time code, and
the JIT's code generator is simple: no global register allocation, no instruction scheduling, a call for most runtime
operations. Stock Haxe's HL/C (`hl2c`) translates bytecode to C, register for register. Run on the Haxeon compiler and linked
against our fork it works, but gains little: the workload is runtime-bound (GC, allocation, string and map natives), `-O3`,
`-march=native` and LTO give nothing over `-O2`, and what the bytecode lost (exact types, unboxed values, proofs) the C
compiler cannot recover. The wins have to come from what Haxeon's IR knows.

## Proposal

Haxeon emits C from its own optimized SSA IR, on the HashLink runtime and GC: the same object layouts, type descriptors,
globals, natives and standard library as the JIT, so generated C links against the fork's `libhl.a` and can mix with
bytecode-loaded code later. gcc, clang or MSVC do register allocation and instruction selection. A direct machine-code
backend could reuse the same lowering decisions later; it is not planned.

The target is `--target=hlc`. It is a HashLink target for everything before the backend (defines `hl`, `sys`, `hlc`; the
HashLink IR pipeline; `IrPipelineContext.isWasm()` is false), and differs only in what the backend emits.

## Where it hooks in

After the inliner stage, on the published bodies, exactly where `HlLower` reads them. `HlcBackendSession` (the session
backend for `hlc`, beside `HashLinkBackendSession` and `WasmBackendSession`) does a plain HashLink assembly
(`HlPlainBuild`: reachable from the entry, `IrSharedRuntimeCalls`, a fresh `HlModuleAssembler`) and keeps the assembler's
symbol table and the program it lowered. That assembly decides everything the runtime sees:

- the type table (`HlCode.types`: objects with field order and prototypes, virtuals, enums, enum tags, functions),
- globals and their types, constants (String literals), natives and their slots, function slots and the entry point.

The C backend reuses those decisions; it never lays out a type itself. `HlcModule` lowers each function's body to C
(`HlcFunctionLower`), resolving names through the same symbol table (function slots, global indices, type indices, field
indices), and writes the module image (below). The bytecode `HlLower` produced alongside is not used except as the
image's function signatures; a later step skips lowering bodies to bytecode for `hlc`. The assembler keeps the program it
lowered for this (`HlModuleAssembler.keepsProgram`), so the C backend sees exactly the functions the slots were given,
after `IrSharedRuntimeCalls`.

Lowering decisions that are semantics, not encoding, must be the same in both backends: which receivers get a null check
(`IrNonNullFacts`), the pseudo-calls that are not functions (`IrReceiverCheck`, `IrReferenceIdentity`,
`IrExactTypeFacts.TEST`, `IrHlScalarRef`, `IrScalarWordBits`, `IrValueLaneReference`), string literals as constant
globals, nullary enum constructors cached in globals, enum tags as `index + 1`. While both lowerings are young they
share these by calling the same helpers; once the C backend covers the IR, the decisions move into one
`HlLoweringDecisions` that `HlLower` and `HlcFunctionLower` both read, so neither can drift.

## Runtime image and initialization

The runtime builds its `hl_type`s from a module image: the assembled `HlCode` with every function body replaced by a
one-instruction stub, encoded by `HlWriter` and embedded as a byte array. At startup the generated `main` reads it with
`hl_code_read`, allocates and initializes the module with the fork's own `hl_module_alloc`/`hl_module_init` (types,
enums, virtuals, enum tags, globals and their GC roots, natives, String constants), then overwrites every function slot
(`functions_ptrs`) with the C function, before any object prototype is built. So the type descriptors, field offsets,
natives resolution and constants are the fork's code, not a copy: the C backend cannot disagree with the JIT about a
layout. Dynamic calls into C functions (`hl_dyn_call`, closures passed to natives) go through the JIT's `static_call`
and wrappers, which call with the platform C ABI.

This keeps the JIT in the executable for the stubs. Milestone 4 replaces it with `hl_module_init_aot` in the fork (the
same initialization without JIT, function pointers given) and static per-signature `static_call`/wrapper trampolines as
`hl2c` generates, and may later emit the type tables as static C data to skip decoding.

Layout checks: the generated code accesses object fields through C structs and globals at offsets computed by the backend
(`hl_module_alloc`'s rule). At startup, before running anything, the entry point checks each struct's field offsets
against `hl_get_obj_rt(t)->fields_indexes` and each global's offset against `globals_indexes`, and exits on a difference.
The runtime's own structures (`varray` with its `data` pointer, `vclosure`, `venum`, `vvirtual`) are never copied: the
generated code includes the fork's `hl.h` from the SDK and uses its macros (`hl_aptr`, `hl_vfields`), and enum payloads
are read at the runtime's constructor offsets, so a change in the fork's layouts is a C compile error or a startup check
failure, never silent corruption.

## The C shape

The sources go to `OUTPUT.c/`:

- `hlc.h`: the one generated header: `#include <hl.h>`, a struct per object type (fields flattened from the base down, as
  `hl_get_obj_rt` lays them out with no tail padding between a base and its subclass, `f<index>` by HashLink field
  index), and a prototype per function.
- One `.c` file per Haxe source file (each function goes with the source most of its rows come from, so inlined code
  does not move it), so C builds run in parallel and an edit recompiles only the files whose text changed: the writer
  leaves an unchanged file untouched, so its timestamp stays. Measured on the compiler with `hl2c`, per-module files
  build in a fraction of a unity build's time and memory.
- `image.c`: the module image, the slot table (function pointers by slot), and the layouts to check.
- `main`: the SDK's `src/hlc_main.c` (`native/aot/hlc_main.c` in the repository), compiled with them.

Functions are named from their Haxe names (`hx_Point_sum`), deduplicated with the slot number, so names are stable across
builds and readable in debuggers, `perf` and crash backtraces. Values are `v<id>` by IR value id.

## Values, calls and the GC

- **Values.** Each SSA value is a C local of its HashLink register type's C type (`int`, `double`, `vdynamic*`, an object
  struct pointer). Phis are locals assigned on the incoming edges, through temporaries when an edge moves several. Scalar
  replaced values and value classes the IR already split stay split: they are just more locals, and the C compiler keeps
  them in registers.
- **Direct calls.** A call whose target the IR knows is a C call to that function, which the C compiler may inline. A
  value-class method is a direct call. Virtual calls load the method from the type's prototype (`vobj_proto`), interface
  calls from the virtual's field table with the `hl_dyn_call_obj` fallback, as the JIT does.
- **Natives** are called through the slot table the loader filled (`hl_module_init` resolves them as for the JIT, by
  `hlp_` symbol: `std` from `libhl`, `haxeon_runtime` as `realtime_*`), one indirect call. Direct calls to natives need
  declarations that do not conflict with `hl.h`'s; that is milestone 3.
- **Closures** are `vclosure`s: static closures allocated once per site, instance closures with `hl_alloc_closure_ptr`;
  a call tests `hasValue` as `hl2c` does. Function values from natives and the JIT are the same structure.
- **Dynamic values.** Scalars stay unboxed by their static type throughout; a value is boxed only where the IR says it
  becomes Dynamic (a `ToDyn` row: a Dynamic-typed slot, or a type parameter erased to Dynamic at a real boundary), by
  the runtime's own `hl_make_dyn`. Generated code keeps no box cache of its own (no shared small-Int boxes). Boxes come
  from Dynamic-typed slots: `Null<Int>`, generic containers and type parameters, `Dynamic`, anonymous structures. The
  clean fix is not making the box: nullable scalars as flag and value pairs, generics specialized for scalars, which
  the IR does for every backend, so the JIT and Wasm gain as much. Tagged small Ints inside Dynamic would be a runtime
  and ABI decision for the fork, not part of this backend. Casts go through `hl_dyn_cast*`, dynamic fields through
  `hl_dyn_get*`/`hl_dyn_set*`.
- **Null and bounds checks.** A receiver gets `if (!o) hl_null_access()` unless `IrNonNullFacts` proves it non-null.
  Array accesses call `hl_array_check`/`hl_array_ensure` as the JIT does unless the IR proved the index in range
  (`IrLoopBounds`, milestone 2).
- **Null access messages.** A failed check before a field access throws the JIT's "Null access .field"
  (`hl_jit_null_field_access`); others throw "Null access", as the JIT's do.
- **GC roots.** The collector scans each thread's stack conservatively, as for JIT frames and `hl2c`, so C locals need no
  registration; globals are registered by the module initialization. Stores of pointers into the heap go through
  `hl_gc_store_ref`, which records the write for incremental marking (`gc_write.h`), exactly where the JIT emits its
  barrier. A precise GC (stack maps from the IR's types) is possible later and would need shadow stacks or LLVM-style
  statepoints; it is not planned.
- **Exceptions** use the runtime's traps: `hl_trap` (setjmp) at `BeginTry`, `hl_endtrap` at `EndTry`, `hl_throw` and
  `hl_rethrow`; a trap that preserves the exception stack (`defer`, scoped cleanup) also enters and leaves an
  `hl_cleanup_trap_ctx`. Locals assigned after the `setjmp` and read in the handler are phis in SSA: in a function with a
  try they are declared `volatile`.
- **Enums** are `venum`s; payload fields are read and written at the constructor's offsets from the runtime type
  (`tenum->constructs[c].offsets`), payload-free enums in tag storage are `int` tags.

## Debug information

Each C statement is preceded by `#line N "file.hx"` when its source position differs from the previous one, so DWARF and
PDB line tables point at Haxe sources, and gdb, lldb, perf and sanitizers report Haxe lines. Haxe-level stack traces
(`haxe.CallStack`, uncaught exceptions) need the runtime to turn return addresses into Haxe positions: `capture_stack`
with the platform unwinder and `resolve_symbol` through the native symbol and line tables (`backtrace_symbols`, DbgHelp),
as `hlc_main.c` does; milestone 3. The debugger and hot reload are JIT features and stay so.

## Driver and target selection

`--target=hlc` selects the backend as `--target=wasm32` does (`BackendTargets.parse` gives `HashLinkC`). The compile writes
the C sources into the directory `--output` names plus `.c` (`out/main.c/`). The C compiler is a typed option on the
request (`CompileOptions.cCompiler`, `--c-compiler=cc`), with the SDK it links against (`CompileOptions.cSdk`,
`--c-sdk=DIR`: the native build's `hlc-sdk` directory, made by the `haxeon-hlc-sdk` target, with the runtime headers in
`include/`, `libhl.a` and `libffi.a` in `lib/` and the entry point in `src/`); with both set, the driver compiles each C
file that changed (in parallel, `-O2 -g -fwrapv -fno-strict-aliasing`: Haxe's `Int` wraps, and objects are read through
each other's structs), links the executable at `--output` with the whole VM library (the loader resolves natives by
their `hlp_` symbols in the executable itself), and reports the C compiler's diagnostics as a compile error. Neither is read from the environment or from defines. They change
no IR or C text, so `CompileOptions.key` leaves them out.

## Testing

- `tests/aot/test-aot-programs.sh` compiles each listed `tests/programs` file for `hl` and for `hlc`, runs both, and
  compares exit code, stdout and stderr. The list grows with the milestones; the script prints pass, fail and
  unsupported counts (a compile that stops at an unsupported IR construct is reported as such, not as a failure).
- Later: every program in `expected-exits.tsv`, with a skip list like `wasm-parity-skips.tsv`, in the test driver.
- The compiler itself built with `hlc`: compiling the self-compile input must give byte-identical output to the JIT
  build, and its speed is the benchmark that decides how far to go.

## Milestones

1. **Core.** The target, the session backend, the image and initialization, the C shape, and the lowering of
   constants, arithmetic and comparisons, control flow and phis, static calls, globals, objects and fields, virtual
   calls, closures, boxing and casts, arrays, strings, enums and exceptions; unsupported constructs are a clear compile
   error. The test runner and its first list of programs.
2. **Coverage.** Every IR opcode and pseudo-call: interfaces and virtuals with typed interface tables, value-array reads,
   memory loads and stores, C native calls, iterators, the runtime fast paths `HlLower` writes inline; dropped bounds
   checks from loop proofs. All of `tests/programs` with a skip list, in the test driver.
3. **Debugging and natives.** `#line` mapping and Haxe stack traces; direct native calls; perf symbol names.
4. **No JIT.** `hl_module_init_aot` in the fork, static call trampolines, optional static type tables; an executable
   without the JIT for platforms that forbid it.
5. **The compiler AOT.** Build the compiler with `hlc`, byte-identical self-compile output, measured against the JIT.
6. **Unboxed across calls.** Value classes and scalar-replaced values passed and returned in registers between C
   functions (several C arguments, or small structs returned by value) where the IR's scalar ABI already splits them;
   no boxing at the boundary to natives that do not need it.

### State

Milestone 1 in progress; see the end of this section for what runs.
