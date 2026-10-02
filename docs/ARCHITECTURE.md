# Architecture

## 🧭 What Haxeon is

Haxeon is both a focused Haxe-compatible language implementation and a live
execution environment built on a patchable HashLink runtime.

For the initial application load, the compiler emits a standard HashLink
bytecode module—the same format normally stored in a `.hl` file. Compatible
edits become compact Haxeon patch data containing only changed function bodies
and the symbol additions they require. The runtime validates and JIT-compiles
the entire patch privately before publishing it as one atomic transaction.

Haxeon is not currently a drop-in replacement for the complete Haxe compiler.
Language and standard-library coverage are still expanding, and edits that
change the live module's structure may require a reload.

## 🏗️ How it works

```text
Haxe-compatible source
        │
        ▼
 Lexer → Parser → Type checker
        │
        ▼
 Immutable SSA IR
        │
        ▼
 HashLink lowering and assembly
        │
        ├── Initial build ──→ HashLink bytecode module (.hl)
        │                      + Haxeon identity manifest
        │
        └── Compatible edit → Haxeon patch
                               │
                               └── validate → stage → commit
```

The implementation uses three short format names:

- **HLB** is the standard serialized HashLink bytecode format. Its bytes begin
  with the `HLB` signature and are normally written as a `.hl` file.
- **HLI** is Haxeon's companion identity manifest. It binds a module identity
  and stable Haxeon function IDs to the function slots in an initial HLB module.
- **HLP** is Haxeon's versioned patch protocol. It carries validated symbol
  additions and replacement function bodies between incremental builds and the
  live runtime.

HLI and HLP are Haxeon-specific data formats; neither changes the standard HLB
module, so generated `.hl` files remain compatible with ordinary HashLink.

The frontend is divided into parsing, declaration and type checking, and IR
generation. Modules retain their source, tokens, syntax trees, typed trees,
dependencies, diagnostics, and generated IR. Body and signature fingerprints
allow Haxeon to reuse unaffected artifacts and propagate invalidation only where
required.

IR values are immutable SSA definitions. Assignments create new values, while
condition joins and mutable loop headers receive explicit, predecessor-complete
phi nodes. The HashLink backend eliminates those phis on incoming edges with
parallel-copy snapshots, emits real `OLabel` block markers, and leaves no SSA
constructs in the serialized bytecode module or patch.

The same canonical IR can also be emitted as experimental `wasm32` or `wasm-gc`;
see [`WASM_BACKEND.md`](WASM_BACKEND.md) for the representation
boundary, linear-memory and collector contracts, GC target, and test commands.
