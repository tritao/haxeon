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
- **Most of Haxe's `Type` API is missing.** Haxeon has 2 of its 20
  functions, `Type.enumIndex` and `Type.enumEq`, as compiler intrinsics
  (`E1007: Unknown function "Type.getClassName"` for the rest). Haxe
  libraries that serialize, log or load plugins need the others. In phases:
  1. `enumConstructor` and `enumParameters`, which need only the enum value,
     like the two that exist.
  2. Classes and enums as runtime values, `Class<T>` and `Enum<T>`, on
     HashLink, wasm32 and wasm-gc, with `getClass`, `getEnum`,
     `getSuperClass`, `getClassName`, `getEnumName`, `getInstanceFields`,
     `getClassFields`, `getEnumConstructs`, `allEnums` and `typeof`. Write a
     design note first and agree it with the typer lane: it shares the
     runtime type representation with structure values (architecture step
     2.6, `docs/design/STRUCTURE_VALUES.md`).
  3. `resolveClass`, `resolveEnum`, `createInstance`,
     `createEmptyInstance`, `createEnum` and `createEnumIndex`, once a port
     needs them. A type named only by a string defeats pruning, so this
     needs `@:keep` and Haxe's dead-code rules.
- **`trace` with several values prints differently from Haxe.**
  `trace(a, b, c)` prints `2, 1, 1`; Haxe prints `2,1,1`.
- **Warm builds still track subclasses' reads of base-class statics.**
  Statics are no longer inherited (`f1e69062`), so a base class adding or
  changing a static cannot change a name in its subclasses. The dependency
  edges that link them can go, so such an edit no longer retypes them.
- **Unused imports in `src/compiler/Compiler.hx` and
  `src/compiler/semantic/ModuleCanonicalizer.hx`.** `haxeon lint --only
  unused-imports` lists them. They predate the current work.
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
typer's drain order) and 5 (live pruning), and the allocation work in
`BindingWalker` and `CallResolver` (now on haxeon-7b's `MemberAccess`).

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
