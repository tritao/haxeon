# World compatibility forward-port handoff

## Stable review checkpoint

The local review branch is `overnight/compiler-world-forwardport-20261009`, based
on accepted Haxeon main `99c62706acbc825efb7d2d0019502b36150957ab`. The complete
forward-port checkpoint is
`aee78ba4d9b2d5f330132447e7ef51cda994faf5` (formatter-normalized source and
regenerated bootstrap). Its
HashLink gitlink remains the
accepted `0e739431da931d8e21c98c485afb17f1f3164106`. This is a local review
branch only; it was not pushed or merged, and no World or Beartooth-main pin was
changed.

The checkpoint carries only the earlier native descriptor/typeInfo base needed
by the selected compiler queue, Flat struct syntax/value semantics and layouts,
class-body layout propagation, nullable Flat captures, narrow managed field
stores, managed `UInt32` runtime values, and the corresponding Wasm flat-layout
lowering. It does not carry the later descriptor-default/MessagePack schema
pipeline.

## Baseline and root causes

On accepted Haxeon main before the port, the real World `world.Entity` source
failed at `struct Entity` with E0002. The managed `UInt32` field, by-value
parameter, and return probes failed with E1022. A separate class-body
`sizeof<Transform>()` probe failed with E1022 even though the equivalent
module-level query worked: native layouts were not available while class method
bodies were typed, and cached layouts also were not rebound before retyping a
class body.

The nested `Int16` store required more than a smaller HashLink field type. The
accepted-main IR had no per-field native placement metadata, so the lowerer
could not distinguish a 16-bit field from its 32-bit carrier or sign-extend a
load. The port now propagates selected field offsets, widths, signedness, and
inline-record facts into canonical IR version 11, preserves them through
nullable erasure, and uses them for HashLink and both Wasm backends. The first
Wasm parity run exposed the missing flat-value lowering (the new nested-store
case returned 4 on Wasm32 and trapped on Wasm GC); the retained cross-target
test passes after that lowering was ported.

The native `Transform` probe uses a C `_Static_assert` oracle for size,
alignment, and offsets, paired with Haxe `sizeof`/`alignof`/`offsetof` checks.
The World `Entity` fixture contains the exact source from World commit
`87bd1360a5decad5ba582584e66692b987df19f9` and checks its class-body layout
queries against a C `int32_t` record oracle.

## Supported consumer examples

World's current flat Entity source needs no migration for this checkpoint. Its
constructor can continue accepting `Int` and explicitly casting into its
`Int32` fields. The tested layout is size 8, alignment 4, offsets 0 and 4.
Absent and present `Null<Entity>` values, `same()`, and captures of both nullable
states are exercised on HashLink.

The nested narrow-store case also passes on HashLink and both Wasm backends:

```haxe
struct Leaf {
    public var tag:UInt8;
    public var delta:Int16;
    public var count:Int32;
}
struct Root {
    public var prefix:Int;
    public var child:Leaf;
}
var root = new Root();
root.child.delta = cast (-1234);
// Reading root.child.count still yields zero.
```

`UInt32` is accepted as a managed field and in ordinary function parameters and
results. `Array<UInt32>` uses the existing `Array<I32>` runtime carrier, and
tests preserve the high bit and all-bits-set values. This is bit-preserving
storage/call support; `UInt32` arithmetic, `Null<UInt32>`, map values, enum
payloads, descriptor defaults, and foreign by-value calls remain unsupported.

## Explicit boundary: descriptor defaults

The copied World narrow-default reproducer was run against this checkpoint. It
does not reach default extraction: `typeInfo<NarrowScalarDefault>()` fails with
E1022, `typeInfo requires a native value record type, got
"class:NarrowScalarDefault<>"`. The current early typeInfo port describes
native value records, not ordinary Flat `struct` roots. Therefore this branch
does not provide World W2's descriptor-driven `UInt8 = 250` default, and it
must not be used to claim the S5/default consumer gate. That requirement needs
the later Flat descriptor/artifact work and the associated MessagePack runtime
contract as a separate forward-port.

## Forward-port decisions and conflicts

The source was ported in small commits from the compiler lane onto accepted
main; its branch history is:

- `3c50ea7e6be0408ebed59c405c6af4b69edce147` — native typeInfo base.
- `b98606530139a20670d3193bc2c636d1ef60a035` — struct syntax and value
  semantics.
- `a744de0457934c4ceea8510f22a87e8b32237e10` — Flat layout facts.
- `84516e3496b3ecbe16caeb236381ba2e9e8c87db` — class-body and cached-layout
  propagation. The upstream patch conflicted in generated bootstrap files and
  `NativeLayoutMain.hx`; generated files were regenerated at the final
  checkpoint, and the accepted-main `@:value @:repr("C")` test was retained
  while adding the cached class-body regression. The integration cache was
  relocated from `/tmp` to the worktree-local `out/world-e1022/cache`.
- `32f09ed863b4b7a3f5b434bfae6460e4b2e31a99` — exact World Entity layout,
  nullability, and value-operation probe.
- `67bdfdbac09c632a381ef7fe02baa6975bc3d66e` — nullable Flat capture repair
  (`IrGenerator` and regression cases; generated bootstrap deferred).
- `0e981cf9c1ef8a6d8e8f23ffcf5c577e438dca31` — nested native `Int16` store.
  The upstream cherry-pick also conflicted around lane-only descriptor tests.
  Only the store case was retained; accepted main was extended with the
  required per-field IR metadata and canonical IR v11 codec support. Its test
  is in the HashLink/Wasm manifest and the World-shaped integration.
- `61d3419c8a5a25c7798a217aff90eebb9eca3299` — managed `UInt32` carriers.
  The `ProgramTyper` conflict was resolved with the narrow
  `containsUnsupportedRuntimeValueType` check; unrelated descriptor and
  pointer-place tests from the newer compiler lane were not imported.
- `031075ab4b220261f9c1217553463efd3101135c` — Flat layout lowering for Wasm
  GC and linear Wasm. This was a three-way port of the relevant Wasm backend
  files and kept the new nested-store regression in parity.
- `f98023e5ed47c4bcc38c0004429b1ef643e0a063` — regenerated checked-in
  bootstrap after the full source set.
- `aee78ba4d9b2d5f330132447e7ef51cda994faf5` — normalized the touched source
  and fixture with the configured formatter and regenerated the bootstrap
  from those exact sources.

All worktree-local CMake builds, caches, and copied consumer sources are under
`out/`. ProcKit was copied from Beartooth main `6af1e12abb0649d2cc264e343afc3e94da849b7e`;
its pinned FastNoiseLite (`847eccda1db9e5e4a1472e05ca7d6b368ec0b8e8`) and
Manifold (`f75e9f0d027b9a8222d4a07a1900e98286a02342`) submodules were initialized
only in that copy. The first archive build correctly failed because archives
omit gitlink contents; after adding those exact local revisions, ProcKit's
native build and smoke passed. No Materia or sibling checkout was modified.

## Gate evidence

All commands below were run in this review worktree with local outputs/caches:

- Compiler driver suite: 86 passed, 0 failed at source checkpoint
  `61d3419c8a5a25c7798a217aff90eebb9eca3299`, before the later Wasm-only
  lowering port. After that port, the focused `WasmBackendMain` driver and the
  complete Wasm parity suite below passed; the full 86-case driver suite was
  not rerun. The final closeout changes after those gates were formatting-only.
- Wasm parity: 356 fixtures agree across Wasm32, Wasm GC, and HashLink; 15
  declared skips. This includes the nested narrow-store and `UInt32` cases.
- `scripts/test-hxi-value-records.sh`: HXI fixed-layout ABI checks pass for
  Linux, Windows, Android, and Wasm.
- `tests/integration/test-world-native-record-layout.sh`: passes, including
  Transform and the exact World Entity source.
- `tests/integration/test-world-native-nested-int16-store.sh`: passes; adjacent
  `Int32` remains zero after the nested `Int16` write.
- `tests/integration/test-native-u32-runtime-values.sh`: passes on the pinned
  HashLink runtime, including high-bit and all-bits values.
- ProcKit `Smoke`: native build and complete smoke run pass in the isolated
  source copy, including the ManifoldKit Haxe and two-thread smoke.
- `scripts/bootstrap-compiler.sh`: seed and two self-host stages converge.
- `scripts/bootstrap-compiler.sh --self`: checked-in bootstrap rebuilds
  identically.
- `scripts/check-self-hosting.sh`: stage 1 and stage 2 are a fixed point.
- `tests/integration/test-world-native-record-layout.sh` was rerun at final
  closeout after the formatter pass and exited successfully.
- `scripts/format.sh --check` exits 1 on two unchanged accepted-main files,
  `src/build/provider/CompilerProvider.hx` and `tests/TestMain.hx`. All files
  touched by this forward-port pass their configured individual formatter
  checks; those two unrelated baseline files were not reformatted.

Detailed compiler/bootstrap logs are in ignored `out/gates/`. The compiler
aggregate `scripts/test.sh` was not run as a single command; its affected
driver, parity, HXI, and consumer stages were run directly as listed above.
The driver, HXI, and ProcKit runs preceded the Wasm-only lowering port; no HL,
runtime, or HXI changes followed those runs. The final formatter/bootstrap
closeout and World layout integration logs are also in `out/gates/`.

## Isolation record

The parent compiler lane and sibling checkouts were not edited by this
forward-port. At the final parent-lane audit, the carried files were:

- `docs/STRUCTS.md`: SHA-256
  `313e026e8391dcf87ab89c21b1e55fa863ea99e90bacfcf72cc3f9b9301b906b`.
- `docs/SCOPED_PLACES.md`: SHA-256
  `815812a5bdc01d63ef2e09c0db2479ff72204245d3b12b05581a2138ef6a8644`.
- `hlprofile.dump`: SHA-256
  `3a31fe7dfa40ea8f35625f80136736e176faf9c266f7f5253655d4957c7cef76`.

The earlier pre-task hash for `hlprofile.dump` could not be recovered, so
historical byte-for-byte preservation of that file cannot be independently
certified. This forward-port ran all builds and probes in its own checkout or
under its ignored `out/` tree.
