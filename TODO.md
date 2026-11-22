# Haxeon follow-ups

Concrete gaps found while compiling Materia and while matching stock Haxe.
Longer-term direction is in `ROADMAP.md`.

- **A bare enum abstract value is found by package.** Enum abstracts are
  abstracts that declare values (`552099308`), and a case name resolves among
  the values of the matched abstract (`43b27f9b8`). A bare value with no
  expected type still searches every enum abstract and prefers the one in the
  current package (`BodyTyper`, tests `SamePackageEnumAbstractValueMain`,
  `AmbiguousEnumAbstractValueMain`); resolve it as Haxe does and remove the
  package rule.
- **Most of Haxe's `Type` API is missing.** Haxeon has the enum-value part, on a value of a known enum type:
  `Type.enumIndex`, `Type.enumEq`, `Type.enumConstructor`, `Type.enumParameters` and Haxe's global
  `haxe.EnumTools.EnumValueTools` (`getName`, `getParameters`, `getIndex`, `equals`), which the typer provides
  (`EnumReflection`, `StaticExtensions.enumValueTool`). The rest (`E1007: Unknown function "Type.getClassName"`) needs
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
- **No generator for shader interfaces.** NativeKit's shader toolchain
  (NativeKit ADR 0021) emits a versioned JSON reflection per program
  (`nkgpu-shader-reflection/1`). Add a generator in `packages/gpu/tools`
  that turns it into checked-in `.hx` modules, the way HXI bindings are
  generated and checked:
  - uniform blocks as `@:repr("C")` records with explicit padding, so the C
    layout equals std140, asserted with `sizeof` and `offsetof`;
  - a typed descriptor per program: its variants as an enum, binding slots,
    and the attribute layout a vertex packer must match;
  - creation through the program's C table by ID;
  - a `--check` mode for CI.

  It reads plain JSON, never `sokol-shdc`'s YAML. Writing shaders in Haxeon
  itself is a deferred plan in [docs/design/SHADERS.md](docs/design/SHADERS.md).

## Compiler follow-ups

Open items from the architecture plan's typer and service steps
(`docs/reports/2026-11-architecture-review.md`, phases 2 and 3).
The repeated type test after `__exception_matches` and typed payloads for
regular recursive generic enums are in the next section.

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
- **The collection policy.** The peak is the last collection's survivors plus
  the 1 GB trigger; a trigger tied to the live data is a policy to measure,
  not necessarily more collections.

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
- **Function type syntax.** The parser rejects Haxe's `?Int->Int` (an
  optional argument in the old syntax) and a parenthesized result
  (`Int->(Int->Int)`).
- **A local inline function nothing calls is not type-checked.** Its body is
  typed only where it is called (`LocalInlineFunctions`), so an error in one
  that is never called goes unreported; Haxe types the body at the declaration
  and reports it. Typing it once at the declaration too, and discarding the
  result, would report it.
- **Lone surrogates.** Printing a String with a lone high surrogate swallows
  the next code unit (the newline of `Sys.println`): the UTF-16 to UTF-8
  conversion takes it as the pair's low half.

## Generated code, HashLink and Wasm (haxeon-e4's lane)

Planned in this order unless noted. Timings so far were taken on a loaded
machine; re-measure on a quiet one before acting on a ratio.

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
  `docs/reference/GENERIC_SPECIALIZATION.md`, drop the nested-pattern cast,
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

- **Session memory after the IR columns chain.** The per-function stage
  memos and keeping each function as its frozen body past the encode point
  (`fa6bde3fd`) brought the signature edit below its level before the chain,
  but the server's live data is still above it and cold allocation is higher
  (`tests/perf/incremental-baseline.json`). The stages before the encode point
  still keep the generator's objects; see IR_CORE_COLUMNS.md, "Session caching
  model".

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
