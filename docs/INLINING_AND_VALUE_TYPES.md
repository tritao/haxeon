# Inlining and value types

Status: design, 2026-09-30. Nothing here is implemented except the value-class fixes listed under "Done".

## Why

Every object is a separate GC allocation and there is no inliner, so small values cost a heap object each. Measured in
Materia's editor (`app/tests/performance`, `--scenario primitives`): a `LayoutStyle` is 288 bytes spread over five objects,
a `RenderNode` is 936 bytes, a `Text` widget build is 3.3 KB, and `ResolvedLayoutItem` decoding allocates four objects per
node. A tab switch rebuilds about 320 nodes, so the fixed per-node cost sets the total.

Marking small types `@:value` today makes this worse (`LayoutAxis` as a value class grew `LayoutStyle` from 288 to 336
bytes): the value is stored inline in its parent, but every construction still heap-allocates a temporary and copies it
in. HashLink has no stack structs, so removing those temporaries has to happen in the compiler's IR.

## Done

- `65bbd540` Instance-method calls on a value class lower to direct calls. They used to lower to `CallMethod` through a
  prototype slot; value structures have none, so the JIT asserted (`emit_opcode`).
- Null handling: value classes are stored inline, so null cannot reach one. `null` and `Null<V>` are no longer assignable
  to a value class `V` (E1002), and an instance field of type `Null<V>` is rejected (E1022). Nullable value locals,
  parameters and returns are still allowed because they are pointers. Before this, `h.v = null`, an unguarded optional
  parameter stored into a field, and a `Null<V>` field all crashed with SIGSEGV at address 0.

## Value semantics

A value class has copy semantics on every target. Binding an instance to a new location gives that location its own
copy: a variable (`var b = a`, also with an inferred type), an argument, a return value, or a store into a field, array
element or map. Writes through a place still write in place (`h.span.start = 3`, and a method called on a place
mutates it), so a receiver is not copied. A fresh value (a `new`, a call result) is not copied again.

The typer inserts a `TCopy` node where `coerce` binds a place to a mutable value class, and the IR generator expands it
to a new object with the same field values, copying nested mutable value classes in turn. A class whose fields are all
`final` (and hold no mutable value class) is shared, since it cannot be told from its copy. Before this, HashLink
stored value fields inline and handed out pointers into the parent while Wasm used ordinary references, so
`var alias = h.span; h.span = new Span(5, 6)` meant two different things; the parity suite now runs the same value
class programs on all three targets with no skips.

Not covered yet: the loop variable of `for (x in values)`, generic value classes, and structural `==` on value
classes (it is still reference equality).

## Plan

Four stages, each with a measurable checkpoint. Each stage must keep the full driver suite and Wasm parity green.

1. **Inliner v1.** Small leaf functions and value-class methods; honors `inline` on functions.
   Checkpoint: stdlib `inline` helpers (`StringBuf`, `Std` wrappers) actually inline.
2. **Scalar replacement** of non-escaping value-class instances, with a small dead-code pass.
   Checkpoint: the `Insets`/`LayoutAxis` temporaries disappear in the `primitives` benchmark and the `@:value`
   experiment flips from worse to better.
3. **Construct-in-place** for value fields and array elements, then convert `Rect`, `Point`, `Transform2D`, `Color` and
   poses to `@:value`.
4. Optional: inline frames in debug metadata.

## Where the pass goes

The IR is SSA per function (`IrFunction`: blocks of `Located<IrInstruction>`, `IrValue` ids are function-local).
Functions are generated independently and cached per module (`ModuleState.irFunctions`, versioned by `irVersions`).
The only point where every function and the object tables coexist, before both backends, is between
`IrGenerator.assemble` (`compilation/FrontendCompilation.hx`, the call at about line 473) and
`BackendAssembly.assemble`. HashLink and both Wasm backends consume the same `IrProgram`, so one pass covers all
targets. `IrProgramAssembler.assemble` already scans all functions and rewrites `Call` to `CNativeCall` in place.

**The pass must not mutate cached `IrFunction` objects.** They are shared by `ModuleState.copy()` and by transaction
snapshots, and their fields are `final`. The pass is a pure function from the pristine IR set to fresh `IrFunction`
objects for the program handed to the backend (memoized by input versions).

## Incremental and hot-patch safety (the main risk)

Confirmed by the code:

- Editing a callee body regenerates only that function (`semantic/SemanticAssembly.hx`; the invalidation worklist is
  seeded only by signature, generic-origin and purity changes). `tests/compiler/ModuleMain.hx:63-79` asserts this.
- `HlModuleAssembler` builds `changed` and the patch set from the `regenerated` names only, and `HlLower` re-lowers and
  re-verifies only those (plus functions whose instructions carry the same source path).
- The patch runtime requires identical function types but does not constrain register count or layout, so a body that
  grows because of inlining patches fine.

So a caller that inlined a callee would keep the old body after the callee is edited. Required rules:

1. Record, per caller, the callees it inlined (transitively) and each callee's `irVersions` value. Validate on every
   compile, as `purityQueries` does for typing.
2. Compute the patch set by post-inline IR: `changed` is every function whose `IrFunctionStateCodec.encode` bytes differ
   from the last published entry (the same comparison `Compiler.rehydratedChanges` uses). Callers of an edited callee
   are then re-lowered, re-verified and patched.
3. Keep the original callee: stable IDs, closures (`StaticClosure`, `InstanceClosure`), virtual dispatch and other
   callers still need it.
4. Inlining a callee can make a caller newly require a runtime native, which changes the native count and forces a full
   reload (`HlModuleAssembler`). Account for this or accept it.
5. Gate the whole pass behind a compile option that is part of the compiler configuration identity, so caches never mix
   modes. Roll out enabled for non-patchable builds and Wasm first; enable for live/watch sessions once rules 1-4 have
   tests.

## Inlining policy v1

- Candidates: direct `Call` sites and `MethodCall` on a value-class receiver (final, so statically resolvable). Skip
  virtual and interface calls until there is a proof that a method is not overridden.
- Callee: non-recursive (build call-graph SCCs by scanning `Call` and closure names), within an instruction budget,
  no `BeginTry`/`Catch`, not `__`-prefixed, not `__init*` or the entry point, not referenced by native metadata or
  `ObjectReflection`.
- `inline function` becomes a stronger hint (larger budget). The parser currently drops it for methods and functions
  (`syntax/Parser.hx:212, 538-596, 778`); `AstFunction` and `TypedFunction` need an optional flag, and
  `ModuleChangeAnalyzer` must treat a change of it as a signature-level change.

### Mechanics

Clone the callee blocks with fresh value ids (max id + 1 in the caller) and fresh block ids; substitute arguments for
callee parameters; split the caller block at the call into a head and a fresh continuation block; turn each callee
`Return v` into `Jump(continuation)` plus a phi in the continuation (a plain substitution when there is one return);
retarget the caller's successor phi inputs from the original block to the continuation. Keep `BeginTry` last in its
block. Critical edges do not need splitting here (`PhiEdges.split` handles it at lowering). `IrVerifier` re-checks
phis, dominance and types after the rewrite and is the safety net.

## Scalar replacement

Candidate: `NewObject(v, T)` where `T` is a value class. Uses are found with `IrOperands.inputs` plus phi and terminator
operands. Allowed: `FieldGet`/`FieldSet` with `v` as the object, and constructor or method calls that were inlined
first. Escapes (bail out): `v` stored into a field or array or global, returned, thrown, passed to a call that was not
inlined, used as an `InstanceClosure` receiver, `ToVirtual`, `ToDyn`, a `MakeEnum` argument, a phi input, or read in a
`BeginTry` handler (handler values must dominate the `BeginTry` block). Rewrite: one SSA value per field, forwarded
within a block and merged with phis at joins; a field read before any write takes the zero default (HashLink `New`
zero-fills). Nested value fields recurse.

There is no IR-level dead-code elimination, use-def list or alias analysis today, so stage 2 brings a small DCE for
the dead loads, stores and allocations it leaves behind.

## Debug and profiling

Per-opcode provenance is flat; there is no inlined-at chain. Inlined instructions keep the callee's provenance, so the
debugger shows the callee's file and line. Two things to fix in stage 1:

- `HlLower.functionIdentity` takes the source path from the first instruction and start/end/line as min/max over all
  instructions regardless of path, so cross-file inlined code would distort a function's enclosing span. Compute it
  from the function's own locations (or carry the function span in `IrFunction`).
- `debugBindings` refer to function-local value ids and their identities collide by name. Remap the callee's values and
  namespace the identities, or drop the callee's bindings.

Stack traces and profiler samples attribute an inlined callee to its caller. That is acceptable for v1; an
`inlinedAt` provenance field and a new debug section (unknown section kinds are skipped by readers) can come later.

## Determinism

Output must be independent of host and history (commit `634823b6`; self-hosting byte-identity in ROADMAP). Never let
`Map` iteration order affect candidate order or fresh numbering; sort names first. Decisions must be a pure function of
IR content so an incremental build equals a clean build. The checked-in bootstrap compiler needs refreshing when output
changes.

## Tests

Differential: run every manifest program with the pass on and off and require the same exit code (HashLink and both
Wasm targets); use `IrInterpreter` as a reference executor for pass unit tests. Incremental: edit a callee body and
assert every inlining caller appears in the patch and executes the new behaviour (`tests/compiler/ModuleMain.hx`
style, plus a hot-reload test). Add cases for callees with multiple returns, loops, phi-carrying successors, calls
inside `try`, and value classes stored to fields.

## Open questions

- Where the gate lives (compile option vs build profile) and how the live/watch session turns it on safely.
- Whether devirtualizing classes with no overrides is worth an IR-level override scan after value classes work.
- Whether the persisted function cache should store pre- or post-inline IR (post-inline changes what
  `rehydratedChanges` compares).
