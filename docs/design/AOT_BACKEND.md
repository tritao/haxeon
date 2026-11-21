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
one-instruction stub (and the function identities, which name stack frames), encoded by `HlWriter` and embedded as a byte
array. At startup the generated `main` reads it with `hl_code_read`, allocates the module with the fork's own
`hl_module_alloc` and initializes it with `hl_module_init_aot`, given the C functions as the module's code: the same
initialization as the JIT's `hl_module_init` (types, enums, virtuals, enum tags, globals and their GC roots, natives,
String constants, the module registry), sharing its code in the fork, with nothing compiled. So the type descriptors,
field offsets, natives resolution and constants are the fork's code, not a copy: the C backend cannot disagree with the
JIT about a layout, and the executable never starts the JIT.

What the JIT would have provided the entry point sets itself: `hl_setup.static_call` (how `hl_dyn_call` calls a compiled
function with its arguments in memory) and `get_wrapper` (the function a closure wrapped to another function type calls,
which unpacks its arguments for `hl_wrapper_call`) are generated trampolines, one pair per C calling shape of the program's
function types (and of each with its first argument bound), keyed by the result's and arguments' shapes (`hlc_signatures`
in `image.c`, found by binary search); `resolve_symbol` and `capture_stack` are the stack traces below. The type tables could
later be emitted as static C data to skip decoding.

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
- **Natives** of the VM (`std`, `hl_*`) and of the Haxeon runtime (`haxeon_runtime`, `realtime_*`) are direct C calls, by
  the convention of their libraries' `HL_NAME`: each is declared in `hlc.h` under a name of its own bound to the symbol
  (`extern ... hlc_native_17(...) __asm__("hl_alloc_array")`), so its C types never meet `hl.h`'s declaration. The loader
  still resolves every native by its `hlp_` symbol and checks its signature, as for the JIT. Natives of other libraries,
  loaded at run time, and every native where the compiler has no asm labels, are called through the slot table the loader
  filled.
- **Closures** are `vclosure`s: static closures allocated once per site, instance closures with `hl_alloc_closure_ptr`;
  a call tests `hasValue` as `hl2c` does. Function values from natives and the JIT are the same structure.
- **Dynamic values.** Scalars stay unboxed by their static type throughout; a value is boxed only where the IR says it
  becomes Dynamic (a `ToDyn` row: a Dynamic-typed slot, or a type parameter erased to Dynamic at a real boundary), by
  the runtime's own `hl_make_dyn`. Generated code keeps no box cache of its own (no shared small-Int boxes). Boxes come
  from Dynamic-typed slots: `Null<Int>`, generic containers and type parameters, `Dynamic`, anonymous structures. The
  clean fix is not making the box: nullable scalars as flag and value pairs, generics specialized for scalars, which
  the IR does for every backend, so the JIT and Wasm gain as much. Tagged small Ints inside Dynamic would be a runtime
  and ABI decision for the fork, not part of this backend. Casts go through `hl_dyn_cast*` (`Null<T>` to `T` inline, as the JIT), dynamic fields through
  `hl_dyn_get*`/`hl_dyn_set*`.

  The self-compile asks for about 4.8 million scalar boxes, of which the JIT's shared Bool and small-Int boxes serve
  all but a few hundred thousand. Without a cache, an AOT compiler would allocate nearly all of them, so "no box cache"
  depends on removing their causes first, in the compiler and runtime, where JIT and Wasm gain too: the native typed
  maps box Int and Bool values on `set` (most of the requests and allocations: unboxed value slots, and `get` lowered
  to a found flag and value pair); map handles stored as values of other maps (store the handle in a reference-valued
  map); optional and default Bool and Int arguments through dispatch and overridable methods (extend the nullable
  scalar argument splitting); generics with scalar `T` (specialization); real Dynamic boundaries (JSON, `Reflect`)
  stay. Until then, generated code boxes only through the runtime's helper (`hl_make_dyn`), so the policy lives in
  one place and changes there for both backends.
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

Each C line is preceded by `#line N "file.hx"` when its source position differs from the previous one, and every C line
after the first of one IR row repeats it (a `#line` counts the lines after it), so DWARF and PDB line tables point at Haxe
sources, and gdb, lldb, perf and sanitizers report Haxe lines. Rows of no source are line 1 of `<generated>`, as `HlLower`
places them. Functions keep their Haxe names in C (`hx_Point_sum`), which is what perf shows.

Haxe stack traces (`haxe.CallStack`, uncaught exceptions) are the JIT's, frame for frame (`native/aot/hlc_stack.c`): the
generated functions are in a section of their own (`hlc_text`), so `capture_stack` (the platform unwinder, `backtrace`)
keeps exactly the frames whose return address is in it, as the JIT keeps those in its code. `resolve_symbol` names a frame
by the function's identity in the module image (the `FUNCTION_IDENTITIES` section is kept in the image) and the Haxe file
and line of the call from the executable's own DWARF line table (`.debug_line`, read once, on the first resolve). The C
compiler never turns calls into jumps (`-fno-optimize-sibling-calls`): a jump leaves no record a frame could be restored
from. Whether it inlines generated functions into each other follows the build mode (`--build-mode`, on the request):

- **development** compiles with `HLC_EXACT_FRAMES`: generated functions are `noinline`, so every frame is a real one, as
  the JIT's are (the IR's inliner has already inlined what it decided to). The parity runner compiles in this mode.
- **release** lets the C compiler inline. A return address can then lie in code inlined from other generated functions,
  and the stack capture restores their frames from the DWARF inline records (`.debug_info`: each
  `DW_TAG_inlined_subroutine` with its address ranges, abstract origin and call file and line), read on the first capture:
  a physical frame becomes the chain of generated functions inlined at its call, innermost first, each named at the line
  where its caller calls it. Inlined runtime helpers (`hl.h`, `hlc_new`) are not frames: the generated function around
  them is named at the line of the helper's call. Clones the C compiler makes (`.part`, `.constprop`) are named by their
  abstract origin.

Each mode keeps its objects (`OUTPUT.c/obj-development`, `obj-release`), made again when the compiler or its flags change;
the C text is the same. Where the C compiler has the flag (gcc), it compiles with `-fno-crossjumping`: it would otherwise
merge identical calls of different Haxe lines, throws most often, also in inlined copies of one function, into one call
of one line, losing the others' lines and inlined frames.

A frame's file is the path the `#line` directive wrote, as the JIT prints the module's debug file. The C compiler's line
table keeps a path under its working directory relative to it, so `/work/Main.hx` and `Main.hx` read the same there; the
image lists the directives' paths (`hlc_source_paths`), and the line table's files are matched to them by absolute path.

Implemented for Linux (ELF); elsewhere exceptions carry no frames yet (Windows has DbgHelp for
lines, macOS the dSYM). The debugger and hot reload are JIT features and stay so.

## Driver and target selection

`--target=hlc` selects the backend as `--target=wasm32` does (`BackendTargets.parse` gives `HashLinkC`). The compile writes
the C sources into the directory `--output` names plus `.c` (`out/main.c/`). The C compiler is a typed option on the
request (`CompileOptions.cCompiler`, `--c-compiler=cc`), with the SDK it links against (`CompileOptions.cSdk`,
`--c-sdk=DIR`: the native build's `hlc-sdk` directory, made by the `haxeon-hlc-sdk` target, with the runtime headers in
`include/`, `libhl.a` and `libffi.a` in `lib/` and the entry point in `src/`); with both set, the driver compiles each C
file that changed (in parallel, `-O2 -g -fwrapv -fno-strict-aliasing -fno-optimize-sibling-calls`, plus `-DHLC_EXACT_FRAMES` in a
development build: see Debug information; Haxe's `Int` wraps, and objects are read through
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
2. **Speed and coverage.** What `HlLower` writes inline: the runtime fast paths, value-array reads, typed interface
   method tables, the JIT's inline allocation; ordinary C function calls (`CNativeCall`, still unsupported); bounds
   checks dropped by loop proofs. The parity runner in the test driver.
3. **Debugging and natives.** Haxe stack traces (`#line` mapping is in milestone 1); direct native calls; perf symbol
   names.
4. **No JIT.** `hl_module_init_aot` in the fork, static call trampolines, optional static type tables; an executable
   without the JIT for platforms that forbid it.
5. **The compiler AOT.** Build the compiler with `hlc`, byte-identical self-compile output, measured against the JIT.
6. **Unboxed across calls.** Value classes and scalar-replaced values passed and returned in registers between C
   functions (several C arguments, or small structs returned by value) where the IR's scalar ABI already splits them;
   no boxing at the boundary to natives that do not need it.

### State

Milestones 1 to 4 are done. `tests/aot/test-aot-programs.sh --all` passes all 643 programs of `tests/programs` with the
JIT's exact exit code, stdout and stderr, stack traces included; `tests/aot/programs.txt` lists them and is the runner's
default, and the `ci` suite `aot-programs` runs it. No IR construct of the programs is unsupported.

Milestone 2: the C lowering writes what `HlLower` writes inline, from the same decisions
(`HlLower`'s value array constants and read selection, `HlLower.cNativeInvocation`): the array push and byte read and write
fast paths, also at calls of their shared helpers (`IrSharedRuntimeCalls` saves the JIT start-up time, which C does not pay);
value array reads from the scalar lane with the view resolved where the array value is defined; the typed interface method
table prologue of dispatch functions; ordinary C function calls (`CNativeCall`) through the runtime's dispatch. Array bounds
checks are inline compares, dropped where an earlier check in the block still holds (`HlLower.keepsArrayBounds`) or the loop
proves the index in range (`IrLoopBounds`). Objects are allocated by `hl_alloc_obj`, as the JIT allocates them by default. The JIT's inline
allocation is opt-in on both: the JIT's with `HL_JIT_ALLOC_INLINE=1` in the VM, the C backend's with the typed option
`CompileOptions.inlineAllocation` (`--inline-allocation`), which allocates by `hlc_new` from the collector's own descriptor
(`hl_jit_alloc_prepare`, filled at start-up). A cast from `Null<T>` to `T` reads the box inline, as the JIT's
`emit_dyn_cast` does, instead of calling `hl_dyn_casti`.

Measured on the cross-language benchmarks (`benchmarks/cross-lang`, first bench input, median of 5 interleaved runs, wall time,
machine loaded by other work at a load of about 5 to 7), JIT, milestone 1, milestone 2: binarytrees 2.40, 2.46, 2.52 s;
nbody 0.48, 0.50, 0.48 s; spectral-norm 0.41, 0.74, 0.31 s; fasta 0.90, 0.96, 0.85 s; merkletrees 0.76, 0.81, 0.86 s;
lru 0.27, 0.28, 0.28 s. The array checks are what spectral-norm and fasta gain. binarytrees and merkletrees spend most of
their time in the collector's marking threads, which the generated code does not change; inline allocation shows no gain
there. nbody and lru are within noise.

Milestone 3: Haxe stack traces as the JIT's, frame for frame (Linux; see Debug information), and direct calls of the VM's
and the runtime's natives. Keeping every frame means no inlining between generated functions and no sibling calls; on the
same benchmarks that costs nothing measurable but merkletrees (recursive small functions), about 0.88 to 0.95 s, within
this machine's noise but worth the milestone 5 measurement of inlining with DWARF inline records.

Milestone 4: the executable initializes its module with `hl_module_init_aot` and calls through generated trampolines; the
JIT is never initialized (it is still linked, as part of `libhl.a`). Not done: a `libhl` without the JIT for platforms that
forbid writable code (a build of the VM library that leaves the JIT out), and the type tables as static data.

Release builds let the C compiler inline, with the frames restored from DWARF (see Debug information); development builds
keep exact frames, and the parity runner uses them. In release the four stack programs (throw-string, try-rethrow,
jit-stack-trace, defer-exception-stack) and `nested-call-stack` print the JIT's traces, also with `--no-inline` (where gcc
and clang inline the chains the IR's inliner left). Measured in release (median of 5 interleaved runs, load about 4 to 6),
JIT, C inlining, exact frames: binarytrees 2.42, 2.58, 2.31 s; nbody 0.48, 0.47, 0.47 s; spectral-norm 0.41, 0.31, 0.31 s;
fasta 0.90, 0.84, 0.84 s; merkletrees 0.75, 0.78, 0.79 s; lru 0.27, 0.28, 0.28 s. Inlining by the C compiler gains nothing
measurable: the IR's inliner already took the small calls. What closed merkletrees' gap (1.09 s against the JIT's 0.86 s
before, under load) was the `Null<Int>` unboxing inline, which the JIT had and the C called `hl_dyn_casti` for; its
remaining time is the collector and `hl_make_dyn`, which the JIT boxes through its shared small-Int table inline.

Next: milestone 5, the compiler built with `hlc`; stack traces on macOS and Windows.
