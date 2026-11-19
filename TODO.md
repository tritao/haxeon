# Haxeon follow-ups

Concrete gaps found while compiling Materia and while matching stock Haxe.
Longer-term direction is in `ROADMAP.md`.

- **Enum abstracts lose their type when lowered.**
  `DeclarationIndex.resolveNamedType` resolves an enum abstract to its
  underlying type, so a switch subject or expected type of an enum abstract
  is just `Int`/`String`, and a bare case value such as `case Box:` cannot be
  resolved against the switched type as Haxe does. `BodyTyper` works around
  it by searching every enum abstract for the value, preferring the one in the
  current package (`722504a6`, test
  `tests/compiler/SamePackageEnumAbstractValueMain.hx`). A switch over an
  enum abstract from another package still fails when two imported abstracts
  share a value name. Keep enum abstracts as `TAbstract`, like other
  abstracts, and resolve bare values from the expected type; then remove the
  package heuristic.
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
  3. `resolveClass`, `resolveEnum`, `createInstance`, `createEmptyInstance`, `createEnum` and `createEnumIndex`, once a
     port needs them. A type named only by a string defeats pruning: the note proposes Haxe's `-dce std` rule.
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
  pass replacing paths 6 to 8) wait until the naming function and the
  boundary contract are agreed with haxeon-e4.
- **CLI usage errors are `InternalError`.** An unknown option or a missing
  argument (`HaxeonCli`, `LintCommand`) throws
  `compiler.core.InternalError` since `24db87fe1`. Add a `UsageError` so a
  user's mistake is not reported as a compiler failure.
- **`haxe.io.Error.Blocked` became `InternalError("Blocked")`.** `24db87fe1`
  changed `ProcessOutputCapture.read`. Blocked is a control-flow signal, not a
  failure: throw the enum value again.
- **Lint rules cannot type many stdlib modules.** `LintMain` types each file
  through the language service, which fails on many stdlib modules with
  "Duplicate type name". Run the typed rules (`unbound-local`,
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

### Known differences from Haxe still open

The Haxe code Haxeon rejects or runs differently is listed in
[LANGUAGE_SUPPORT.md](docs/reference/LANGUAGE_SUPPORT.md#not-yet-supported).

## Generated code, HashLink and Wasm (haxeon-e4's lane)

Planned in this order unless noted. Timings so far were taken on a loaded
machine; re-measure on a quiet one before acting on a ratio.

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
- **Compressed debug sections** (decided, ADR 0003 §12): an LZ4 HC flag on
  debug sections, function identities first (1.15 MB to about 234 KB on the
  compile server), compressed by a runtime native over the fork's vendored
  `lz4.c` so both compiler builds write the same bytes.
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
- **Fewer lookups.** String-map time is spread over about 25 classes; the
  lasting fix is identities as integers instead of names (ADR 0003 M3).
- **The IR verifier runs in release builds** (4.4%). Skipping it there trades
  away a check, so it is the user's call.
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
