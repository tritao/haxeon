# Shared generated helpers: ownership by subject (design note, no code)

Status: proposal, 2026-11-11. Input: the warm-edit sweep (`Main --warm-edit`, run by the checked suite), which leaves one program,
`enum-generated-dependencies`, whose warm rebuild differs from a fresh build. It is listed by name in `driver.TestRunner.
warmEditKnownFailures` with a reference to this note, and fails the day it starts passing.

Scheduled with ADR 0003 M4: the invalidation key is a query dependency there, so it is not built here as a second hand-written `invalidated` extension.

## The failure

`$hash$value$equality:<sha(T)>` is one function for a type `T`, however many functions need it. Each request is recorded in
`TypingSession.hashRequests` by name, and the first request wins: its `origin` (the requesting function) and `span` become the
helper's. In `enum-generated-dependencies` the requesters of the hash helper for `Key` are `$generic:...LateBox[constrained]<Key>.hash`
and `$enum-custom:equals:...`. A fresh compiler types them in one order; a warm session, which types only the functions an edit
touched, sees them in another, so the same helper gets a different `origin`. The origin decides the helper's owning module, when it
is regenerated, and its stable function identity (HLB section 1), so the two modules differ.

The same shape is in every first-wins registry: `valueEqualityRequests`, `enumEqualityRequests`, `wireCodecRequests`,
`jsonCodecRequests`, `enumMethodRequests`, `enumInterfaceAdapters`, `dynamicStructureConversions`. The sweep exercises only the hash
one. (`keyPathDefinitions` was last-wins and is fixed: its span is now a function of the path.)

## Principle

A shared artifact's attributes are a function of its subject, never of its uses. Fresh and warm builds then agree by construction,
without a record of who asked.

## What has to be decided

**1. Ownership.** `FrontendCompilation` resolves a function's module from the `owners` map, from the initializer naming
(`Class.__init`), or from its `origin` chain (`resolveFunctionModule`). A type has no function name in `owners`:
- class or struct `T`: `T.new` is in `owners` whenever a constructor exists, explicit or implicit (the sweep showed implicit ones are);
  otherwise the declaration module from `CompilationContext.declarationOwner`.
- enum `T`: no function at all; `declarationOwner(T)`.
- generic instance `Box<A>`: the module of the generic declaration, but its body also depends on `A`'s module.
- `Nullable<T>`, `Array<T>`, `Map<K,V>`, key paths: the subject is the element or root, recursively; the outermost nominal type decides.
Proposal: `origin` becomes `$type-origin:<canonical type key>` (the prefix already exists for runtime dependencies,
`RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX`), resolved through `declarationOwner` in `resolveFunctionModule`, which then needs the
context or a name-to-module lookup.

**2. Invalidation.** Today a helper is regenerated when its origin function is retyped or invalidated, which comes for free from the
requester chain. With a type origin the pseudo name must enter `invalidated` when `T`'s module changes in a way the helper reads: the
fields it compares or hashes, their types, and conformance declarations (`Equatable`, `Hashable`, custom `equals`/`hash`). A field
type in another module changes that helper too, so the key is transitive: the helper's own calls to other helpers are already edges
(`generatedHelpersStillCalled` walks them); the transitive step must also mark helpers whose subject's *fields* mention a changed
type. Without it a helper would be kept stale, which is worse than the order dependence we are removing.

**3. Typing context.** `HashGenerator.generate` and its siblings call `session.enterBody(requested.origin, null, owner)`: the helper's
body is typed in the requester's context (its function name for temporaries and diagnostics, its generic substitutions, its imports).
A subject-owned helper needs its own context: name `$helper:<name>`, owner = the module that owns `T`, and no substitutions from the
requester. Check what the bodies read from the context today: temporaries (`diffTemporary`, `keyPathTemporary`) are per function and
would restart per helper (fine), but anything resolved through the requester's imports or type parameters would break.

**4. Diagnostics.** Errors raised while generating (a field that is not hashable, a missing conformance) use the requester's `span`, which
is the useful place to report them. The helper's own spans become the subject's declaration; the requester span is kept for diagnostics
only, so an error still points at the use that asked and no artifact carries it. A diagnostic then depends on which use asked first,
which is acceptable for a message and not for an artifact.

**5. Per-use helpers.** A codec or adapter specialized per use site is not a shared helper. If any member of these registries turns out to
read the requester (an `$iteration-adapter` already does and is a derived function), it is classified as derived and keeps its requester
as origin; the sweep of every family below decides which.

## Order of work

1. A targeted test set, written first, each case a warm edit rebuild that must equal a fresh build: a struct hashed from two requesters in
   either order; an enum compared from a generic and from a custom method; a field type changed in another module; a conformance
   added; a requester removed; two requesters in two modules, the owning module edited; a nullable and an array of the subject; a codec
   (`wire`/`json`) of the same type from two requesters. Add them to the sweep as named programs.
2. The mechanism with the hash registry only, behind the known-failure marker: `enum-generated-dependencies` must then pass and the
   marker fail, which removes it.
3. The other registries one at a time, each with its test case and the per-family hldump review (names, origins and function identities
   change for every helper whose first requester was not the subject's module, so every program with generated helpers is affected;
   the review is of identities and owners only).
4. Delete the first-wins `origin` and `span` fields from the request records.

## Risks

- Invalidation under-approximation (above) is the one that matters; the sweep's inside-the-file edit does not exercise a change in
  another module, hence the test set first.
- Stable function identities change for most generated helpers once, which invalidates anything keyed by them across a compiler upgrade
  (the hot-reload patch protocol): needs a protocol version note.
- It belongs with ADR 0003 M3/M4 (ownership and invalidation), not with the warm-rebuild fixes.

## Test set (written, passing today)

`helper-ownership-struct-hash`, `-struct-equality`, `-enum-equality`, `-wire-codec` and `-generic-and-custom` are sweep programs: each has
one shared helper with two requesters written in different functions (a struct hashed from a map and from `Hashing.hash`; struct
equality from `==` and as a map key; enum equality from a generic method and a plain function; a MessagePack codec from two functions; a
hash requested by a generic specialization and by a custom enum method). All pass the warm-edit sweep today, so they are not in the
known-failure list: they document the shapes and will gate the mechanism. They do not reproduce `enum-generated-dependencies`, whose
requesters differ in typing stage (a method typed after the ordinary bodies); a reduction of that is part of the work. The cases that need
a change in another module (a field type edited elsewhere, a conformance added, a requester removed from a second module) cannot be
written as sweep programs, whose edits are confined to the entry file; they need a multi-module warm test and belong with the M4 query
tests.
