# Embedding Haxeon as a game scripting system

Status: research and design only; nothing here is built. It measures what exists today and records the decisions the
user still has to make (see [Open questions](#open-questions)).

The goal is a scripting layer in the spirit of Luau: small, fast, sandboxed, with quick iteration. Scripts are written in
Haxe, compiled by Haxeon and run inside a game that is not necessarily written in Haxe. This note compares two runtime
routes, the HashLink VM (A) and a WebAssembly engine (B), and recommends one per scenario.

## Requirements

Three questions are open, and the answer to each changes the design:

| Question | Options |
|---|---|
| Who writes scripts | **Dev**: the game's own developers, compiled with the game's tools. **Mod**: players and modders, possibly at run time, inside the game. |
| Platforms | **Desktop**: Windows, Linux, macOS; a JIT is allowed. **Locked**: consoles and iOS; no writable code, so no JIT and no downloaded native code. |
| Sandbox | **Trusted**: scripts can crash the game but are not hostile. **Untrusted**: a mod is hostile until proven otherwise. |

Whatever the scenario, the system must:

1. **Call into the game through one declared API**, and do nothing else. Game objects reach scripts as handles, never
   as pointers.
2. **Compile scripts without recompiling the game.** The game ships, and scripts change after it.
3. **Have small modules and cheap loading.** Many small scripts, loaded and unloaded as levels change.
4. **Iterate fast.** A saved edit shows up in the running game in well under a second, keeping state where possible.
5. **Set limits on untrusted code**: a list of capabilities, a memory cap per script, a time budget per call, and no
   way to corrupt the host.
6. **Run deterministically when asked to**, for lockstep multiplayer and replays: the same inputs give the same results
   on every platform.

## What exists today

Every number in this note was measured on 2026-11-22 on the development machine (x86-64 Linux, Node 26), except where
marked *published* or *estimate*. The load average was about 7 throughout, so timings carry roughly ±10% noise.

| Piece | Where | State |
|---|---|---|
| HashLink VM with JIT | `vendor/hashlink`, `out/sdk/bin/hl` | 1.85 MB of text with the JIT, statically linked: 1.9 MB stripped. |
| HashLink without JIT | `libhl-aot.a` (2.6 MB archive) | Used by `--target=hlc`. A hello-world AOT executable is 1.65 MB stripped (AOT_BACKEND.md, milestone 4). |
| Runtime module load | `hl_runtime_module_load`, `hl_runtime_module_apply_hlp`, `hl_runtime_module_call_*` (`hlmodule.h`) | Loads several HLB modules into one VM, patches them atomically, unloads them (`runtime.RuntimeDomain`, `LoadedPlugin`). |
| Live patching | `--live`, HLP ([LIVE_PATCHING.md](../internals/LIVE_PATCHING.md)) | Function-level patches with stable IDs, added types, signature adapters and guards for stored closures. |
| AOT C backend | `--target=hlc` ([AOT_BACKEND.md](AOT_BACKEND.md)) | All 645 test programs pass. The output links against `libhl`. |
| Wasm backends | `--target=wasm32`, `--target=wasm-gc` ([targets](../reference/WASM_BACKEND.md), [backend internals](../internals/WASM_BACKEND.md)) | Both are executable targets. wasm-gc is tested on Wasmtime 47 (`tests/wasm/test-wasm-gc-wasmtime.sh`). |
| Runtime-neutral profile | `--wasm-runtime-neutral` (wasm32 only) | Needs no Wasm exceptions and charges fuel through an import (`haxeon_host.fuel_charge`). Only tested on Node so far. |
| Wasm host ABI | `stdlib/haxeon/wasm/HaxeonHost.hxi` | Only C-ABI scalars and linear-memory addresses cross the boundary, so one host serves both Wasm targets. |
| HXI | `--ffi-interface=FILE.hxi`, `haxeon ffi import` ([C_HEADER_FFI.md](../reference/C_HEADER_FFI.md)) | Describes a C API. Wasm imports it by `@library` name; HashLink resolves it as natives. |
| Wasm function patches | `WasmBackend.compilePatchBase` / `compilePatch` | The compiler side exists, with stable identities, slots and an ABI check. No host applies these patches outside the tests. |
| IR interpreter | `compiler.ir.tools.IrInterpreter` | A 1,017-line reference executor of compiler IR for pass tests. It is not a VM and needs the compiler loaded. |

### A typical script, measured

The test script (`Script.hx`, 60 lines) implements an enemy brain. It has an enum with payloads, a class, an
`Array<Brain>`, a `Map<String, Int>`, string interpolation, a closure passed to `filter` and two exported entry points
(`spawn`, `update`). It calls a seven-function game API declared in HXI:

```text
interface Game @target("portable-abi32") @library("game") {
	extern fn entity_x(entity: u32) -> f32 @symbol("entity_x");
	extern fn entity_move(entity: u32, dx: f32, dy: f32) -> void @symbol("entity_move");
	extern fn entity_spawn(kind: utf8, x: f32, y: f32) -> u32 @symbol("entity_spawn");
	...
}
```

The same `.hxi` file compiled unchanged for HashLink, wasm32 and wasm-gc.

| Output | Release | Gzip -9 | Development | Functions |
|---|---:|---:|---:|---:|
| HashLink `.hl` | 3,465 B | n/a | 10,486 B | n/a |
| wasm-gc | 42,693 B | 25,756 B | 51,156 B | 57 |
| wasm32 | 467,124 B | 42,630 B | 495,359 B | 230 |
| wasm32, runtime-neutral | 492,648 B | 48,407 B | n/a | 236 |

The four benchmark programs used below (nbody, spectral-norm, binarytrees, lru) come out at the same sizes: HashLink
3–5 KB, wasm-gc 60–65 KB, wasm32 508–522 KB.

- **HashLink modules are tiny** because the standard library's natives (strings, maps, regular expressions, the GC)
  live in the VM. A Wasm module has to carry its own copy.
- **wasm32 is 11× larger than wasm-gc** because of emitted string helpers. In `Script.wasm`, six UTF-16 index and
  substring functions (`__string_substring`, `__string_index_of`, `__string_last_index_of` and their variants) are
  46–55 KB each, about 300 KB of the 446 KB code section. Each is emitted inline Wasm for UTF-16 coordinates over UTF-8
  storage. Moving them into the C linear runtime ([WASM_LINEAR_RUNTIME.md](WASM_LINEAR_RUNTIME.md)) or sharing one
  decoder loop would bring wasm32 close to wasm-gc. Until then, wasm32 is the fallback target.
- In wasm-gc the largest functions are the float formatter `runtime.Ryu` (6.4 + 3.5 KB) and `__std_string` (1.5 KB).
  A script that never formats a `Float` would drop Ryu; it is pulled in by `'$n'` interpolation of numbers.

Compile time and memory for this script, one cold compile per process:

| Compiler | HashLink target | wasm-gc | wasm32 |
|---|---|---|---|
| AOT-built (`out/aot/haxeon-aot`) | 0.10 s, 36 MB peak RSS | 0.17 s, 60 MB | 0.24 s, 84 MB |
| JIT-hosted (`hl compiler.hl`) | 1.3–1.6 s, 99 MB | 1.3–1.8 s, 128 MB | 1.4–1.6 s, 159 MB |

The AOT compiler takes 0.15 s and 37 MB just to start and print an error, so a small compile adds almost nothing to
the process. In the JIT-hosted compiler, startup is mostly JIT. An in-process session that stays warm does better
still: `BenchmarkMain`'s scale run (HashLink target, `out/benchmark-scale-check.json`) gives medians of 2.4 ms for a
cold compile of 10 modules and 1.7–1.9 ms for a body edit. With 100 modules, the figures are 26 ms cold and 8–10 ms per
body edit.

## Route A: the HashLink VM

The game links `libhl` (with or without the JIT) and loads each script as an HLB module through
`hl_runtime_module_load`. Scripts call the game through natives that the game registers. In development, they are
patched live with HLP.

**What it has:**

- **The smallest modules**: 3.5 KB for the sample script.
- **The fastest code on desktop.** The JIT ties or beats V8-run Wasm on every benchmark below.
- **The most mature iteration tools**: atomic function patches that keep state, stable IDs, guards for stored
  closures, the HLD3 debugger and the profiler.
- **The same VM as a Haxe-written game**, if the game is one.
- **A ready path for locked platforms**: scripts compiled with `hlc` and linked into the game binary at build time.

**What it lacks:**

| Gap | Why it matters | Cost to close |
|---|---|---|
| No HLB interpreter | Locked platforms cannot load new scripts at run time: only `hlc` code compiled into the game runs there. `IrInterpreter` works on compiler IR, not HLB, and is a test oracle. | **XL.** A new interpreter for HLB (about 100 opcodes, plus the call trampolines `hlc` already generates), probably 8–15k lines of C to make fast. Not recommended. |
| No memory safety for untrusted bytecode | HLB has raw-memory and unchecked opcodes (`OGetMem`, `OSetMem`, `OUnsafeCast`), and the VM does not verify a module for safety. A hand-made `.hl` can corrupt the process. | **Cannot be closed for downloaded bytecode.** The only option is to compile on the device from source and trust the compiler to reject unsafe features: the compiler then belongs to the trusted base. |
| Natives are not a capability list | Natives resolve by library and name (`module.c`, `resolve_library`/`dlsym`), so any `std` native is reachable (files, processes, sockets). | **S.** An allowlist callback at native resolution, checked per module. |
| No per-script memory cap | One GC heap per process, shared by every module. | **L.** Per-module heap accounting in the GC. |
| No time budget | No fuel, and no interrupt at loop back-edges. | **M.** A JIT back-edge check against a flag; `hlc` would need the same in C. |
| Narrow call shapes | `hl_runtime_module_call_*` covers `void`, `i32`, bytes, object, closure; there is no `f64` and no multiple arguments, so calling `update(dt:Float)` needs a wrapper. | **S–M.** A generic call through `hl_dyn_call` with a typed argument array. |
| Determinism | x86-64 JIT, ARM64 JIT and `hlc` (where the C compiler may contract floating-point operations) can round differently, and math goes through the platform's libm. | **M.** Fixed math, `-ffp-contract=off`, cross-platform tests. |

## Route B: a WebAssembly engine

Scripts compile to wasm-gc (or wasm32) and the game embeds a Wasm engine. Each script is one module:

- its **imports** are the game API, one import module per HXI `@library`, plus `haxeon_host` and `haxeon_runtime`;
- its **exports** are the script's `@:expose` entry points.

**What it gives by construction:**

- **A sandbox.** Validation and bounds checks mean a module can touch only its own memory and its imports.
- **A memory cap** through the linear memory's maximum or the engine's GC heap limit.
- **Time budgets** through fuel, or epochs where the engine has them.
- **Determinism**, apart from NaN bit patterns.
- **Interpreters that run on locked platforms.**

### Engines

Sizes and features of third-party engines are *published* figures or the engines' documentation as of 2026, not
measured here.

| Engine | Execution | Size (published) | Wasm GC | Exceptions | Metering | Notes |
|---|---|---|---|---|---|---|
| wasm3 | Interpreter | ~64–100 KB | No | No | No built-in; use the Haxeon fuel import | Effectively in minimal maintenance. Can run runtime-neutral wasm32 only. |
| wasmi | Interpreter (Rust) | a few hundred KB | Planned, not implemented | Planned | Built-in fuel | Runtime-neutral wasm32 only. |
| WAMR | Classic and fast interpreters, AOT (`wamrc`), JIT | ~60–300 KB for an interpreter build, by features | Yes in the interpreter, JIT and AOT since 2.0 | Legacy exceptions in the classic interpreter; AOT exceptions reported unreliable (2026) | Engine-dependent | Haxeon's `--wasm-legacy-exceptions` matches what its interpreter supports. Its AOT emits native code, which locked platforms only accept when compiled into the shipped binary. |
| Wasmtime 47 | Cranelift JIT, Pulley interpreter | several MB (Cranelift); smaller with Pulley only | Yes, on by default | Yes (`try_table`), on by default | Fuel and epoch interruption | Pulley generates no native code, so it suits iOS and consoles; its GC and exception support is reported, not yet verified here. Haxeon already tests wasm-gc on Wasmtime 47. |
| Wasmer | JIT backends | several MB | No (to verify) | No (to verify) | Metering middleware | No reason to prefer it here. |

Which target fits which engine:

- **wasm-gc** runs on WAMR (interpreter, with `--wasm-legacy-exceptions`) and Wasmtime (JIT or Pulley).
- **wasm32 runtime-neutral** runs on everything, wasm3 and wasmi included, at the cost of size and the collector's
  speed (below).
- **Plain wasm32** needs Wasm exception handling, so it runs where wasm-gc runs and buys nothing there.

### How Haxeon's output fits an engine

**wasm-gc:**

- Managed objects are engine GC objects; there are no root maps and no shadow stack. An ordinary module has no linear
  memory. One is added (or imported with a memory contract) only for C-ABI scratch space, as with `utf8` arguments.
- The game API imports take C scalars, and a string is a `utf8` pointer into that scratch memory. The host reads it
  with a bounds check against the memory's size, which every engine's API exposes.
- Missing: wasm-gc has no runtime-neutral profile, so a GC engine without exceptions or fuel (WAMR AOT) cannot run it
  yet. Porting the `pending-global-v1` exception protocol and the fuel instrumentation from wasm32 is the gap.

**wasm32:**

- Haxeon's mark/sweep collector runs inside linear memory, with the allocator in C linked from
  `linear-runtime.wasm`. It works in any engine because it needs only memory and the shadow-frame root chain.
- The memory contract (`--wasm-import-memory --wasm-memory-contract`) lets the host set the memory's maximum, which is
  the per-script cap.
- Its collector is the slow part: binarytrees runs 4.4× slower than on wasm-gc in V8 (below).

**Imports a host must provide:**

| Import module | Functions |
|---|---|
| `haxeon_runtime` | Math functions: `__math_sin`, `__math_pow`, ... |
| `std` | `sys_exit`, `sys_time` |
| `haxeon_host` | `print`, `write_output`, `flush_output`, `date_now`, `date_timezone_offset`, `callback_create`, `callback_close`, and `fuel_charge` in the runtime-neutral profile |
| one per HXI `@library` | The game API, e.g. `game` |

Only what a module uses is imported. The sample script on wasm-gc imports exactly its seven `game` functions;
`Math.sqrt` is a Wasm instruction. It exports `main`, `Script.spawn`, `Script.update`, `memory` (scratch space for
`utf8` arguments), `table` and `__haxeon_exception`. A Node runner that stubs unknown imports ran every module in this
note.

### Performance

These are single runs repeated three times, release builds, pinned to one core, under load about 7. Times are
whole-process for HashLink and include instantiation for Wasm. The Wasm columns run in V8 (Node 26), an optimizing JIT,
which stands in here for Wasmtime's Cranelift; no Wasm interpreter was measured.

| Benchmark (input) | HashLink JIT | wasm32 (V8) | wasm-gc (V8) |
|---|---:|---:|---:|
| nbody (5,000,000) | 0.43 s | 0.44 s | 0.40 s |
| spectral-norm (2,000) | 0.35 s | 0.49 s | 2.23 s |
| binarytrees (18) | 2.3 s | 10.2 s | 2.35 s |
| lru (100, 1,000,000) | 0.23 s | 1.45 s | 1.12 s |

- **Numeric code** runs at the same speed on all three. Script logic that does arithmetic on fields is cheap anywhere.
- **Allocation-heavy code** needs wasm-gc: binarytrees on the wasm32 collector is 4.4× slower than wasm-gc. It is
  cheaper to make wasm32 rarer than to make its collector faster.
- **Map-heavy code** (lru) is 5–6× slower on both Wasm targets than on HashLink, whose maps are C natives. Scripts that
  live in maps will notice.
- **spectral-norm on wasm-gc is 4.5× slower than on wasm32.** This is unexplained and should be investigated before
  relying on wasm-gc for float arrays; a boxed `Array<Float>` representation is the first suspect.
- **Fuel through a host call is too slow.** nbody built runtime-neutral, with `fuel_charge` a JS import called at every
  function entry and loop back-edge, took 4.8 s against 0.44 s: 11× slower. The design below charges fuel inside the
  guest instead.

How Route B compares with interpreters and with Luau (*estimate*; no interpreter or Luau runs are in `benchmarks/`):

- **Interpreters**: WAMR's fast interpreter, wasm3 and Pulley typically run 5–20× slower than an optimizing JIT on the
  same module.
- **Luau's interpreter** is one of the fastest dynamic-language interpreters but pays for dynamic typing. Statically
  typed Wasm in a fast interpreter should be in the same range or ahead on numeric script code, and behind on string-
  and map-heavy code, where Luau's tables are native and Wasm carries its own maps.
- **Luau's VM and compiler together** are on the order of 1–2 MB (published). A Wasm interpreter is smaller than that,
  but the Haxeon compiler is far larger (below).

A head-to-head run is phase 0 of the plan.

## Comparison

| | A: HashLink | B: wasm-gc on WAMR or Wasmtime |
|---|---|---|
| Runtime size | 1.9 MB with JIT; ~1.6 MB without (estimate from the AOT hello-world) | WAMR interpreter ~0.1–0.3 MB; Wasmtime several MB (published) |
| Sample module (release) | 3.5 KB | 43 KB (26 KB gzipped) |
| Desktop speed | Best | Equal on numeric code; behind on maps |
| Locked platforms | `hlc` at game build time only | Interpreter, loads at run time |
| Untrusted code | No | Yes |
| Memory cap, time budget | No (L and M work) | Engine limits; fuel inside the guest (M work) |
| Live iteration | Function patches that keep state, today | Module reload with a state handoff (M work); function patches later |
| Debugger | HLD3 | Engine-specific; none integrated |

## Recommendation per scenario

| Who writes | Platforms | Sandbox | Route | Why |
|---|---|---|---|---|
| Dev | Desktop | Trusted | **A, JIT** | Everything exists: live patching, debugger, smallest and fastest modules. Add the native allowlist for hygiene. |
| Dev | Desktop and locked | Trusted | **A**: JIT on desktop, scripts compiled into the game with `hlc` on consoles | Locked platforms never load new code at run time in this scenario. Iteration happens on desktop or on a devkit build with the JIT. |
| Mod | Desktop | Untrusted | **B, wasm-gc on Wasmtime** (Cranelift) or WAMR | Only route B is a sandbox. Distribute the compiler as a modding SDK rather than inside the game unless editing in the game is a feature. |
| Mod | Locked | Untrusted | **B, wasm-gc on a WAMR interpreter or Wasmtime's Pulley** | No native code is generated, which platform rules require for downloaded content. If an engine lacks GC, use runtime-neutral wasm32. |
| Dev and mod | Any | Mixed | **A for the game's scripts, B for mods**, against one HXI API | The same `.hxi` compiles for both routes (measured above), so the API is written once. |

If only one route is to be built, build B. It covers every scenario at some cost in speed on desktop and in module
size, and A's advantages matter mainly to the game's own developers on desktop, who have them already through `haxeon run --watch`.

## Separate compilation against a fixed host API

Haxeon compiles whole programs, and a script module stays one: the script, the part of the standard library it reaches,
and the API declarations. What makes it separate from the game is only the boundary, and that boundary is a C API
described in HXI. Neither route needs the game's Haxe code, if it has any, to be compiled into the script.

**The API description** is one or more `.hxi` files:

- written by hand, or generated from C or C++ headers with `haxeon ffi import`;
- each `interface ... @library("name")` is one **capability group**: a Wasm import module, or a HashLink native
  library;
- game objects are `u32` handles: a generation and an index, which the host validates on every call;
- events are exports the host calls (`update(dt)`), or callbacks through the existing `callback_create` mechanism.

A game written in Haxe declares its script API the same way, as HXI, rather than sharing its classes with scripts.
Sharing classes would make every layout and method of the game part of the scripts' ABI, and route B could not do it at
all.

**ABI stability:**

- **An API fingerprint.** Each function's name and C signature are hashed together with the whole file. The compiler
  writes the fingerprint and the names used into a custom section (Wasm) or the module's identity manifest (HLB); the
  host checks it at load and names the missing or changed function.
- **Add-only evolution.** New functions and new groups keep old scripts working. Removing or changing a function is a
  new version; the host can keep the old export under a versioned symbol (`entity_move_v1`) for as long as old mods
  matter.
- **Wasm checks import types at link time** already, so a changed signature fails at instantiation even without the
  fingerprint. The fingerprint adds a readable error.
- **HashLink checks a native's signature when it resolves it** (AOT_BACKEND.md, natives). The same fingerprint makes
  the error readable.

**Route A versus route B:**

| | A: same HashLink VM | B: separate Wasm module |
|---|---|---|
| Script to game | Natives resolved from the game's process, filtered by the allowlist | Imports, one module per capability group, linked only if granted |
| Game to script | `hl_runtime_module_call_*` by stable ID; needs a generic call shape (`f64`, several arguments) | Exports, called through the engine's typed call API |
| Values that cross | C scalars and handles; strings as UTF-8 bytes | Same, with strings in the guest's linear memory (wasm-gc copies through scratch memory) |
| Standard library | Natives shared with the VM; types repeated per module | A private copy per module (most of the 43 KB) |
| Script to script | Not directly: each module has its own type table. Use the host API or messages. | Same: separate instances with no shared heap |

What is new: the fingerprint section and its check (both routes), the generic call shape (A), and a host-side loader
library (B, below). The compiler's driver already takes `--ffi-interface` and `@:expose`.

## Embedding the compiler

Runtime authoring, a modder editing scripts inside the game, needs the compiler in the process.

### An embedded profile

The compiler would be built by `hlc` as a static library without the CLI, LSP, formatter, the clang importer and the
backends it does not use. The estimate below comes from the object files of the current `haxeon-aot` build
(now under `out/aot/build`), grouped by the source each file comes from:

| Part | Text |
|---|---:|
| Module image (`image.o`: type tables, constants) | 2.84 MB |
| `compiler/ir` | 2.78 MB |
| `compiler/types` | 2.23 MB |
| wasm-gc backend + shared Wasm | 1.62 + 0.90 MB |
| wasm32 backend | 1.41 MB |
| HashLink backend (`compiler/hl`) | 0.56 MB |
| semantic, syntax, ffi, abi, compilation, core, modules, runtime | ~1.7 MB |
| CLI, build, project, editor, LSP service, formatter, profiler, `compiler/tools`, C backend | ~1.6 MB |
| **Total object text** (the executable: 18.6 MB text, 24.8 MB file) | 15.9 MB |

- **Route B profile** (wasm-gc only): drop wasm32, `hl` lowering where unused, the C backend and the tools. That is
  about 10–11 MB of text, plus libhl without JIT (~1.6 MB): **about 12 MB**.
- **Route A profile** (HashLink only): about 11 MB including libhl.

Either way, the embedded profile is roughly half of `haxeon-aot`. IR and typing are the bulk and stay.

That is an order of magnitude more than Luau's whole VM and compiler. It is acceptable for a desktop game with an
in-game editor, and a reason to keep the compiler out of console builds: on locked platforms, mods arrive compiled.
The standard library sources the compiler reads (490 KB of `.hx`, about 120 KB compressed) ship with it, read through a
virtual file system.

### C API

The C API is small and owns nothing of the game's:

```c
typedef struct script_compiler script_compiler;
script_compiler *script_compiler_new(const script_compiler_options *options); /* target, API .hxi texts, limits */
void script_compiler_set_source(script_compiler *, const char *path, const char *text, size_t length);
void script_compiler_remove_source(script_compiler *, const char *path);
/* Builds every entry; returns 0 and the module bytes, or diagnostics. Bytes stay valid until the next build. */
int script_compiler_build(script_compiler *, const uint8_t **module, size_t *length,
                          const script_diagnostic **diagnostics, size_t *count);
void script_compiler_free(script_compiler *);
```

`script_compiler` wraps the existing persistent `Compiler` session (the one `CompilerSession` uses), so a rebuild
reuses typed modules and IR. The scale benchmark's 2–10 ms per body edit is the expected recompile time for
script-sized projects. The options are typed `CompileOptions`, as the CLI's are; there are no defines or environment
variables.

### Memory

A cold compile of the sample script peaks at 36–60 MB RSS in the AOT compiler, of which about 37 MB is the process
started with nothing compiled.

- **A warm session** keeps its typed modules and IR. For a few dozen script files this should stay in the tens of MB
  (*estimate*; measure in phase 4).
- **The GC trigger has to come down.** The compiler shares libhl's GC with the game's own HashLink code, if there is
  any, so the 64 MB minimum trigger of the fork (and any larger setting the compiler tools use) must be lowered for an
  embedded session.
- **The compiler runs on its own thread** so a build never stalls a frame.

## Sandbox model

The rules are the same for both routes; only route B enforces them against hostile code.

**Capabilities.**

- A script's import list is its whole authority. Each import module is one capability group (one HXI `@library`).
- The host links only the groups a mod's manifest asks for and the player or game grants. An ungranted group fails at
  instantiation and names the import. The compiler can report the same thing earlier, when it is given the granted list.
- The standard library's own imports are granted separately:
  - math in `haxeon_runtime` is always granted;
  - `print` and output go to the game's log;
  - `date_now` and `sys_time` are denied in deterministic mode, which uses game time from the API instead;
  - `sys_exit` traps;
  - `sys.io.File` already runs on an in-memory store inside the guest ([WebAssembly](../reference/WASM_BACKEND.md#standard-library-on-wasm)), so it never reaches the
    disk.

**Memory.**

- wasm32 declares a maximum through its memory contract, which the host sets per script.
- wasm-gc relies on the engine's limit on its GC heap. Wasmtime and WAMR both configure a heap per store or instance;
  the exact controls are to be verified in phase 0.
- An allocation past the limit traps.

**Time.**

- Every call into a script carries a fuel budget: per frame for `update`, and a separate one for instantiation,
  because the start function runs then ([runtime-neutral profile](../internals/WASM_BACKEND.md#runtime-neutral-profile)).
- The instrumentation moves into the guest. A mutable global counter is decremented by each block's cost at function
  entry and at loop back-edges, and the host is called only when the counter goes negative. That replaces the
  host call per charge (11× on nbody) with a load, a subtract and a branch.
- On engines with fuel of their own (Wasmtime, wasmi), the host can use the engine's instead and build without
  instrumentation.
- A script that runs out of fuel traps in the middle of whatever it was doing, so its instance is discarded and the mod
  reloaded or disabled. The host never resumes it.

**Faults.** Any trap (out of bounds, out of memory, out of fuel, or a Haxe exception nothing caught) ends that instance
only. The game logs the script's stack, mapped through the name section.

**Determinism.** Wasm is deterministic apart from NaN bit patterns, which Haxe code cannot observe except through
`Bytes`. The remaining sources are host imports:

- **Math**: the host's libm differs between platforms. Fix it by linking a portable math implementation into the module
  through the C runtime, as SHA-256 already is (`crypto-runtime.wasm`), instead of importing `haxeon_runtime` math.
- **Time**: denied, as above.
- **Randomness**: `Std.random` is already a fixed-seed generator on Wasm. A seed from the game API is still needed.
- **Map iteration order**: to be checked by a cross-platform test.

Route A cannot promise determinism across platforms without the work in its gap table.

## Hot reload and iteration

**Route A** has the full machinery today:

- live HLP patches apply atomically and keep state;
- old closures are guarded;
- a body edit takes milliseconds through a warm session.

What is missing is only the embedding: the game calls `hl_runtime_module_apply_hlp` itself instead of running the live
host.

**Route B**, in two steps:

1. **Module reload with state handoff.** Before the swap, the old instance's `saveState()` export serializes what the
   script wants to keep. The new instance starts, and `restoreState(bytes)` reads it back. This is the same contract as
   `runtime.LoadedPlugin`. Script modules are tens of KB, so compiling and instantiating takes milliseconds in an
   interpreter. It works in every engine and every target, and it is what mods get.
2. **Function patches** (later, if module reload is not enough). `WasmBackend.compilePatch` already produces
   replacement functions with stable identities and ABI checks. A host must give the base and patch modules a shared
   table, memory and globals, and swap table slots atomically. Only the compiler side exists.

**The iteration loop:**

1. The editor saves.
2. The embedded session (or the SDK compiler in a server mode, as the compiler worker runs today) rebuilds in
   milliseconds.
3. The host swaps the module between frames.
4. Diagnostics go to the in-game console with `file:line`.

## Plan

Sizes: S is under 500 lines or a few days; M is up to about 2,000 lines; L is larger; XL is a project of its own.

| Phase | Work | Size | Route |
|---|---|---|---|
| 0 | **Spike.** A C host that loads the sample script built for wasm-gc into a WAMR interpreter and into Wasmtime 47 (JIT and Pulley), implements the `game` API with handles, and times `update` against the HashLink JIT. Add a Luau version of the same script for comparison. Explain the spectral-norm wasm-gc anomaly. Settles the engine choice. | S–M | B |
| 1 | **API fingerprint.** A custom section or identity-manifest entry and the host check. Granted-list checking at compile time. | S | A, B |
| 2 | **Budgets.** Guest-side fuel counter, the runtime-neutral exception protocol for wasm-gc, and the per-instance memory limits in the host. | M | B |
| 3 | **Host library.** A small C library over the chosen engine: load, link capability groups, call exports, fuel, trap reporting, reload with `saveState`/`restoreState`. Phase 0's host grows into it. | M | B |
| 4 | **Embedded compiler.** An `hlc` static-library profile without the CLI and the unused backends, a virtual file system for the stdlib, the C API above, and memory measurements of a warm session. | M–L | A, B |
| 5 | **Determinism.** In-module math, a seeded random from the API, a cross-platform replay test. | M | B |
| 6 | **wasm32 size** (only if a GC-less engine is required). Move the string helpers into the C linear runtime. | M | B |
| A1 | **Route A hygiene**, for the game's own scripts: native allowlist at resolution, a generic call shape, the game calling `apply_hlp` directly. | S–M | A |
| — | Not planned: an HLB interpreter (XL), and memory safety for downloaded HLB. | | |

Phases 0–3 give a sandboxed mod system on every platform with mods compiled by an SDK. Phase 4 adds editing inside the
game. A1 is independent and small.

## Open questions

1. **Who writes scripts**: only the game's developers, or also players and modders? If modders, at run time inside the
   game, or with an SDK outside it?
2. **Platforms**: are consoles and iOS in scope? Do they need run-time loading of scripts, or only scripts shipped with
   the game?
3. **Sandbox**: is any script untrusted? That alone decides between "A is enough" and "B is required".
4. **Determinism**: is lockstep multiplayer or replay across platforms a requirement?
5. **Engine preference**: WAMR (small, C, GC in its interpreter) or Wasmtime (Rust, JIT and Pulley, larger)? Is a Rust
   dependency acceptable in the game?
6. **Game language**: is the game C/C++, or Haxe on HashLink? This decides whether route A is free (same VM) or an
   extra 2 MB.
7. **The compiler in the shipped game**: is about 12 MB acceptable on desktop for editing in the game, or should
   compilation stay in an SDK?
