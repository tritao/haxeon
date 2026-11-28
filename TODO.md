# Haxeon follow-ups

Concrete gaps found while compiling Materia and while matching stock Haxe.
Longer-term direction is in `ROADMAP.md`.

- **App runners: what step 1 left** (`docs/design/PROJECT_BUILDS.md`).
  A package with native
  sources and no `[native.cmake]` cannot join a runner's graph. Under
  `--watch`, an edit to native code needs a restart.
- **Rough edges met writing the user guides** (`docs/guides/03` to `05`).
  - `--capture` takes `frame.png` with `import -window TITLE`, which matches
    names without case and can pick GTK's hidden 10x10 leader window, named
    after the executable: an app whose title is its executable's name in
    another case (`haxeon create hello` makes "Hello" in `hello`) gets no
    `frame.png` ("Resource temporarily unavailable"). Capture by window id.
  - `--frames=N` counts drawn frames, and an idle window draws none, so an
    app run with a large N (`--frames=400`) never stops.
  - A package's CMake configure prints a warning that `HAXEON_NATIVE_OUTPUT_DIR`
    and `HAXEON_TARGET` were not used, when its project does not read them.
  - `haxeon ffi import --help`, or any unknown option, is an uncaught
    `InternalError` (exit 70) instead of a usage error with the options.
  - Naming an FFI record without importing its interface module
    (`new geo_point()` without `import Geometry;`) reports `Missing module
    "geo_point"` at line 1, column 1, with no hint about the import.
  - An `ffi.imports` recipe cannot call a package's own `[native] sources`:
    they link `<package>.hdll`, while the importer's `library` resolves to
    `lib<name>.so`, so the call fails at run time ("Could not open ordinary
    C library"). Only `[native.cmake]` with `library` works for it.
  - `TextField` with a style loses its whole default style (height, padding,
    corner radius), and the default is private, so a field cannot change only
    its width.
  - `NavigationStack` paints its screens with a fixed phone colour
    (`NavUi.ground`), not the theme's, so it stays light under `Theme.dark()`.
  - Nothing installs the Android SDK and NDK into `.tools/android-sdk`, which
    the Android build requires; `docs/reference/ANDROID.md` says they live
    there but not how they get there.
- **Spike: bundle a C compiler with Haxeon** (after the app template). Apps
  that use native packages build C and C++ with the user's toolchain
  (`docs/design/WEBSITE.md`, native code), which on Windows means Visual
  Studio Build Tools. Build NativeKit and an ahead-of-time app with a pinned
  `zig cc` on Linux and Windows: correctness, the size it adds, and whether
  its GNU ABI mixes with the MSVC-built VM and runtime. macOS keeps the Xcode
  tools (Apple's SDK is not redistributable) and Android the NDK either way.

- **Most of Haxe's `Type` API is missing.** Haxeon has the enum-value part, on a value of a known enum type:
  `Type.enumIndex`, `Type.enumEq`, `Type.enumConstructor`, `Type.enumParameters` and Haxe's global
  `haxe.EnumTools.EnumValueTools` (`getName`, `getParameters`, `getIndex`, `equals`), which the typer provides
  (`EnumReflection`, `StaticExtensions.enumValueTool`). On a class or enum named at the call, `getClassName`,
  `getEnumName`, `getEnumConstructs`, `getInstanceFields`, `getClassFields`, `createInstance` and `createEmptyInstance`
  are written out by the typer (`TypeReflection`). The rest (E1009, "needs classes and enums as runtime values") needs
  classes and enums as runtime values; the design is `docs/design/TYPE_VALUES.md` (reviewed by haxeon-e4, decisions
  for the user listed at its end). Haxe libraries that serialize, log or load plugins need it. In phases:
  2. `Class<T>`, `Enum<T>` and `EnumValue` on HashLink, wasm32 and wasm-gc: one `TypeDescriptor` per declaration,
     `getClass`, `getEnum`, `getSuperClass`, `getClassName`, `getEnumName`, `getInstanceFields`, `getClassFields`,
     `getEnumConstructs`, `allEnums`, `typeof`, a class named as a value (`Main.twice()` with a `Dynamic` first
     argument), Haxe's `EnumTools` on an enum, and `enumConstructor`/`enumParameters` on `Dynamic`. Slice 3 needs
     `ClassId` lowered on every backend (`INTERFACE_VALUES.md`).
  3. `resolveClass`, `resolveEnum`, `createInstance`, `createEmptyInstance`, and `createEnum`, `createEnumIndex` and
     `allEnums` on an enum held as a value (on an enum named at the call they are written out by `EnumCreation`), once
     a port needs them. A type named only by a string defeats pruning: the note proposes Haxe's `-dce std` rule.
- **A `Dynamic` cast straight to an array of structures fails at run time.**
  `var points:Array<{x:Int}> = dynamicValue;` throws "Array element type
  mismatch" when the array holds records of another anonymous type; Haxe
  accepts it unchecked. The array is kept as a storage view, and only an array
  inside a record is copied (`ConversionResolver.structuralCopyTarget`).
- **`trace` with several values prints differently from Haxe.**
  `trace(a, b, c)` prints `2, 1, 1`; Haxe prints `2,1,1`.
- **Warm builds still track subclasses' reads of base-class statics.**
  Statics are no longer inherited (`f1e69062`), so a base class adding or
  changing a static cannot change a name in its subclasses. The dependency
  edges that link them can go, so such an edit no longer retypes them.
- **No event signal type in the standard library.** Applications hand-roll
  listener lists. (`haxeon.reactive.Signal<T>` is a reactive value, not an
  event; pick a name that does not clash.) Add a general synchronous event type:
  - `connect(handler)` returns a `Connection`, removed with
    `disconnect()`, never by comparing closures for equality;
  - the firing side is a separate, private object, so only the owner can
    emit;
  - the payload is one type parameter, so several arguments are passed as
    a struct.

  Beartooth decided against C#-style delegates or events as a language
  feature and relies on this type for UI and tools instead (its engine
  events are queued channels, a separate thing).
- **No HTTP server.** NativeKit has the `nk_http` client and `nk_transport`
  listeners, but nothing serves HTTP. Beartooth needs one for the game
  server's asset endpoint and for its asset service (Beartooth
  `plans/NET.md` ND-D14, `plans/ASSETS.md` AS-D9):
  - HTTP/1.1 with keep-alive, request and header size limits, streamed
    request bodies (uploads are verified while they arrive) and file
    responses with `Range`;
  - Server-Sent Events, or a long-poll, for watching channel heads;
  - polled from the host event loop like `haxeon.rpc`, with bounded queues;
  - no TLS: a reverse proxy terminates it.

  The server itself belongs in NativeKit as `nk_http_server`: llhttp for
  parsing on a private libuv I/O loop, with file responses served on the I/O
  thread (NativeKit ADR 0020, proposed pending a spike). Haxeon binds it
  through HXI and polls its events. HashLink's `uv.hdll` then has to share
  NativeKit's libuv or be disabled, so the process links one copy.
- **No BLAKE3.** Beartooth addresses stored bytes by BLAKE3-256
  (`plans/ASSETS.md` AS-D3). Bind the official C implementation, with its
  SIMD paths, through HXI: one-shot and streaming hashing, checked against
  the official test vectors.
- **Simplify NativeKit shader reflection.** Upstream `bare_json`, declared
  uniform layout, and live shader replacement are tracked in
  [docs/design/APP_PLATFORM_CLEANUP.md](docs/design/APP_PLATFORM_CLEANUP.md)
  step 7. Writing shaders in Haxeon itself is deferred to
  [docs/design/SHADERS.md](docs/design/SHADERS.md).

## Compiler follow-ups

Open items from the architecture plan's typer and service steps
(`docs/reports/2026-11-architecture-review.md`, phases 2 and 3).
The repeated type test after `__exception_matches` and typed payloads for
regular recursive generic enums are in the next section.

- **`new C()` on a class with no constructor compiles.** Haxe rejects it
  ("C does not have a constructor"), even when the instance fields have
  initializers; an inherited constructor, even a private one, is accepted.
  `CallResolver.typeConstruction` should fail with E1008 when neither the
  class nor a base class gives it one, and the implicit-constructor path it
  falls into then goes.
- **An anonymous type is recorded twice.** `AnonymousTypeRegistry` walks a
  type once to attribute its structures to the unit being typed
  (`TypingSession.recordAnonymousUse`) and once to add them to the unit's
  output (`TypingOutput.discoverAnonymous`): two records of one fact, the
  kind of drift that made warm builds differ from fresh ones. Record once in
  the unit's output and derive the unit attribution at merge.
- **A deferred structure record assumes its unit is still being typed.** A
  structure whose fields are not known yet is recorded when they are
  (`Monomorphs.whenKnown` in `AnonymousTypeRegistry.recordUses`), into the
  output of the unit being typed then. That is the unit that met it as long
  as no check outlives its unit, which holds but is not checked; fail with an
  internal error when a deferred record runs after its unit's output was
  merged or dropped.
- **Reachability on the query engine: one liveness result per function.**
  When pruning moves onto the engine (`docs/design/QUERY_ENGINE.md`,
  whole-program steps), whether a function is live should be its own query
  read by the stages after it, so a whole-program walk changes only the
  functions whose liveness changed, as Nimony's DCE writes one live set per
  module (`doc/internals/ic.md` there). The redo of the early prune still
  needs each helper recorded with what it serves
  (`docs/design/WARM_REBUILD_REUSE.md`).
- **A persistent standard-library cache (low value for now).** Nimony builds
  its standard library once per compiler build and options key and shares it
  between builds. Haxeon loads only the standard-library modules a program
  reaches, so a small program's compile is already short: a program using
  `Map`, `StringBuf`, `haxe.Json`, `StringTools`, `Reflect` and `Date`
  compiles in about 0.1 s in the worker, against about 1 s for the whole
  `haxeon build`. Measure the standard library's share of a large program
  (the self-compile, the app) before planning it. The cacheable layer would be
  the typed or early IR of standard-library functions (passes, pruning and
  specializations depend on the program), once the typer runs on the query
  engine and memos own their outputs (ADR 0003 decisions 11 and 14).

- **An interface met through an inherited inferred method is not re-checked.**
  When a class implements an interface through a method it inherits, and that
  method's inferred signature changes, a warm build does not check the
  implementation again. Untested; left over from step 2.5
  ([LAZY_DECLARATION_TYPING.md](docs/design/LAZY_DECLARATION_TYPING.md)).
- **Root cause of `ce0f9ab00`.** That commit fixed a failure seen only under
  the self-hosted compiler by marking a function inferred where the signature
  table holds it too. Why it failed is not fully understood; object identity
  across `SemanticProgram.replaceBodies` is the suspect.
- **Generic code is typed twice** (plan step 2.7). A generic body is typed
  once with its own type parameters (diagnostics, the declaration's type)
  and again for each representation it is code for (erased, or per
  specialization), because the typer elaborates the representation
  (boxing, `TToDynamic`/`TAbiCast`, `TCopy`, layout constants, helper
  choice) while it types. Stage 1 of
  [GENERIC_TYPING_ONCE.md](docs/design/GENERIC_TYPING_ONCE.md) removed the
  repeats that were the same typing and the `mentionsDynamic` heuristic.
  Stage 2, elaboration as a pass after typing, is approved (2026-11-18)
  under haxeon-e4's contract in that note. Service lane, in order:
  1. Stage 2 items 1 to 3: boundaries, layout constants and helper choice
     for a type parameter recorded by the typer and inserted by the pass,
     byte-identical, with the equivalence test made permanent. Done for
     paths 6, 7 and 8 under `--elaborate-generics`; the programs that still
     differ are listed with their reasons in
     `tests/driver/elaboration-known-differences.txt`. Besides item 4,
     two groups there are representation decisions items 1 to 3 did not
     name: a constrained type parameter's member reached through its bound,
     and iteration and key-path arguments a specialization makes concrete.
     The iteration-argument group now reaches the standard library: under
     `--elaborate-generics`, `Lambda.exists(array, value -> ...)` fails to
     type in `Lambda.hx` ("expected T, got String") with any element type,
     and `std.process.Command` calls it, so every program that starts a
     process (`std-process`, `stdlib-process`) is listed. A five-line
     program with `Lambda.exists` over an `Array<String>` reproduces it.
  2. Finish step 2.4: type the parser's repaired syntax with the real typer,
     then delete the language service's approximate typer (the item below).
  3. The Android reload crash (below).

  Items 4 and 5 (nested generic calls and structured lambda names, then the
  pass replacing paths 6 to 8) have the naming function (`GeneratedNames`,
  `63914ff7d`) and wait for the boundary contract with haxeon-e4.
- **`haxeon lint` reports usage errors as `InternalError`.** `UsageError`
  (exit 2) exists since `43ece64c9`, but `LintCommand` still throws
  `InternalError` for a missing `--only` or `--manifest` value and an unknown
  rule, as does `HaxeonCli` for a missing project file.
- **`haxe.io.Error.Blocked` became `InternalError("Blocked")`.** `24db87fe1`
  changed `ProcessOutputCapture.read`. Blocked is a control-flow signal, not a
  failure: throw the enum value again.
- **Lint rules cannot type many stdlib modules.** `tools.TypedLint` types
  each file through the language service, which fails on many stdlib modules
  with "Duplicate type name". Run the typed rules (`unbound-local`,
  `throw-non-exception`) on the build's own compilation instead.
- **`@:pure` is written by hand on `haxe.Exception`.** Its constructor and its
  caching `stack` getter carry it (`stdlib/haxe/Exception.hx`, `0db84ca90`).
  Natives should declare their effects, so purity inference derives this.
- **Android: a body patch after a domain reload crashes.** The app gets SIGSEGV
  in `hl_alloc_obj` under `string_from_f64`. The patch bytes are the same as
  the old build path's, so the cause is in the host or runtime, not in
  `ce88bb128`. Queued for the service lane after step 2.4.
- **Android: a rejected edit leaves the server session ahead of the device.**
  The next edit is correct but cold. A refusal that reports the device's
  revision, as `LiveRefusal` does for the desktop host, would let the session
  take the edit back ([ANDROID_BUILD.md](docs/design/ANDROID_BUILD.md)).
- **`test-dap-hot-reload.sh` cannot run here.** It is rewritten
  (`tests/integration/test-dap-hot-reload.sh`) but needs haxelib and neko, and
  the vendor Makefile no longer links, so it stays in `tests/unregistered.txt`.
  It relies on dap-cli 0.3.0's undocumented `__dapCliInitialBreakpoints`.
- **A shared helper's owning module is its first requester's.** `ff7e29aac`
  gave a helper its subject's span, but its origin is still the first unit
  that asked for it. Fixing it needs the invalidation work in
  [HELPER_OWNERSHIP.md](docs/design/HELPER_OWNERSHIP.md) (ADR 0003 M4).
- **Delete the language service's approximate typer (step 2.4, last piece).**
  Since `7baff2763` a failed body is dropped and the rest is typed, but a
  failed body has no typed information, so completion inside the function
  being edited, and in a module that does not parse, still uses the syntax
  fallback. Decided (2026-11-18): type the parser's repaired syntax with the
  real typer. Queued for the service lane after stage 2 items 1 to 3 of
  step 2.7.

### Direct SSA follow-ups

From [DIRECT_SSA.md](docs/design/DIRECT_SSA.md)'s trade-offs: the generator
builds SSA as it emits, so there is no form over mutable locals to rebuild
SSA from.

- **One SSA builder.** `IrLocalsBuilder` (locals) and `IrBuilder` (explicit
  phis, used by the passes) are separate. Merge them, locals as an option, so
  passes that restructure control flow repair SSA through the same machinery
  the generator uses.

### Structure after the memory work

Design debt and levers left once the peak work lands:

- **Finish moving the IR stages onto bodies.** The decision is a full
  migration to bodies edited in place ([IR_CORE_COLUMNS.md](docs/design/IR_CORE_COLUMNS.md)),
  and several passes run on bodies already; the stages before the encode
  point still work on objects.
- **The checked-arena runtime.** The fork's write tracking, evacuation and
  layout registration are unused by the compiler (the pilot did not pay,
  [ARENAS.md](docs/design/ARENAS.md)). Either make it a language feature with
  users and tests, or shrink it to what is used.
- **Ownership by lifetime instead of one-shot switches.** Several "when no
  session is kept, release X" points exist; build data should live in a build
  scope and session data in a session scope, so a one-shot compile just drops
  the build scope and the two modes cannot drift.
- **Finish integer identities** (ADR 0003 M3,
  [INTEGER_IDENTITIES.md](docs/design/INTEGER_IDENTITIES.md)): binding and
  symbol ids everywhere rather than one string key at a time.
- **Parallel compilation** (ADR 0005): typing per class and lowering per
  function are natural units; the largest wall-time lever left.
- **Language-service latency.** The perf guard benchmarks compile-server
  edits (`scripts/perf-guard.py`, incremental part); language-service
  rebuilds (latency, memory) are not benchmarked.
- **Delete the transitional reuse paths.** `IrLineage.handedOn`, the
  `stableGenerated`/`generatedSources` bridges and the static-check copies go
  once static-null-checks and object reflection are per-function passes; then
  a per-stage recording view (one code path for one-shot and session builds,
  as `HlLoweringView` does) and one fact-print table in place of `IrFacts`,
  `HlFactPrints`, the inliner's prints and `IrVerifyMemo`'s string compare.
- **Null safety on the rest of `compiler.ir`.** `compiler.ir.pipeline` needs
  `IrAssembly`'s per-stage tables made non-null per phase, `compiler.ir.gen`
  needs the SSA builder's null sentinels and the frontend calls that return
  `Null` reworked, and `IrLoopBounds` keeps state set by `reset()`.
- **One scripted reorganization commit** at a quiet point: `ir/model` into the
  `ir` root, `compiler.hl` to `compiler.backend.hl`, `compiler.tools` to
  `compiler.driver`, `src/tools` to `src/cli`, `src/runtime` to `src/live`
  (`scripts/apply-ir-layout.py` does the moves). `IrGenerator.hx` is a better
  split candidate than any folder merge.
- **Does a plain `Compiler` build live by default?** The Compiler API with
  default options builds live (field migrations and all); decide whether that
  is the intended default.
- **The one-shot collection policy.** The peak is the last collection's
  survivors plus the 1 GB trigger; a trigger tied to the live data, as the
  compile server now uses (`ProcessMemory.compileServer`), is a policy to
  measure for one-shot compiles too, not necessarily more collections.

### Generated code optimizations

Semantic and whole-program optimizations go in the IR (every backend gains, the
IR has Haxe's types, nullability, purity and the class hierarchy, and the cost
is paid at compile time, not at every start); machine-level ones in the fork's
JIT. Heavier passes run in release builds only, written on IR bodies.

- **First: measure.** A generated-code benchmark set in CI, and
  `IrOpportunityCensus` over real programs (the compiler, the apps), to rank
  the passes below by counts rather than by guess.
- **IR, likely order:** devirtualization through the class hierarchy (direct
  calls, then inlining behind them; devirtualized calls recorded as
  dependencies so hot reload and live patching invalidate them); global value
  numbering with loop-invariant code motion; escape analysis across calls
  (per-function summaries, so more allocations become locals); sparse
  conditional constant propagation.
- **JIT and VM:** keeping values in machine registers across operations; fused
  or unchecked opcodes that let IR proofs pay (bounds checks on plain
  `Int`/`Float` arrays, fused on ARM64); a profile-guided tier only much later.

### Known differences from Haxe still open

The Haxe code Haxeon rejects or runs differently is listed in
[LANGUAGE_SUPPORT.md](docs/reference/LANGUAGE_SUPPORT.md#not-yet-supported).

- **`haxe.io.Bytes.ofData` and `fastGet`.** Both take Haxe's `BytesData`,
  which Haxeon has no type for (`getData` returns the raw `hl.Bytes`). On
  HashLink it is an object holding the pointer and the length; here it would
  also have to keep the Bytes that owns the memory alive. Needs a decision on
  the type and on `getData`'s result.
- **Type names Haxe keeps and Haxeon's types drop.** A missing-member error
  spells a function type without its argument names (`Int -> Int`; Haxe:
  `(a : Int) -> Int` when the type has them) and a typedef'd structure by its
  fields instead of its name (`Point`): `TFunction` carries no argument names
  and a typedef resolves to its structure. Needs a decision on carrying
  display names in `CompilerType`.
- **A callback declaring `Void` does not fix a type parameter.** Given
  `function keep<T>(run:Void->T):T`, `keep(function() { n++; })` types, but
  `keep(function():Void { n++; })` fails with E1003 ("Cannot infer the type
  parameter "T" of a callback's result where it is passed to "keep""); Haxe
  infers `T = Void` from the declared result. The parameter is filled from
  the callback's result through the variable `CallResolver.openResult` makes,
  and a declared return type apparently leaves that variable unfilled. Met in
  `packages/ui/tests/haxeon/FrameworkSmoke.hx`, which passes such a callback
  to `ReactiveRuntime.withTracking<T>` through a local typed `Void->Void`
  instead.
- **Function type syntax.** The parser rejects Haxe's `?Int->Int` (an
  optional argument in the old syntax) and a parenthesized result
  (`Int->(Int->Int)`).
- **A local inline function nothing calls is not type-checked.** Its body is
  typed only where it is called (`LocalInlineFunctions`), so an error in one
  that is never called goes unreported; Haxe types the body at the declaration
  and reports it. Typing it once at the declaration too, and discarding the
  result, would report it.
- **Maps.** A `Map` typed as `Dynamic` still prints its runtime handle
  (`~map_string_i32:...`), since its key and value types are gone. An explicit
  cast of a map of maps to `Map<String, Dynamic>` crashes in the runtime cast.
  Enum keys iterate in insertion order where Haxe on HashLink prints them in
  declaration order.
- **Generic owners specialized only from annotated members.** An owner whose
  member holds its parameter inside a structure is specialized (`3c1041b09`),
  but only when the member's type is written; one inferred from the body is not
  checked.
- **A failed bounds check reports the wrong line on HashLink:** an uncaught
  out-of-range read is reported at the function's `return`, where the C
  backend reports the access.
- **Anonymous structure field order** differs between a stock-built and a
  Haxeon-built program (watch-event JSON: alphabetical against declaration
  order). Haxe leaves it unspecified; decide what Haxeon guarantees and match
  stock HashLink where users see it (`haxe.Json`).
- **`@:structInit` classes (next typer batch).** Haxe builds an instance of a
  `@:structInit` class from an object literal wherever the class is the
  expected type: a typed local, an argument, a return or a field. Fields with an
  initializer may be left out; a declared constructor takes the literal's
  fields as its parameters by name. Haxeon has no `@:structInit`. Lower the
  literal to `new` plus the field stores, through the expected-type path that
  object literals already use. Then convert the UI style classes
  (`packages/ui/src/haxeon/ui/LayoutStyle.hx` and similar: their
  defaults move from `new()` to field initializers; check the generated
  `Diffable` field masks) and the guides that write `new LayoutStyle()`
  followed by field sets.
- **C#-style object initializers, only if `@:structInit` leaves real gaps.**
  `new T(args) { field = value, ... }` would add constructor arguments plus
  fields, sets through property setters, and nested updates of an existing
  object, but it is a Haxeon-only dialect: code using it no longer builds with
  stock Haxe, and the parser, formatter, language service and lint all need
  it. Decide after the UI conversion above shows what `@:structInit` cannot
  express. If it goes ahead, write a design note first: the exact syntax (not
  valid Haxe today), lowering to `new` plus ordinary assignments, and where
  Haxeon-only syntax is allowed (apps and Haxeon-only packages, not packages
  meant to build with stock Haxe).
- **A class, interface or `Dynamic` value where a structure is expected.**
  `var o:{} = new Thing();`, `var p:{x:Int} = thing;` and
  `var m:{function f():Int;} = thing;` are `E1002`; Haxe accepts all three,
  and a write through `p` reaches the object. A structure is lowered as a
  class of its own, so a rule in `TypeRelations.isAssignable` alone would read
  another class's field slots (on Wasm GC the cast traps), and copying into a
  record (tried in `c618c16d8`, reverted) breaks identity and loses writes.
  It is slice 4 of [STRUCTURE_VALUES.md](docs/design/STRUCTURE_VALUES.md),
  after slices 2a (an IR structure type, `dyn` on HashLink) and 2b (per-field
  dispatch). Haxe's rules there, checked with `--interp`: a method fits
  `{function f():Int;}` but not `{f:()->Int}`; `final y` fits
  `{final y:Int;}` but not `{y:Int}`; a `(get,never)` property fits only a
  structure field with the same access; a var fits `{var x(default,null):Int;}`;
  private and missing fields, enums and abstracts are rejected; `Dynamic` to a
  structure is an alias, not a copy.
- **A function returning a value where `Int->Void` is expected.** Haxe
  accepts it and drops the result; Haxeon rejects it. Decide whether that
  stays with `Void` as the unit type ([ERROR_MODEL.md](docs/design/ERROR_MODEL.md))
  or follows Haxe.
- **`new` through a typedef, edge cases.** `typedef Q<T> = Box<Array<T>>`
  then `new Q(5)` types as `Box<Int>`, where Haxe rejects it: the typedef's
  own parameters are not inferred through its target. And `new` through a
  typedef of an interface or a structure reports `E1007` "Unknown class",
  where Haxe says the type has no constructor or cannot be constructed.
- **Lone surrogates.** Printing a String with a lone high surrogate swallows
  the next code unit (the newline of `Sys.println`): the UTF-16 to UTF-8
  conversion takes it as the pair's low half.

## Generated code, HashLink and Wasm (haxeon-e4's lane)

Planned in this order unless noted. Timings so far were taken on a loaded
machine; re-measure on a quiet one before acting on a ratio.

- **Drop the shared host heap once the web uses wasm-gc.** On the web,
  NativeKit's Emscripten host and Haxeon's `wasm32` guest share one linear
  memory, so the host's `malloc` is replaced by dlmalloc confined to a fixed
  arena below the guest heap (`vendor/nativekit/docs/wasm-host-memory.md`,
  `NativeKit::wasm_host_allocator`, `NK_WASM_HOST_HEAP_LIMIT`). With
  `wasm-gc` the guest's objects live in the engine's heap, so the host can
  have linear memory to itself with Emscripten's own allocator, and the arena,
  its limit and the adapter can go. Before that, check what still needs a
  byte region both sides address (buffers passed by pointer, audio worklet
  memory) and give those explicit shared buffers.
- **Wasm32 output is not deterministic for a few programs.** Four Wasm32
  modules of the driver suite differed between two runs of the same commit
  (lengths 22396/22398 and 23806), seen on 2026-11-10; the source was not found.
- **HashLink string maps stop a key at NUL.** `hl_hash_gen` and the key
  comparison in `vendor/hashlink/src/std/obj.c` read a NUL-terminated string,
  so `"a\0x"` and `"a\0y"` are one key in stock Haxe's `StringMap`. Haxeon
  rejects NUL in a String, so only code built by stock Haxe (the compiler,
  tools) can hit it: never put NUL in a map key there.
- **`haxe.ds.ObjectMap` is a linear search on Wasm.** Wasm references have no
  stable identity hash, so the Wasm `ObjectMap` keeps parallel key and value
  arrays and compares keys one by one: every lookup is O(n). Give both Wasm
  targets an identity-hashed map, as HashLink has.

- **Erased generic owners with a specialized receiver take the slow path.**
  The inlined fast path (`8c18d84d2`) tests only the owner's own class, so
  reading a `Box<Int>` (its own specialized class) through `Box<Dynamic>`
  takes the full accessor: 15 ns against stock Haxe's 6 ns in
  `benchmarks/structure-access`. Pick the fast path's class from the static
  types at the call site, never from guessing the program's shapes.
- **lru is still 12% behind stock** (272 ms against 242 ms; it was 316 ms).
  Compare its hot functions with stock's (`haxeon dev hl-stat --dump`) and
  fix what differs.
- **Regular recursion in generic enums is erased.** `Tree<T> = Leaf(v:T) |
  Node(l:Tree<T>, r:Tree<T>)` stores its recursive slots as `Dynamic`, so
  every recursive read is a checked cast (and `IrGenerator.nestedEnumField`
  casts back for nested patterns). Erase only non-regular recursion
  (`E<T>` → `E<Array<T>>`, which never stops specializing); type a regular
  slot with the specialized enum. Classify beside `EnumRecursion`, update
  `docs/internals/GENERIC_SPECIALIZATION.md`, drop the nested-pattern cast,
  add differential tests against Haxe (deep trees, nested patterns,
  `Null<Tree>`, generic functions over `Tree<T>`, a non-regular case still
  erased) and an enum binary-trees benchmark on HashLink and both Wasm
  targets. Agreed with haxeon-b8.
- **Plain class field reads and reads by name through `Dynamic` are slower
  than stock** (2.5× and 2.3× in `benchmarks/structure-access`). Found so far:
  arithmetic on `inline final` constants is not folded (stock folds
  `COUNT - 1`), and a loop reloads a captured value, with its null check,
  every iteration (no loop-invariant load hoisting). The by-name read is
  every dispatcher's last arm.
- **Structure values, the rest of the representation track**
  (`docs/design/STRUCTURE_VALUES.md`): slice 2a, `IrType.Structure`,
  physically `dyn` on HashLink, with development debug metadata keeping the
  logical type; then slice 2b, the guards, gated on the self-compile staying
  within noise and nbody within 3% (if missed, first skip `OGetType`'s null
  test in the JIT after a null check). The guard-miss counter comes with 2b.
  In 2a, make the exact object test an IR instruction: today
  `__object_has_exact_type` is a runtime call that passes recognize by name
  (`IrExactTypeFacts.TEST`).
- **A catch clause repeats its type test.** Each clause calls
  `__exception_matches`, then a `SafeCast` that checks again. An unchecked
  cast after a successful match drops the second check, as
  `IrExactTypeFacts` does for erased owners.
- **The Wasm targets call a runtime function for the exact object test** and
  keep their checked casts after it. Lower it inline (a type id compare on
  Wasm32, `ref.test` on Wasm GC) and use `IrExactTypeFacts` there too.
- **Register allocation uses conservative live ranges.** Each register's range
  is the hull of its live points; exact live intervals would let more values
  share a register.
- **Code size, smaller items:** `OIncr`/`ODecr` for `+= 1` (stock uses them),
  shorter anonymous-structure names, and a size-aware inlining budget.
- **Hand-built test programs declare runtime natives themselves.** A pass
  that starts calling a new runtime function breaks them
  (`IteratorTypeDescriptorMain`, fixed in `aefdb62c5`). Give
  `IrProgramAssembler`'s native registration one entry point,
  `ensureRuntimeNatives(program)`, and use it from those tests too.
- **The IR census is switched on by `HAXEON_IR_CENSUS=1`.** Behaviour switches
  belong in `CompileOptions` with a CLI flag; convert it.
- **The HashLink fork carries fixes upstream lacks:** a block that jumps to
  its own start is a loop (`696b2c1`), catch slots (`56f9452`), referenced
  registers in one stack home (`e289d5c`; upstream loses a callee's write
  through a reference in a try) and trap-region validation (`621c7ed`).
  Offer them upstream as patches, so merges stay easy. Waiting on the user's
  go-ahead, since it is outward-facing.

Held until other lanes finish: architecture plan §13 steps 4 (needs the
typer's drain order) and 5 (live pruning).

### Compiler speed

- **Optional scalar arguments through `$dispatch` (parked).** Calling a statically
  known target's flag-plus-value specialization removes most Bool box requests
  (1,265K to 329K on the self-compile) but saves no allocation, since small Ints
  and Bools already use the VM's shared boxes, and it cost +1.4% instructions:
  each specialization copies the whole method body while the boxed original stays
  for the vtable. The census put these boxes at about 0.33% of JIT time. If taken
  up again: make the boxed original a small adapter over the split body instead of
  cloning large bodies, and find the downstream cost with a symbolized profile first.

- **Live-mode server memory.** On the app template, the live server settles
  about 5% above `tests/perf/live-baseline.json` and still grows per edit. A
  heap diff between builds 4 and 12 shows about 67 IR functions with their
  bodies kept per build (held from the stage memos or the inline cache:
  `IrStageEntry.output`, `InlineMemo`, `IrLineageCell.fn`) and two large
  pointer-free blocks of unknown owner; the three retractable publications copy
  the type registry, object and inline caches and the assembler state instead
  of sharing them. The baseline predates recorded reads (`540848a15`): measure
  it before and after that commit before raising it. Sharing the publications'
  unchanged tables copy-on-write (forked maps and symbol pools, reused writer
  segments) was tried and set aside: it cut the self-compile server's live data
  by only about 4 MB and cost body edits about 7% of their instructions, since
  every lookup went through the fork. Paused behind signature-edit latency; if
  taken up again, share at publication granularity with no cost on the build's
  own lookups.
- **Signature edits.** perf-guard's signature edit retypes about 1,350
  functions, the callers of the edited constructor, which all change; the
  inliner now redoes only those (958 functions). Most of what is left is per
  changed function: typing, IR generation, the assembly stages, lowering. The
  collections are a small part (about 4% of its instructions). The edit adds
  a function (the constructor's nullable-scalar adapter), so the dense
  function, string and type indices after it move and about 2,800 functions
  are relinked and encoded again, against fresh tables (see "A new constant,
  global or function relinks the functions after it" in WARM_REBUILD_REUSE.md,
  which says why this stays). Per function, load/store forwarding's field
  dataflow is the inliner's largest part.
- **What a kept build still does per function:** `HlLoweringView.holds`
  checks every kept function's facts (about 1% of a body edit), and the
  metadata tables are interned afresh and compared with the kept ones
  (`HlLinkRecord.fits`). A change to a String constant's literal also asks
  every String constant again.
- **The body edit outside IR assembly:** whole-program purity inference (the
  recorded reads give the exact "declarations unchanged" signal a
  per-function memo needs), IR generation, the ABI description, generated
  helpers and the encode.
- **After a live patch, the server writes the whole module and its build id
  before replying,** which delays the next edit; write them after the reply.
- **The small project's VM build and check allocate about 4% more** than
  their baseline (`vm_build_allocated_bytes`, `vm_check_allocated_bytes`);
  their instructions are at it. Not yet investigated.

The 2026-11-18 profile of a self-compile (Haxeon-built release compiler,
29 s on one thread) is flat: compiler code 48%, string-keyed maps 18.5%,
allocation and GC 17.6%, string operations 7%, int-keyed maps 5%, dynamic
casts 3.6%. No caller of hashing or allocation is above 0.5%, so the
allocation work planned in `BindingWalker` and `CallResolver` is dropped
(about 0.3%). By phase: IR passes 39% (inliner 12%), typing 17%, HashLink
lowering 17%, IR generation and SSA 11%, parsing 5.5%.

- **Map runtime in the HashLink fork.** Step 1 (string keys with a known
  length, a hash index as large as the map) took the self-compile from 30.1
  to 29.0 s. Next: typed value maps (`Int`, `Bool`, `Float` stored unboxed)
  and an IR `get` that returns a found flag and the value, so a map read
  neither allocates nor casts. Then re-profile.
- **Fewer lookups.** String-map time is spread over about 80 classes; the
  lasting fix is identities as integers instead of names (ADR 0003 M3),
  staged in `docs/design/INTEGER_IDENTITIES.md`.
  Strings now cache their map hash (fork 36197c5), which cut 4%; it is a
  complement, not the fix.
- **SSA value names.** Every SSA temporary carries a `"v<id>"` String
  (`IrSsaVariables` makes each once). A temporary needs no name; drop
  the field for temporaries with ADR 0003 M3's structured identities.
- **IR type ids.** Types get ids, not interned values (payload enum values
  have no identity in Haxeon); step 1, lowering and the reachability edges
  keyed by the body's ids, is done. Next: one process-wide `IrTypeIds`,
  then server caches and kept walk records by id
  (`docs/design/INTEGER_IDENTITIES.md`, "Types").
- **Per-function scratch.** Register allocation, SSA liveness and the lowering
  tables now keep their storage across functions; the rest of SSA building,
  lowering and the inliner still allocate per function. Do them together as
  `COMPILER_DATA_LAYOUT.md`'s reusable per-function contexts, not one table at
  a time.
- **Parallel and cached compilation** are ADR 0005 (compilation units).

Waiting on the user:

- **Project tools:** packages that provide commands, pinned per project, like
  .NET local tools (`dotnet tool restore`, `dotnet tool run`). The
  content-addressed tool cache behind `haxeon dev tool-path` could be the
  restore step. Needs a design note first: manifest shape, version
  resolution, running package-provided code.
- **`hl-stat` for users:** it answers "why is my module big or slow to load"
  for anyone shipping a HashLink app, so it may belong in the user CLI (like
  `haxeon heap`) rather than `haxeon dev`.
- **A lint rule for shared mutable statics,** generalizing the compiler's
  `CompilerStaticsMain` check.

## Web app native packages

Add Emscripten support to web app runners. Use `emcmake` and the generated
`haxeon.cmake` to build the dependency graph into a native host module. Bundle
that module and connect its exports, memory contract and callback table through
`haxeon-host.js` for both Wasm targets. Migrate the UI package's per-app web build
example once the runner can build it.
