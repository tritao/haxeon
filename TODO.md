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
