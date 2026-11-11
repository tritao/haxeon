# 5. Compilation units and the link step

Date: 2026-11-11

## Status

Proposed. Nothing here is implemented.

It turns ADR 0003 §11 ("separate compilation by package") into a design. Its prerequisites are ADR 0003 M2 (passes as a
summary plus a local rewrite), M3 (structured identities), M4 (one dependency engine, per-module visibility) and §13
(explicit providers, reachability first). The format choices below are meant to shape that work, so they are recorded
before it starts.

## Context

A cold build of `materia/app` compiles every package from source in one process: the stdlib, nativekit, cadkit,
machinekit, materia and the app. On 2026-11-10 that took about 50 to 60 s and allocated about 31 to 33 GB, on one thread.
Most of that code is library code that rarely changes.

What persists across processes today:

- the fingerprint that skips a build whose inputs are all unchanged;
- the identity state for live patching.

Nothing parsed, typed, lowered or encoded survives a process. Any change means a full cold build.

The analyses that make the output good are whole-program:

- reachability pruning;
- dispatchers built over all types;
- interface tables;
- generic specialization;
- the enum and closure classification;
- cross-package inlining.

So the runtime model of .NET, separately loaded assemblies linked by the JIT, does not fit. HashLink needs one bytecode
module with dense global tables, and hot reload patches that one module. A single Wasm module is also what we ship and
optimize.

## Decision

### 1. Compile per unit, link once

A unit is a package: a library or the app, as `haxeon.json` declares it. The stdlib is one unit.

Each unit is compiled into a unit artifact, and a link step combines the artifacts into the one `.hl` or `.wasm` the
targets need. This is the C object file or Rust `.rlib` model, not runtime-loaded assemblies. The output module stays as
it is today.

### 2. What a unit artifact contains

1. **Interface**, the equivalent of a reference assembly:
   - exported declarations, signatures and type layouts;
   - generic definitions that dependents instantiate;
   - bodies dependents may inline (as Rust exports MIR for generics and inline functions);
   - the summaries other units' passes read (ADR 0003 §4).
2. **Implementation**: the unit's functions after its own passes, in relocatable form. Operands are recorded symbol
   requests, not absolute indices (the relocatable lowering of M0). Debug locations are relative to their function (the
   position-independence item).
3. **Tables**:
   - providers, as (type, operation) pairs (ADR 0003 §13);
   - roots: `@:keep`/`@:expose`, static initializers, native callbacks;
   - the natives the unit needs;
   - the runtime modules it uses.

The format is versioned binary, written with the existing codec style (`IrFunctionStateCodec`). It is deterministic, so
equal inputs give byte-equal artifacts.

### 3. Cache key and invalidation

An artifact is addressed by a hash of:

- the unit's sources;
- the compiler version;
- the target profile and options;
- the **interface** hashes of the units it depends on, never their implementation hashes.

A dependency whose implementation changes but whose interface does not leaves its dependents' artifacts valid. Artifacts
live in a content-addressed cache directory, shareable between worktrees, machines and CI.

### 4. What runs where

| Per unit | At link time |
|---|---|
| parse, typing, IR generation | resolving units, instantiating generics at use and folding duplicates |
| the unit's local and summary-based passes | the whole-program steps: reachability (§13), dispatchers and helpers from the provider tables, interface tables, enum and closure classification over the reachable program |
| relocatable lowering | assigning dense indices and encoding |

Cross-unit inlining uses the exported inline bodies.

A pass that cannot be expressed as a summary plus a local rewrite runs at link time. The ADR 0003 M2 inventory decides,
per pass, which side it belongs to.

### 5. Warm builds and the editor

The warm worker keeps its in-memory caches. Unit artifacts are the cross-process layer underneath, so a fresh worker
starts from the artifacts instead of from source. The language server uses unit interfaces for dependencies, and the
full analysis only for the workspace's own units.

### 6. Hot reload

The link output is the module that gets published and patched, as today. Patches are computed against the linked module.
Unit boundaries change nothing for the live host.

## Prerequisites

1. **Per-module visibility (ADR 0003 M3/M4).** Today alias resolution keys on every alias in the program, and signature
   inference runs over the whole program. A unit can only be compiled against interfaces once name resolution depends on
   what the unit imports.
2. **Summaries (M2).** The inliner, scalar arguments and the classifications need exported summaries, or they move to
   link time.
3. **Providers and reachability first (§13).** Dispatchers and helpers are assembled at link time from what each unit
   declares.
4. **Stable identities (M3)** and position-independent IR. Names and debug data in a unit cannot depend on source offsets
   or on the order of the whole program.
5. **Codecs for typed and interface data.** IR and lowered code have codecs; typed trees and declarations do not.

## Migration

1. After §13 and M2: specify the artifact format and the link step in detail, and write a reader and a writer with
   round-trip tests.
2. **First unit: the stdlib.** It is the most stable package and every program uses it. Gate: a program built from the
   cached stdlib artifact produces the same output as a program built from source. Measure cold build time and memory with
   and without it.
3. The library packages (nativekit, cadkit, machinekit, ...) as units.
4. Parallel compilation of independent units. This needs the allocator work, because HashLink allocation takes a lock.
5. The cache shared through CI.

## Consequences

- **Faster everyday cold builds.** Unchanged packages come from the cache, so a cold build costs roughly what its changed
  packages cost, plus the link.
- **Parallelism** between independent units, which a single-program compile cannot offer.
- **An interface boundary between packages.** Cross-package optimization is limited to what interfaces export. This is a
  deliberate trade-off, made explicit per pass.
- **More formats to maintain**: the artifact codec, versioning and cache eviction.
- **Rejected alternatives:**
  - **Runtime-loaded modules (the .NET model)** do not fit HashLink's single-module tables or our whole-program
    optimizations.
  - **Caching only the final module** saves nothing when anything changes.
  - **Caching per function** gives finer granularity, but its cache keys need the whole program's analyses first, so it
    does not bound cold cost (2026-11-10 finding).
