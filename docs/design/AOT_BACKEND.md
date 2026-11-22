# AOT backend: C from Haxeon's IR on the HashLink runtime

Status: proposed; milestones 1 to 5 implemented (`--target=hlc`). Depends on the columnar IR (`IR_CORE_COLUMNS.md`): the backend
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
later be emitted as static C data to skip decoding (below).

**Static type tables (designed).** Start-up decodes the image: in a hello-world compile by the AOT compiler (about 100 ms
of processor time), `hl_code_read` is about 19% and `hl_module_init_aot` about 4%. It needs no IR or `HlLower` change: the
C backend already has the assembled `HlCode` it encodes, so it can emit the `hl_code` itself as static C data (types with
their `hl_type_obj`, `hl_type_fun`, `hl_type_enum` and `hl_type_virtual` parts, field and constructor arrays, names as
UTF-16 literals, globals, natives, constants, strings, the one-instruction function stubs, the function identities) and
give it to `hl_module_alloc` and `hl_module_init_aot` unchanged, which compute the runtime parts (object layouts,
enum offsets, virtual tables) as now. Two constraints shape it. Field hashes are not a pure function of names:
`hl_hash_gen` resolves a collision by the order names are first registered, and registers each name for `hl_field_name`;
so the static code keeps calling it, in `hl_code_read`'s order, at start-up (a fork function that fills the hashes of a
static `hl_code`), and that registration is itself a good part of the decode (an insertion into a sorted array per name;
making it a hash table is a separate, simple fork change that helps the JIT too). And `hl_code`'s layout becomes an ABI
between the generated C and the fork, checked as the object layouts are (`sizeof` and offsets at start-up, or a version
in `hlmodule.h`). Expected gain: most of the decode except the name registration, on the order of 10 ms per start of the
compiler, less for small programs (a hello-world executable starts in about 6 ms in all).

Layout checks: the generated code accesses object fields through C structs and globals at offsets computed by the backend
(`hl_module_alloc`'s rule). At startup, before running anything, the entry point checks each struct's field offsets
against `hl_get_obj_rt(t)->fields_indexes` and each global's offset against `globals_indexes`, and exits on a difference.
The runtime's own structures (`varray` with its `data` pointer, `vclosure`, `venum`, `vvirtual`) are never copied: the
generated code includes the fork's `hl.h` from the SDK and uses its macros (`hl_aptr`, `hl_vfields`), and enum payloads
are read at the runtime's constructor offsets, so a change in the fork's layouts is a C compile error or a startup check
failure, never silent corruption.

## The C shape

The sources go to `OUTPUT.c/`:

- `hlc.h`: what every file shares, and only that: `#include <hl.h>`, the section and inlining macros, the runtime
  helpers (`hlc_new`, the value array view).
- One `.c` file per Haxe source file (each function goes with the source most of its rows come from, so inlined code
  does not move it), so C builds run in parallel and an edit recompiles only the files whose text changed: the writer
  leaves an unchanged file untouched, so its timestamp stays. Measured on the compiler with `hl2c`, per-module files
  build in a fraction of a unity build's time and memory. A module whose C passes about 600 KB continues in
  `Module.part2.c` and so on: a C compiler's time grows with a file's functions, and the largest modules were otherwise
  the build's whole time. Each file starts with the declarations its text uses, found by its identifiers: the typedefs
  and definitions of the structs it names (a struct per object type, fields flattened from the base down, as
  `hl_get_obj_rt` lays them out with no tail padding between a base and its subclass, `f<index>` by HashLink field
  index), the natives it calls and the prototypes of the functions it names. So no file parses the whole program's
  declarations (one header of all of them was 3 MB, parsed by each of 517 files), and a declaration's change rebuilds
  only the files that use it.
- `image.c`: the module image (as little-endian 64-bit words, which a C compiler reads far faster than bytes), the slot
  table (function pointers by slot), the generated functions by C name, and the layouts to check.
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
  the convention of their libraries' `HL_NAME`: each is declared in the files that call it under a name of its own bound to the symbol
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
  `DW_TAG_inlined_subroutine` with its address ranges, abstract origin and call file and line): a physical frame becomes the chain of generated functions inlined at its call, innermost first, each named at the line
  where its caller calls it. Inlined runtime helpers (`hl.h`, `hlc_new`) are not frames: the generated function around
  them is named at the line of the helper's call. Clones the C compiler makes (`.part`, `.constprop`) are named by their
  abstract origin.

  A capture happens at every throw, caught or not, so it reads little: the first indexes the compilation units by address
  (one DIE each), and a unit's scopes are read the first time a frame lies in it. The line table is read only when a frame
  is named. Reading all of `.debug_info` at the first throw cost the AOT-built compiler half a second at start-up, as it
  throws early and catches.

Each mode keeps its objects (`OUTPUT.c/obj-development`, `obj-release`), made again when the compiler or its flags change;
the C text is the same. Where the C compiler has the flag (gcc), it compiles with `-fno-crossjumping`: it would otherwise
merge identical calls of different Haxe lines, throws most often, also in inlined copies of one function, into one call
of one line, losing the others' lines and inlined frames.

A frame's file is the path the `#line` directive wrote, as the JIT prints the module's debug file. The C compiler's line
table keeps a path under its working directory relative to it, so `/work/Main.hx` and `Main.hx` read the same there; the
image lists the directives' paths (`hlc_source_paths`), and the line table's files are matched to them by absolute path.

Platforms:

- **Linux (ELF)**: the section is `hlc_text`, bounded by the linker's `__start_`/`__stop_` symbols; frames come from
  `backtrace`, the debug sections from `/proc/self/exe`, the load bias from `dl_iterate_phdr`.
- **Windows with MinGW (PE with DWARF)**: GCC writes DWARF into the PE image too, so the same reader serves. The generated
  functions are in `.text$hlc.2`, which the linker sorts between the markers `hlc_text_first` (`.text$hlc.1`) and
  `hlc_text_last` (`.text$hlc.3`) in `hlc_stack.c`, as it sorts every `.text$` group by name (`.` is in no C symbol, so no
  COMDAT section falls between). Frames come from `RtlCaptureStackBackTrace`, which unwinds through the SEH tables GCC writes
  for every function; the debug sections are read from the mapped executable file (their names are longer than 8 bytes,
  so they are `/N` into the COFF string table); the bias is the loaded base less the header's `ImageBase`. Paths compare with
  either separator and with drive letters. An executable links libhl statically and compiles with `HL_IMPORT=extern`
  (the fork's `hl.h` lets it be defined), so references to libhl are direct rather than through a DLL's import table, and
  its entry point is `wmain` (`-municode`), as the runtime's arguments are UTF-16 there. Checked by cross-building with
  MinGW and running the six stack programs under wine in both build modes, against the JIT on Linux.
- **Windows with MSVC** (not implemented): MSVC writes no DWARF; its line tables and inline records are in the PDB. The
  section scheme is the same (`__declspec(code_seg(".text$hlc.2"))`, link.exe sorts `.text$` groups as GNU ld does) and the
  frames the same (`RtlCaptureStackBackTrace`). Naming a frame would go through DbgHelp: `SymInitialize` once, then
  `SymGetLineFromAddr64` for the file and line, and `SymQueryInlineTrace` with `SymFromInlineContext` and
  `SymGetLineFromInlineContext` for the inlined frames of a release build; the C name maps to a slot by
  `hlc_function_names` as with DWARF. DbgHelp needs the PDB next to the executable and is single-threaded (a lock around
  it). The paths a PDB records are the `#line` paths as written, so no matching against `hlc_source_paths` is needed.
- **macOS** (not implemented): no machine to test it, so it stays on the unsupported path (no frames). The design: the
  section is `__TEXT,__hlc_text` with the linker's `section$start$__TEXT$__hlc_text` and `section$end$...` symbols; frames
  from `backtrace`; the bias from `_dyld_get_image_vmaddr_slide(0)`. The DWARF is not in the executable: the linker leaves
  it in the object files (the debug map), so the build runs `dsymutil` after linking and the stack reader maps
  `OUTPUT.dSYM/Contents/Resources/DWARF/<name>`, a Mach-O file whose `__DWARF` segment holds `__debug_line`,
  `__debug_info` and the others (Mach-O section names are `__debug_*`, at most 16 bytes, so `__debug_str_offs`); the DWARF
  reader is the same once the sections are found.

Where none of these applies, `hlc_stack_init` installs a capture that returns no frames, so exceptions carry no stack. The
debugger and hot reload are JIT features and stay so.

A function the C compiler inlined is a frame when its C name is a generated function's: image.c lists the generated
functions by C name with their slots (`hlc_function_names`, sorted), which needs no exported symbols or `dlsym`. The line
rows are sorted stably (several rows share an address, and the last is its line), by a merge sort of its own, as `qsort`
is not stable in every C library.

## Driver and target selection

`--target=hlc` selects the backend as `--target=wasm32` does (`BackendTargets.parse` gives `HashLinkC`). The compile writes
the C sources into the directory `--output` names plus `.c` (`out/main.c/`). The C compiler is a typed option on the
request (`CompileOptions.cCompiler`, `--c-compiler=cc`), with the SDK it links against (`CompileOptions.cSdk`,
`--c-sdk=DIR`: the native build's `hlc-sdk` directory, made by the `haxeon-hlc-sdk` target, with the runtime headers in
`include/`, `libhl.a` (the VM library without the JIT) and `libffi.a` in `lib/` and the entry point in `src/`); with both set, the driver compiles each C
file that changed (as many at once as there are processors, the largest first; `-O2 -g1 -fwrapv -fno-strict-aliasing
-fno-optimize-sibling-calls`, in a development build `-O0 -g1 ... -DHLC_EXACT_FRAMES`: see Debug information; Haxe's
`Int` wraps, and objects are read through each other's structs; `-g1` keeps the line tables and inline records the stack
traces read and leaves out the variables and types, most of the debug information's compile time), links the executable at `--output` with the whole VM library (the loader resolves natives by
their `hlp_` symbols in the executable itself), and reports the C compiler's diagnostics as a compile error. Neither is read from the environment or from defines. They change
no IR or C text, so `CompileOptions.key` leaves them out.

## Shipping the compiler

The CLI (`haxeon`, the VM running `haxeon-cli.hl`) runs the compiler in three roles: one compile (`compiler.tools.HaxeonCompiler`,
the one-shot fallback), a compile server per project (`compiler.tools.CompilerServer`, which `build.execution.CompilerClient`
starts and reuses) and the language server (`LspMain`, `haxeon lsp`). Under the JIT each is a bytecode build of its own, made from
the checkout's sources with the pinned Haxe and cached (the session directory, `out/tools`), and every start of one JITs all of its
functions first (about a second for the compiler).

Built ahead of time, the three are one executable, `haxeon-compiler` beside the VM (`HashLinkPath.directory`), whose entry point
`tools.CompilerExecutable` takes the role from its first argument (`serve STATE`, `lsp`, else the compiler's own arguments): ahead
of time, code a role does not use costs nothing at start-up, and one file is what a release ships. `build.AotCompiler` says where
it is and whether it is current, and the CLI asks it at each place it would start the compiler on the VM:

- `CompilerClient.run` starts `haxeon-compiler serve STATE` instead of `hl worker.hl STATE`, under a worker version of its own
  (`compiler-session-v9:aot`), so a bytecode worker of the same sources is not reused once the executable is installed. A worker
  profiled with `HAXEON_COMPILER_PROFILE_PORT` stays on the VM, whose diagnostics port it is.
- `CompilerClient.runOneShot` runs `haxeon-compiler ARGUMENTS` instead of `hl compiler.hl ARGUMENTS`, on every platform.
- `haxeon lsp` runs `haxeon-compiler lsp`.

Nothing else chooses between the two: no option, no environment variable. The executable is used while it is current, that is
built from the compiler sources the CLI would otherwise build to bytecode. Its stamp, `haxeon-compiler.sources`, holds the
digest of those sources (`CompilerSources.roots` and the standard library, by relative path and content, so it does not depend on
where the files are unpacked); when the executable or the stamp is missing, or the digest differs, the CLI runs the compiler on
the VM as before. So an edit to the compiler in a checkout never runs an older compiler, and a release, whose sources are the
ones it was built from, always runs the executable. `haxeon doctor` says which: ok, stale or not built.

A release ships the executable and its stamp for each platform in the VM's directory, so a user needs no C compiler. They are
made by `haxeon dev aot-compiler [--c-compiler=CC]` (`tools.dev.AotCompilerBuild`): the native build (for the hlc SDK), the
checkout's compiler built to bytecode, `--target=hlc` of `tools.CompilerExecutable` in release mode (`HaxeonBuild.TOOL_BUILD_MODE`)
with `cc` (`gcc`, MinGW, on Windows), then the executable published by rename (`cmake/haxeon-replace.cmake`, so a running worker
keeps its file) and the stamp written last. The C sources and objects stay in `out/aot-compiler`, so a rebuild compiles only the
C files that changed. The hlc build links libhl statically, so the executable needs nothing beside it; the stack traces read its
own DWARF (`-g1`), which is most of its 39 MB. On Linux the CLI with the executable builds a one-file project cold (CLI start,
compile server start, compile) in 1.2 s against 2.3 s with the bytecode worker, and a language server session starts in 0.6 s
against 2.1 s. The `aot-compiler` suite builds it, checks each role and runs the suites that compile through the CLI with it.

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

Milestones 1 to 5 are done. `tests/aot/test-aot-programs.sh --all` passes all 645 programs of `tests/programs` with the
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
JIT is never initialized, and since this round not linked either. The SDK's `libhl.a` is `hlvm_aot` (`libhl-aot.a` in the
build): `hlvm`'s objects but for the JIT's (`jit*.c`), whose entry points the fork's `jit_none.c` gives for a VM without
it (`HL_NO_JIT_SOURCES` in `cmake/hl-sources.cmake`): `hl_jit_alloc` returns nothing, so a bytecode module cannot be
initialized or patched, and nothing writes code. `hl_jit_null_field_access`, which compiled code of both kinds calls,
moved from `jit.c` to `module.c`. The default `hlvm` and `hl` are unchanged. PCRE's own JIT is not compiled in either
library. Measured: a hello-world executable's code goes from 1.78 MB to 1.60 MB (stripped file 1.82 MB to 1.65 MB), the
compiler's from 19.64 MB to 19.47 MB; start-up is the same (about 6 ms for hello-world; a hello-world compile by the AOT
compiler about 0.1 s either way). The hot reload and debugger code stays, inert: the library is linked whole (the loader
finds natives by name), and leaving those out would need guards in `module.c` and `hlruntime.c` for a few kilobytes.

Type tables as static data: designed, not done (see Runtime image and initialization).

Release builds let the C compiler inline, with the frames restored from DWARF (see Debug information); development builds
keep exact frames, and the parity runner uses them. In release the four stack programs (throw-string, try-rethrow,
jit-stack-trace, defer-exception-stack) and `nested-call-stack` print the JIT's traces, also with `--no-inline` (where gcc
and clang inline the chains the IR's inliner left). Measured in release (median of 5 interleaved runs, load about 4 to 6),
JIT, C inlining, exact frames: binarytrees 2.42, 2.58, 2.31 s; nbody 0.48, 0.47, 0.47 s; spectral-norm 0.41, 0.31, 0.31 s;
fasta 0.90, 0.84, 0.84 s; merkletrees 0.75, 0.78, 0.79 s; lru 0.27, 0.28, 0.28 s. Inlining by the C compiler gains nothing
measurable: the IR's inliner already took the small calls. What closed merkletrees' gap (1.09 s against the JIT's 0.86 s
before, under load) was the `Null<Int>` unboxing inline, which the JIT had and the C called `hl_dyn_casti` for; its
remaining time is the collector and `hl_make_dyn`, which the JIT boxes through its shared small-Int table inline.

Milestone 5: the compiler (`compiler.tools.HaxeonCompiler`, release) builds with `hlc` in about two minutes (517 C
files, about 100 MB with debug information, 18 MB of code), and its self-compile output is byte-identical to the JIT-built
compiler's (`ba8b4e5ea782` on this base) on the first try: the parity programs had covered what the compiler uses. Bugs
the compiler's own traces found, each with a program: frames of modules in packages named the bare file
(`package-stack-trace`), gcc merging the throws of a function it had inlined into itself (same program), and the debug
information read in full at the first throw (start-up). Measured on the frozen self-compile input (median of 3
interleaved runs, `HL_GC_MARK_SERIAL=1`, cores 0 to 5, load about 3 to 5), JIT-built against AOT-built: wall 11.84 s
against 9.26 s; peak RSS 1285 MB against 1277 MB; main-thread instructions 50.9 G against 39.5 G. A hello-world compile,
which is mostly start-up: 1.15 s against 0.13 s, peak RSS 97 MB against 67 MB (the JIT compiles every function first).
Built with exact frames (no C inlining) the AOT compiler runs the same (9.0 to 9.1 s, 39.2 G instructions, 25 MB less
RSS), and with `--inline-allocation` too (9.4 to 9.8 s, 39.3 G): neither C inlining nor inline allocation pays for the
compiler, so both stay as they are (inlining in release, as traces lose nothing; inline allocation opt-in). The AOT build
allocates about 4 MB more than the JIT's over the compile (1.936 GB against 1.932 GB): see below. This base
predates the scalar-valued maps of the fork and of `origin/main`, so the box counts here are the old ones (about 4.8
million scalar box requests in a self-compile, nearly all served by the shared Bool and small-Int boxes): the fork pin
has the new maps API, which this base does not use.

Stack traces on Windows: programs built with MinGW have the JIT's traces (see Debug information), checked by
cross-building the six stack programs and running them under wine in both build modes; MSVC and macOS are designed there
and take the no-frames path until built.

Build speed. The compiler's C build took about two minutes, of which the Haxe compile is about 27 s; the C compile was
the rest, at about 630 s of processor time with a few files over 15 s each. Changes: each file declares only what it uses
(the 3 MB header of every declaration had been parsed by each of 517 files); modules over about 600 KB of C are split
into parts; files compile as many at once as there are processors, the largest first; `-g1` instead of `-g` (the line
tables and inline records are all the stack traces read; the six stack programs pass in release, with `--no-inline` and
with clang); the module image as 64-bit words. And the largest gain was outside the C: HashLink started each compile with
`fork`, which from the 2.5 GB compiler process copied its page tables and then made it fault on each page it wrote, so
the C compiles ran one to three at a time for half the build; the fork's `hl_process_run` now starts commands with
`posix_spawn` on Linux and macOS, falling back to `fork` where it cannot. Measured (16 processors, other work at a load of
about 5 to 14): a clean release build 110 s before, 64 s after (the C part from about 83 s to about 36 s, all 16 compiles
busy throughout); a build after editing one function body 26 s before and 28 s after, the Haxe compile and one C file both
times; a clean development build, now `-O0`, 40 s, whose compiler self-compiles in 15.3 s instead of 9.5 s, with the same
output. Per-function `optimize("O1")` on the largest functions was measured and gains nothing (the time is spread over a
file's functions, not one function's size), so it is not done. A declaration change still rebuilds more files than use it
when it renumbers types or slots, as struct and native names are indices; stable names would fix that.

Where the Haxe side of a C build goes. The compiler's phases are reported for a C build as for a HashLink one
(`CompilerDriver.writeC`: the compile, writing the C, the C compiler; the C emission is the backend's publication phase).
Measured on the compiler's own sources, release, stock-built compiler on the VM (load about 6 to 8): to HashLink bytecode
19.2 s, to C 26.7 s. The same frontend, typing and IR; the C build adds the C emission, 7.1 s (lowering functions 4.1 s, each
file's declarations 1.9 s, the module image 0.8 s and its declarations 0.3 s), and the HashLink assembly before it lowers every
function to bytecode too (1.9 s), which the C backend reads only for the image's signatures; writing 105 MB of C is 0.3 s
(1.3 s when it compares against an earlier build's files), and splitting modules into files 0.1 to 0.3 s. A file's
declarations came from five `indexOf` scans for name prefixes, two of them over the file concatenated with its declarations;
one pass now reads each identifier once (`HlcNames`), a `#line` path is quoted once, and the image's words are written digit by
digit. The C is byte-identical; the emission went from 7.1 s to 5.3 s on the JIT. With the AOT-built compiler, which is what
builds a release's: the C build's compile from 17.1 s to 14.8 s, main-thread instructions 79 G to 64 G (its HashLink build of
the same sources: 10.4 s, 44 G). What is left of the difference: the C emission (3.9 s built ahead of time), and the bytecode
lowering of function bodies the C backend does not read (1.4 s), which needs `HlLower` to intern without lowering (the types,
constants and natives a body names are interned as it is lowered). The `aot-compiler` build of `tools.CompilerExecutable` also
pays a frontend restart (graph 8.6 s against 1.5 s) for standard library modules only typing finds (`haxe.io.BytesHex`,
`haxeon.DynamicOps`); that is the frontend's, not the C backend's.

Per-function C emission in parallel (designed, a later track). Each function lowers into its own text and files are joined in
slot order, so the output stays deterministic; declarations are per file and independent once lowering is done. What is shared
and mutated while lowering, and must be settled first: the HashLink symbol table interns a type the first time a value asks
for it (`typeOf` through `HlRemap.typeIndex`), the inline allocation descriptors are numbered on first use
(`allocationIndex`), the `#line` paths are recorded (`linePath`), and `readsValueArrays` is set. A sequential pre-pass that
interns every value type of every body and numbers allocation types in slot order would leave lowering read-only on the module,
and the rest are per-function results merged in slot order. The workers would be `compiler.core.Parallel` threads, as the C
compiles are; the limit is the collector, since emission allocates strings at a high rate, so the gain would be less than the
core count. Peak memory would not grow: the C text is all held at once already (2.1 GB peak for a C build of the compiler
against 1.3 GB for its bytecode build).

The AOT-built compiler allocates about 4 MB more than the JIT-built one over the self-compile (1.936 against 1.932 GB): 3.8 MB in
`backend-functions` and 0.4 MB in `ir-assembly`. An allocation census of both builds by type finds it: 284,000 more 16-byte
untyped blocks built ahead of time (and 17,000 fewer Int boxes), at `HlSymbolTable.internType`. There a generic map's value
(`IrTypeMap<Int>`, erased to Dynamic) is cast to `Null<Int>` by `hl_dyn_castp`, in both backends; the runtime returns the box
as it is only when it is a collector pointer (`hl_is_gc_ptr`, as a JIT box on the stack must be copied), else it allocates a
copy. The JIT's `ToDyn` allocates a fresh box inline (`emit_box_alloc`), so the cast returns it; the C backend boxes through
`hl_make_dyn`, which gives the shared small-Int boxes (`hl_static_ints`), which are not collector pointers, so each lookup of a
small Int allocates. The fix is the runtime's: `hl_dyn_castp` returning a shared static box as it returns a collector one
(they are immutable and never on a stack), which removes the copies for the JIT's static boxes too. Not done: it is a fork
change.

Next: macOS and MSVC stack traces when they can be built; the static type tables; the static boxes in `hl_dyn_castp`; skipping
the bytecode lowering of bodies for `hlc`; stable struct and native names (an added class renumbers types, and a rebuild of the
compiler then compiles 629 of its 642 C files again); the
self-compile against `origin/main`'s map changes.
