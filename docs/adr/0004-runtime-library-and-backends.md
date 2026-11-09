# 4. Runtime library written once, thin backends

Date: 2026-11-09

## Status

Proposed. Nothing here is implemented. It builds on ADR 0003 (layers, the target profile, declared runtime modules) and
covers what that record leaves open: where runtime behaviour is defined and how much of it a backend owns.

Decided with the user on 2026-11-09:

- Both Wasm memory models stay: Wasm GC and Linear32.
- Wasm64 is not needed yet.

The decisions do not carry the same confidence:

- **Committed:** the target boundary (2), C only below the object model (3), the Wasm backend structure (4), removing
  Wasm64 for now (5).
- **Go/no-go:** the library in Haxeon source (1). The string-family study (R1) decides it from measurements before any
  further family is ported.

## Context

Measured on `warm-rebuild-reuse` (2026-11-09). The compiler is 130k lines; the Wasm backend is 33k of them (25%), against
about 8.5k for HashLink from lowering to the writer:

| Part | Lines |
|---|---|
| Wasm shared pipeline (lowering, structuring, scalar ABI, encoder, validator, layout, UTF-16 coordinates, patch, linker) | 10,349 |
| Wasm GC (`backend/wasm/gc`) | 12,755 |
| Linear32 (`backend/wasm/linear`) | 9,807 |
| HashLink C runtime (`native/runtime`) | 8,427 |

The size comes from the runtime library. HashLink's VM and our C runtime supply strings, bytes, maps, arrays and the
collector, so the HL backend only lowers. Wasm has no runtime, so the compiler builds one, as raw instruction lists:

- `WasmLinearRuntime.hx` (4,393 lines, 130 functions) is almost entirely library: bytes 921, strings 871, maps 493, int
  formatting 394, structs 370, dynamic values 360.
- `WasmGcRepresentation.hx` (5,919 lines, the largest file in the compiler) mixes representation with the same library:
  arrays about 1,065, strings 751, bytes about 490, dynamic values 372.
- Both models then have their own maps, arrays, dynamic arrays and value arrays (`WasmGcMaps` 961, `WasmGcDynamicArrays`
  863, `WasmLinearArrays` 1,286, `WasmLinearDynamicArrays` 1,209, ...). Linear32 also has a collector in hand-written Wasm
  (`WasmLinearGc` 755).

So one operation, such as `StringTools.replace`, has up to three definitions:

- C on HashLink (`native/runtime/strings.c`, `@:hlNative("haxeon_runtime", ...)`);
- hand-emitted instructions on each Wasm model;
- sometimes a fourth in Haxe source under `#if wasm`. About 20 stdlib files have such branches.

The definitions drift. HL/Wasm parity failures account for 6 to 10 of the gate's failing stages.

The stdlib already has the shape this record generalizes:

- `stdlib/runtime` holds Haxeon-source runtime code: `Ryu` float formatting, `Regex`, `StringMethods`, `DynamicObject`.
- `haxeon/collections/HashMap.hx` is shared source.

## Decision

### 1. The runtime library is written once, in Haxeon (go/no-go: R1)

The library lives in the stdlib as Haxeon source and is the one definition of what each operation does, on every target:

- string algorithms;
- bytes;
- int and float formatting and parsing;
- `Array<T>` over fixed arrays;
- maps;
- dynamic values and reflection helpers;
- regex.

A target may add a faster version of an operation only if a differential test checks it against the source version.

C cannot be the shared language. C compiled to Wasm sees only linear memory, so it cannot allocate or read Wasm GC
structs and arrays. Each call on the GC model would copy its data into linear memory and back. That works for hashing but
not for `charAt` or `map.get`.

Haxeon source has two further advantages:

- it compiles natively to both models;
- the inliner and the IR verifier see it like user code, with no call boundary.

Runtime code is written in a restricted dialect: it may not use what it implements. For example, string code does not
concatenate strings. The dialect is marked by package (`runtime.*`) and checked by the compiler.

### 2. Intrinsics are the only target boundary

`stdlib/runtime/Intrinsics.hx` declares about 45 operations as `@:intrinsic("family.name")` externs. The IR has one
operation for them. Each backend has one table that maps every intrinsic to an opcode, an instruction sequence or a
native. The compiler fails at build time if a target lacks an intrinsic the reachable stdlib uses.

| Family | Operations |
|---|---|
| Byte buffers | `alloc`, `length`, `get8`/`set8`, `get16`/`32`/`64`, `getF32`/`F64` (little-endian), `copy` (overlapping), `fill`, `compare` |
| Fixed arrays | `alloc<T>`, `length`, unchecked `get`/`set`, `copy`, `fill` |
| Strings | length in code units, code unit at, adopt a buffer, view as bytes, ASCII flag |
| Identity | `same`, `identityHash` |
| Types and dynamic values | `typeId`, `isInstance`, `kind`, box/unbox int, float and bool |
| Math and bits | `clz`, `ctz`, `popcnt`, rotations, unsigned divide and compare, float bit reinterpretation, `sqrt`/`floor`/`ceil`/`trunc`/`nearest`, `min`/`max` |
| Errors | `trap`, `unreachable` |
| GC | `collect`, `stats` |
| Closures | varargs closure, dynamic call with an argument array |

Host services (print, time, random seed, files) stay imports (HXI, natives), not intrinsics.

This builds on what exists rather than adding a second mechanism. Today the compiler-known primitives are `__name` calls
resolved by name in `CallResolver`: `__reference_equal`, `__std_string`, `__string_split`, `__string_to_lower_case`,
`__math_floor` and others. Since `ad476835`, `Source.isStandardLibrarySource` carries stdlib provenance from the loader
root, but only `__reference_equal` is restricted to stdlib sources (`1d60d0ec`, E1025). The work is:

- The declaration becomes the single list of these primitives. `CallResolver` stops matching name strings.
- Every primitive is restricted to stdlib sources through `isStandardLibrarySource`.
- Primitives that are library behaviour rather than basic operations move into Haxeon source as their family is ported
  (R1 to R5). For example, `__string_split` and `__string_to_lower_case` go in R1.

Wasm GC constraints that the shared library respects:

- **No interior pointers.** Shared code addresses memory as a buffer plus an offset. `RawPtr`, `NativeSpan` and `Arena`
  stay HL and Linear32 only.
- **No multi-byte loads from i8 arrays.** Byte-heavy code (hashing, UTF-8) is measured on GC in R1. It may get a
  per-target fast path.
- **No address hashing.** `identityHash` needs a lazily set header slot on GC objects.
- **No weak references without the host.** On GC, weak references need the host's `FinalizationRegistry`.

`stdlib` keeps no `#if wasm` outside the intrinsic layer and the host bindings.

### 3. C only below the object model

C remains only where it touches raw bytes or sits beneath managed values:

- HashLink host natives: files, processes, threads, sockets;
- the Linear32 allocator (`native/wasm/heap.c`) and the marking part of its collector, if R6 shows that is simpler than
  the hand-written one (root maps stay in the compiler);
- byte kernels: crypto, and float parsing if the Haxeon version is not good enough.

The HashLink C natives that duplicate library behaviour (`native/runtime/strings.c` and the like) are kept behind the
differential test. They are deleted family by family once a benchmark shows the source version within the agreed bar
(open decision: proposed within 10% on the family benchmark).

### 4. Thin backends; Wasm has one shared pipeline and two reference models

A backend owns only:

- lowering from the IR;
- its intrinsic table;
- its object representation;
- its encoder or writer.

It owns no library behaviour.

For Wasm:

- **Shared pipeline:** structuring, the scalar and C ABIs, exceptions, fuel metering, the encoder, the validator, the
  patch format and the runtime linker.
- **A `WasmReferenceModel` interface:** representation (value types, object, array and string layout, type tests, roots)
  plus the intrinsic table. `Gc` and `Linear32` implement it.
- **Builders:** `WasmGcModuleBuilder` and `WasmLinearModuleBuilder` shrink to module assembly over the interface.
- **`WasmGcRepresentation.hx`:** split into representation and the code R2 to R5 delete.

### 5. Wasm64 is removed until needed

`Wasm64` and `Linear64` are declared but have no implementation:

- `Backend.hx`, `WasmTarget.hx` and `WasmBackend.hx` declare them;
- `CompilerDriver.hx` accepts `wasm64`.

They are deleted.

When a 64-bit target is needed, Linear32 becomes a linear model parameterized by pointer width, behind the same
interface.

### 6. Allocation regions are a runtime API (added 2026-11-09)

HashLink's GC already keeps a registered owner's blocks in pages of their own (`dfd802296`: owner classes,
`hl_gc_owner_live_count`, and `hl_gc_owner_release`, which frees a class's pages after a full collection and only when
nothing in them is live). We add a per-thread current owner, `hl_gc_push_owner` and `hl_gc_pop_owner`, and a stdlib
`Region` (create, run, live count, release).

Allocations made inside a region share no page with long-lived data. Release is checked, so it can never leave a dangling
reference; an escape only keeps pages alive and is reported. Uses:

- the compiler's per-stage temporaries (IR passes first, then lowering and typing; outputs are allocated outside);
- applications: per-frame or per-request work.

On Wasm GC a region is a no-op hint, because the engine owns allocation. On Linear32 it can follow later.

Rejected:

- **Explicit allocator parameters per allocation** are invasive across generics, closures and the stdlib.
- **Region types with static escape checking** are unsound or too restrictive with `Dynamic`, reflection and closures.
- **Releasing without the liveness check** risks memory corruption.

The compiler worker is built with stock Haxe, so the API is reached through `@:hlNative` declarations, not syntax.

## Migration

Every step keeps the full driver suite green, the Wasm suites at their baseline or better, and HL/Wasm parity at its
baseline or better. Each family port deletes that family's hand-emitted builders in both Wasm models in the same series;
there are no two paths.

- **R0 Gate (prerequisite):** fix the 12 stages that fail on `origin/main`, or remove them on purpose, and make
  `scripts/test.sh` the list CI runs. The rest of this record is refactoring, and it relies on a gate that is either green
  or red.
- **R1 Intrinsics and the string-family study (go/no-go):**
  - add `Intrinsics.hx`, the IR operation, the three tables and the completeness check;
  - make the Haxeon source of the string family (search, replace, split, trim, case, compare) the only implementation on
    both Wasm models, and delete the hand-emitted versions.

  Measure against the hand-written versions:
  - run time on a string benchmark (UTF-8 heavy on GC in particular);
  - module size;
  - app compile time.

  Measure HL too: the source version against its C natives.

  Go if Wasm is within the agreed bar and the deleted lines exceed the added ones. No-go keeps the hand-written family
  and stops here, with the measurements recorded.
- **R2 Bytes, then int and float formatting.**
- **R3 Arrays and dynamic arrays.**
- **R4 Maps:** includes `identityHash` and the GC header slot.
- **R5 Dynamic values and reflection.**
- **R6 Wasm structure:**
  - the `WasmReferenceModel` interface;
  - split `WasmGcRepresentation`;
  - shrink both builders;
  - decide whether the Linear32 collector moves to C.
- **R7 HashLink natives:** delete the duplicated C natives that pass the benchmark bar, keeping the differential tests.
- **Anytime:** remove Wasm64 (5). It has no dependencies.

Ordering against ADR 0003:

- R0 and R1 can run alongside M1, since they touch the stdlib and the Wasm backend, not the IR generator.
- R2 to R5 need the intrinsic operation in the IR, and should land before M2 moves the Wasm builders' own passes into
  layer 6, so those passes are ported once.
- The runtime declaration of ADR 0003 (6) also lists the intrinsics.

## Consequences

- **Size:**
  - expected Wasm backend: about 15 to 18k lines with both models (from 33k);
  - each model's intrinsic table: about 1.5 to 2k lines;
  - `native/runtime`: shrinks to host natives plus measured fast paths.
- **Parity:** one definition per operation removes the class of HL/Wasm behaviour drift behind the parity failures.
  Parity tests become differential tests of the shared library.
- **New targets** (C, a 64-bit linear model) get the library by implementing the intrinsics.
- **Costs:**
  - The library's speed depends on our optimizer: intrinsic inlining and bounds-check removal in loops the library has
    already range-checked.
  - Runtime code is compiled on every cold build; warm reuse covers warm builds.
  - The dialect needs a checker.
- **Risk:** byte-heavy code on Wasm GC. R1 measures it before anything else depends on it.
- **Rejected alternatives:**
  - **A shared runtime in C** cannot operate on Wasm GC values.
  - **Keeping hand-written builders and only deduplicating between the two models** keeps two definitions per operation,
    with HL's C as a third. It also keeps the library outside the verifier and the inliner.
  - **Dropping Linear32** was declined on 2026-11-09; both models stay supported.
