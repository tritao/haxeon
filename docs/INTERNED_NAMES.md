# Interned names: design note (no code)

Status: proposal for ADR 0003 M3, 2026-11-10. Input: the cold CPU profile `coldprof6` (48.7 s on-CPU, 770M allocations).

## What the profile says

String-keyed maps and string comparison are about 28% of cold on-CPU time: `hl_hash_gen` 12.0%, `hl_hbfind` 6.0%, `hl_hbset_impl` 2.3%,
`hl_bytes_compare16` 3.0%, `String.__compare` 2.3%, `ucmp` 1.4%, `hl_bytes_find` 1.3%. Inside the IR passes `StringMap.get/set/exists` are
20% of that phase's self time, in the semantic phase 29%.

Not all of it needs a global `Name` type. Reading the hottest spots, three different problems hide behind "string maps":

| Hot spot | What it does | What fixes it |
| --- | --- | --- |
| `SsaBuilder.computeLiveness` | a `Map<String, Bool>` per block for use, def, liveIn, liveOut, keyed by local variable name | number the function's locals once (name to dense int), use bit sets. Function-local, no global type. |
| `ModuleCanonicalizer.bindNames` | copies the whole scope map for every binder (quadratic in scope size) | a scope chain (parent pointer plus one small map), no copy. Not an interning problem. |
| `SemanticAssembly.visibleTypeAliases` | for each package segment scans every source alias with `startsWith` and `substring` (string allocations) | index the aliases by package once, then walk segments. An algorithmic fix. |
| `ModuleAnalyzer.isImportedMember` | linear scan of a module's declaration lists comparing names | a per-module `Map<name, kind>` built once when the module AST is analyzed. |
| IR passes: `objects.get(name)`, `functions.get(name)`, `byName`, method tables | one hash per lookup of a class, function or method name, repeated for the same names across passes | a program-wide `Name` (below); the method-resolution table (IrMethodResolution) already removes the worst repeats. |

So the plan is in two tiers: fix the three structural ones first (no new type, large share of the semantic and liveness cost), then introduce
`Name` for the IR tables, where the same few thousand names are hashed again and again.

## The type

One `Name` per distinct string in one compiler process: a final class holding `text:String` and `id:Int` (dense, assigned in creation order),
created through one `Names.of(text)` table. Identity comparison (`==` on the reference) replaces string comparison. Two keyings:

- dense `id` into arrays (`Array<IrObject>` indexed by class name id): no hashing at all; best for the object, function and method tables;
- `ObjectMap<Name, T>` where the keyed set is sparse. HashLink hashes an object key by pointer, so no string is hashed.

The table is append-only for the life of the process. `Name` instances are never freed, which is fine: the set of names in a program is bounded by
its declarations plus generated helpers (about 10^5), and the live-patching worker keeps the table across builds, so ids stay stable for the
patched module.

## Where names are created

At the two points where strings enter the compiler's own representation, and nowhere else:

1. the lexer/parser: declaration, member, field and local names;
2. IR generation: generated names (`$optional-scalar:...`, dispatch entries, positional names), made once from the pieces.

A pass that builds a name (concatenation, prefix) builds it through `Names.of`, so the cost is paid at creation. Prefix tests
(`isDispatchEntry`, `isAdapterEntry`, `PositionalName.is`) become a flag set at creation, not `startsWith` at every use.

## What stays a string

- anything serialized: the HashLink module and debug sections, the runtime ABI file (`RuntimeAbiCodec`), the pipeline snapshot, the inline
  cache's fingerprints and object prints, Wasm output, error messages and the LSP. A `Name` is never written; its `text` is. The id is a
  process-local fact and must not leave the process. Reading serialized state calls `Names.of(text)` once per entry.
- hot reload: the patch protocol and the module's function table are keyed by the function name text. The live worker maps text to `Name` on
  load and back on emit; positional names keep their text form on the wire because their tail encodes source places.
- user-visible text: diagnostics, `--timings`, dumps.
- map iteration order: code that sorts names for determinism sorts by `text`, never by `id` (ids depend on creation order, which depends on
  which module is typed first). Checked by the byte-identical output gate in both modes.

## Order of the work (each step its own commit, each measured by CPU seconds)

1. `computeLiveness` slot numbering, `bindNames` scope chain, alias index, `isImportedMember` index. No new type; semantic and SSA phases.
2. `Names` and `Name`, used first inside `IrProgramIndex` and `IrMethodResolution` (class, method and function tables) behind their existing
   `String` API, converting at the boundary. Measure.
3. Move `IrObject.name`, `IrFunction.name`, call and method-call operands to `Name`. This is the large mechanical step; it touches every pass and
   the serializers, so it is done last and only if step 2 shows the gain.

## Risks

- A `Name` created in one process and compared in another is a bug that reads as "never equal". Mitigation: ids are never serialized, `Name` has
  no public constructor, and check mode (`HAXEON_CHECK_REUSE=1`) compares the text form of reused entries against a fresh run.
- Memory: a `Name` is a two-field object plus its string; the table pins them. At 10^5 names it is a few MB, against a 5 GB worker.
- Wasm and C backends: they read names as text; the conversion is at their input. No behaviour change expected.


## Measured, 2026-11-11: Name ids inside the method tables do not pay

Step 2 as written above (Name ids inside `IrProgramIndex` and `IrMethodResolution`) was measured on a cold profile of the tree after the
method-resolution table landed (10,052 samples, 199 Hz): `IrProgramIndex` is 0.01% of cold CPU and `IrMethodResolution` 0.12% (its
`uniqueImplementation`, `subtreeOf`, `find` and `methodsOf` together). Do not do it; there is nothing to win.

String-map operations are still 22.6% of cold CPU, but they are spread thin over many callers. The ones in the IR passes are the
verifier's tables (`IrVerifyTable.exists` 0.82% and `.get` 0.46%, `IrObjectTable.get` 0.53%, `IrVerifyMemo.note` 0.42%) and the inliner
(`consultResult`, `calleeOf`, `inlinedVersion`, `computeComponents`: about 1.9% self, 10.9% inclusive). The inliner hashes a callee name five
or six times per call instruction; those are better fixed by giving each function a dense id once than by a program-wide Name type.
The SSA builder was the same story and was fixed the same way (locals numbered once, 5.9% to 4.5% of cold).
