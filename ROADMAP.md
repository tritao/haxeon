# Roadmap

Haxeon is a Haxe-compatible compiler and runtime. It targets HashLink (desktop and Android, with live patching) and
WebAssembly (`wasm32`, `wasm-gc`) from one IR. The official Haxe compiler is the bootstrap and differential-testing
oracle only; it is not part of a normal build.

This file tracks the compiler, runtime and editor gates toward converting the Pragtical editor. Language features are
planned in [docs/LANGUAGE_ROADMAP.md](docs/LANGUAGE_ROADMAP.md). What the language supports, and the ordinary Haxe it
does not yet compile, is in [docs/LANGUAGE_SUPPORT.md](docs/LANGUAGE_SUPPORT.md). Status as of 2026-11-15.

## Architecture

```text
source -> tokens -> AST -> typed AST -> SSA IR -> backend (HLB/HLP, Wasm32, Wasm GC)
```

- The frontend owns Haxe semantics, source spans, symbols, and diagnostics.
- SSA is internal to the compiler. HashLink does not need to know about SSA, phi nodes, or source locals.
- Each backend owns its encoding, stable append-only symbol tables, and ABI validation. It never infers semantics from
  debug names.
- The forked HashLink owns live-module dispatch, patch staging, JIT lifetime, and the non-moving runtime type arena
  needed for safe reloads.
- The editor talks to a persistent compiler service, never to individual compiler passes or the official Haxe executable.
- Every feature goes typed AST -> SSA IR -> backend lowering; no feature-specific shortcuts to native code. Unsupported
  syntax and types are rejected with source diagnostics.

## Gates before the Pragtical conversion

### A. Language and backends

Done: classes, interfaces (including generic ones and constrained type parameters), inheritance with stable override
slots, statics with a stable `__init`, closures with shared capture cells, arrays, maps, `Null<T>` with narrowing, enums
with payloads, enum abstracts, abstracts with operators, properties, typedefs (generic and cross-module), imports
(wildcard and `as` namespaces), pattern matching (nested, alternatives with guards, arrays, captures), exceptions with
typed catch filters, dynamic objects and reflection, structs with `Equatable`/`Hashable`, key paths, and scoped cleanup.
What the Wasm backends cover is in [docs/WASM_BACKEND.md](docs/WASM_BACKEND.md).

- [ ] The Haxe compatibility gaps in [LANGUAGE_SUPPORT.md](docs/LANGUAGE_SUPPORT.md#not-yet-supported): `using` static
  extensions, indexing `Dynamic` values, structure and extractor patterns, rest parameters.
- [ ] Runtime library: file handles (`sys.io.File.read`/`write`), `haxe.ds.List`, `haxe.ds.Vector`, the rest of `Lambda`,
  `Type.getClass`/`getClassName`.
- [~] Typed storage for the standard reference maps and nullable-element arrays, and inline `Null<T>` through the callable
  ABI ([LANGUAGE_ROADMAP.md](docs/LANGUAGE_ROADMAP.md#order), items 7 and 8).
- [ ] Width subtyping for anonymous structures (needs a design document).

### B. Incremental compiler service

Done: persistent module state and dependency graph, separate signature and body fingerprints with selective
regeneration, stable function IDs with tombstones and compaction, typed dependency invalidation, and package-qualified
identities for every nominal type.

- [~] Unsaved edits validate transactionally against a forked snapshot without touching the live source, with cooperative
  cancellation at phase boundaries; shared snapshots and one-pass commit/rollback remain.
- [ ] Parallel parse and type work with deterministic assembly.
- [ ] Memory and latency budgets measured on a realistic Pragtical project. This decides whether the parallel work is
  needed yet.

### C. Runtime and hot reload

Done: HLP framing and validation, atomic compatible function patching (including functions with traps and handlers),
revision checks and stale-patch rejection, JIT allocation reclamation, in-memory module loading and patching, the
non-moving type arena, typed lifecycle calls through `RuntimeDomain`, and a multi-module plugin that patches bodies in
place and reloads on structural edits (`tests/hxml/plugin-test.hxml`).

- [~] Structural class layout and base changes are classified as full-reload generations and rebuild HashLink type
  metadata; compatible appended metadata keeps stable addresses.
- [~] Native call and patch failures return typed status codes and keep the last good domain; crash-safe diagnostics
  and automatic recovery for every native fault remain.

### D. Language service

Done: diagnostics, document symbols, completion, hover, definition, references and rename from one compiler snapshot,
served over LSP (`scripts/haxeon-lsp`) and the JSON-lines protocol.

- [~] Navigation follows compiler symbol identity for locals, members and imported functions; full type-aware navigation
  remains.
- [~] Editing recovers through last-good snapshots; true partial parsing of incomplete code remains.

### E. Self-hosting and release

Done: the compiler's own sources compile with Haxeon; compiler A (built by official Haxe) and compiler B (built by A) are
byte-identical; `bootstrap/compiler.hl` is checked in and rebuilt identically by `bootstrap-compiler.sh --self`; CI checks
self-hosted convergence.

- [~] The differential suite compares official Haxe and Haxeon on ten paired programs (`tests/differential`); collections,
  diagnostics and reload classification need more coverage.

## Next

1. Close the Haxe compatibility gaps in section A, `using` first, so ordinary Haxe and Pragtical code compiles.
2. Measure memory and latency on a realistic Pragtical project, then decide on parallel typing.
3. Turn the Pragtical fixture (`tests/fixtures/pragtical`) into a real Pragtical utility plugin running in a reload
   domain.
4. Structural reload domains with state migration, then larger editor subsystems, then the editor core.

## Definition of Pragtical-ready

A representative plugin can be edited and saved while the editor keeps running; compatible function edits patch in
place; class-layout edits reload only that plugin's domain; diagnostics and completion come from the same compiler
snapshot; a clean build works from the checked-in bootstrap compiler; and the differential suite covers every language
feature the migrated code uses.

## How to spend complexity

- Keep the editor process authoritative: a bad edit leaves the previous plugin generation running and its diagnostics
  visible. Structural changes report a domain boundary before any native staging.
- Migrate plugins first, then shared services, then the editor core, keeping an official-Haxe differential build until
  each feature is covered.
- Measure before optimizing. SSA quality, JIT tuning and parallelism follow correctness, reload safety and editor UX.
