# Pragtical conversion plan

This project is not a Lua-to-Haxe transpiler. The target is a Haxe-compatible
editor runtime whose public editor API is designed for HashLink and whose
compiler can replace plugin functions while the process stays alive.

The conversion must therefore proceed in two tracks:

```text
compiler/runtime correctness  ─────┐
                                   ├─> one reloadable plugin
Pragtical API and migration      ──┘        ├─> editor services
                                             └─> editor core
```

## Target architecture

```text
Haxe source
  -> incremental frontend
  -> typed AST
  -> SSA IR
  -> HL module (HLB) + patch (HLP)
  -> HashLink fork
  -> reload domain
  -> Pragtical host
```

The compiler service owns source state, diagnostics, symbols, dependency
invalidation, and language-service queries. The HashLink fork owns native
module loading, patch synchronization, JIT lifetime, and runtime type metadata.
The host owns editor lifecycle and chooses whether a change is an in-place patch
or a domain reload. No layer may become a second typechecker or a second
language runtime.

## Supported language profile for the first conversion

The profile is deliberately smaller than Haxe and larger than the current POC:

- classes, fields, constructors, inheritance, interfaces, and virtual calls;
- `Int`, `Float`, `Bool`, `String`, `Void`, explicit nullable references;
- functions, typed function values, closures, and mutable capture cells;
- `Array<T>` and `Map<K,V>` with primitive and reference values, iterators, and
  identity-safe mutation;
- enums with payloads and expression/statement `switch`;
- nominal typedefs and a small structural-record form for data transfer;
- package-qualified nominal identities, imports, deterministic diagnostics, and source-span recovery;
- typed `throw` through HashLink's dynamic exception ABI; `try`/`catch` follows
  once handler control flow and uncaught-exception diagnostics are stable.

Deferred until the editor is already running on the profile: macros,
`@:genericBuild`, arbitrary abstracts, compiler plugins, cross-target behavior,
advanced reflection, and optimization-driven language features. The Haxe sample
under `pragtical/scripts/lua/tests/languages/samples/052_haxe.hx` is a useful
pressure test, not a requirement to implement every feature it demonstrates.

## Delivery stages

### 0. Baseline and contracts

Inventory the Lua editor API and choose the first Haxe API boundary. Freeze the
HashLink fork revision, formatter version, compiler ABI version, and reload
compatibility rules. Every unsupported construct must produce a diagnostic.

Exit gate: a clean checkout builds the fork, runs the differential suite, and
reports compile/patch latency, module size, and JIT reclamation metrics.

### 1. Language kernel

Finish parser recovery, nominal typing, nullable narrowing, enums, aliases,
closures, and SSA verification. Keep every feature on the same path:

```text
AST -> typed AST -> SSA -> HL
```

Exit gate: the `fib` fixture, all existing source programs, and negative tests
agree with official Haxe behavior where the profile overlaps.

### 2. Collection and ownership semantics

Complete arrays and maps before porting editor code. This includes reference
values, typed map-key iteration, mutable fields, iterators, bounds behavior, and an explicit ownership
model for operations that may replace an array storage object. Implement shared
mutable capture cells before accepting callback-heavy editor APIs.

Exit gate: a collection stress fixture exercises aliases, closures, nested
collections, mutation during iteration, and failure recovery without stale
references.

### 3. Runtime ABI and reload safety

Version strings, arrays, maps, static globals, IO, time, exceptions, type tables, and native
registration as one ABI. Finish the non-moving type arena and make compatible
patches atomic. Structural edits must be classified before native staging and
must never disturb the previous generation on failure.

Exit gate: body edits patch in place; signature edits are rejected or rebuilt;
class-layout edits reload only their domain; failed patches leave the old code
running.

### 4. Plugin-first migration

Build a small representative Haxe plugin with an `Editor` facade, command
registry, document collection, search service, and lifecycle hooks:

```haxe
interface Plugin {
    function activate(editor:Editor):Void;
    function deactivate():Void;
}
```

The plugin must use multiple modules, arrays/maps of editor objects, callbacks,
diagnostics, and state migration. It is the first real workload, not a toy
bytecode test.

Exit gate: save -> incremental compile -> HLP patch completes while the editor
keeps running; a structural edit performs a domain reload and restores state.

### 5. Editor service integration

Embed the persistent compiler service in a Pragtical-like host. Wire save,
completion, hover, definition, references, rename, diagnostics, and a scoped
REPL to one snapshot. Add cancellation and deterministic assembly for parallel
parse/type work only after measurements justify it.

Exit gate: a realistic multi-module plugin workspace meets the agreed latency
and memory budgets, and an invalid edit never replaces the last good generation.

### 6. Subsystem migration

Migrate in dependency order, keeping each subsystem in a reload domain:

1. utility/value types and configuration;
2. document and buffer model;
3. command/keymap and search services;
4. UI/layout and rendering adapters;
5. filesystem/process/network bridges;
6. application orchestration;
7. the editor core loop.

Each step keeps a fallback build and a behavior replay suite. Do not migrate a
consumer before its API and reload semantics are boring and measured.

### 7. Self-hosting and release

Constrain compiler sources to the supported profile, build compiler A with the
official Haxe compiler, then build compiler B with A. Compare diagnostics,
runtime behavior, and module/patch contracts rather than byte identity. Check in
`bootstrap/compiler.hl`, pin all tools, and make official Haxe optional for
normal development.

### 8. Production conversion

Freeze compiler/runtime protocol versions, publish extension and rollback
procedures, remove fallback paths only after a release cycle, and optimize from
measured traces. Correctness, reload safety, and editor UX remain higher priority
than peak throughput.

## Required gates before declaring Pragtical-ready

| Area | Required evidence |
| --- | --- |
| Frontend | deterministic diagnostics and recovery on incomplete edits |
| Semantics | differential coverage for every migrated feature |
| Collections | reference values, aliases, closures, and iterator behavior |
| Runtime | atomic patching, type-arena safety, domain isolation |
| Service | one persistent snapshot powers compile and language queries |
| UX | measured save latency, completion latency, and recovery time |
| Operations | reproducible bootstrap and rollback from a bad plugin edit |
| Migration | one plugin, then one editor service, running without process restart |

## Immediate sequence

The next bounded milestones are:

1. finish collection ownership and mutable capture cells; **done**;
2. add the representative multi-module plugin fixture; **done**;
3. integrate structural reload/state migration with that fixture; **done for
   loaded lifecycle functions and the host domain, with native type-arena work
   still pending**;
4. add latency budgets; **cooperative protocol cancellation is now wired**, but
   measured budgets and parallel workers remain;
5. start the first Pragtical utility migration only after those gates are green.
