# The typer's per-build state as results

Status: accepted (pieces 1, 2 and 5 first; piece 4 with engine slices 6 and 7). Step 3e of [QUERY_ENGINE.md](QUERY_ENGINE.md)'s plan, beside 3c and 3d.

## Why

After the IR stages and the inliner moved onto the engine (slices 1–5) and generated helpers are kept
([WARM_REBUILD_REUSE.md](WARM_REBUILD_REUSE.md)), most of what a no-op build still does is the typer rebuilding state that
depends on the whole program, because `TypingSession` is new each build. Measured on the compiler's own sources (edit-cost
session, wall ms, at 4bf42ab4d): the no-op is 0.585G main-thread instructions, and of it

| Phase | No-op | Body edit | What it rebuilds every build |
|---|---|---|---|
| `setup` | 15–18 | 13–15 | `DeclarationTypeTable.new`: the `AstFunction` → key map and the inferred-key map over every declaration, `leavesSignatureToInference` for about 40k functions |
| `generated` | 23–25 | 22–23 | `registerProgramTypes` over every typed function, class, interface, enum and native: anonymous types, enum representations, generic owners discovered again; `keepAnonymousUnits` over every unit the previous program lists; 26 generic-owner specializations typed again (`takeFromPrevious`) |
| `ir-generation` | 40–42 | 41–42 | the publication step: `publishObjects`/`objectsFrom` over every class, the prune's module scans (`generatedHelpersStillCalled`, `pruneModule`), `retainedFromPrevious` |
| frontend | 23–26 | — | the alias universe sorted and joined, `indexAliasesByPackage`, `StaticExtensionTable.build` |

The signature edit is not the target: it retypes the functions whose calls really change, and step 3c's cutoff covers the
case where an inferred type stays equal. This step is about the floor every build pays.

## The rule

State the typer derives from the whole program becomes a **summary over per-unit contributions**, held by the engine across
builds. A unit (a module's declarations, a typed function, a field initializer, a generated helper) contributes its part when
it is typed or parsed; a unit that is kept keeps its contribution without being walked; the summary changes by the
contributions that changed. This is the pattern the IR stages already use (`IrContributionSummary`, slice 3), applied to the
typer, so no new machinery: computed kinds keyed by unit, summaries with per-key reads, the database's undo log for rollback.

What it rules out: session maps that survive builds by hand. A persistent map outside the engine either grows by one entry
per edit or breaks rollback of a build that is not taken (the reason the floor agent did not add one); the engine's undo log
gives both.

## The pieces

1. **Declaration keys by module** (`setup`). Each module's parse contributes its `AstFunction` → key entries and its
   inferred keys (what `DeclarationTypeTable.new` and `markInferred` compute now), computed once per parse of that module. A
   module whose parse is reused contributes the same object; the table reads the module's contribution through the
   function's module instead of one program-wide map. `leavesSignatureToInference` runs only for re-parsed modules.
2. **Program types by unit** (`generated`). `registerProgramTypes`' discoveries (anonymous types, enum representations,
   generic owners) become each unit's recorded contribution, which `AnonymousTypeRegistry` already attributes to units for
   `anonymousUnits`. A kept unit's contribution stays; the registries are the union. `keepAnonymousUnits` goes: it is this
   rule done by hand over the previous program.
3. **Generic-owner specializations kept** (`generated`). A specialization is a unit like a generated helper: kept while
   nothing it read changed, which needs the specialized class's field shape to be a recorded read first.
4. **Publication by contribution** (`ir-generation`). `objectsFrom` per class as a contribution; the prune and
   `retainedFromPrevious` follow reverse edges from unit records (COMPILER_FOUNDATIONS item 1) instead of scanning modules.
   This piece shares its object tables with engine slices 6 and 7 and lands with them if that is simpler.
5. **Frontend tables by module** (frontend). The alias index by package and the static-extension table as summaries over
   each module's aliases and extensions; the sorted alias universe only when a module's aliases change (its revision is
   already recorded since 8bca2e7f0).

## Checks

- Warm equals cold, as for every engine step: `--check-reuse` compares each summary with one built from scratch, the programs
  suite with `--check-reuse`, the edit replay, a self-compile byte-identical.
- Rollback: a build that is not taken, and a retracted publication, leave every summary as the build before it
  (`QueryEngineMain`-style tests on the new kinds).
- Each piece lands only if no edit gets slower and live memory does not grow (`perf-guard --only=incremental`, `--only=live`).

## Order and expected effect

Pieces 1, 2 and 5 are independent and small to medium; 3 needs a recorded read added to typing; 4 is the largest and may go
with slices 6/7. Expected together: the no-op from 0.585G to roughly 0.25–0.3G and the body edit by about 0.25G, an
estimate from the phase times above, to be measured per piece.

## Decided

- Piece 4 lands with engine slices 6 and 7, which hold the same object tables.
- Piece 1 keys by module parse: a module's re-parse replaces all its `AstFunction` nodes, so a finer key would gain nothing.

## As built

### Piece 1: declaration keys by module

Each module's canonical declarations (`ModuleState.canonicalClasses`, `canonicalAbstracts`, `canonicalEnums`,
`canonicalInterfaces`, `canonicalProgramFunctions`) give a `ModuleDeclarationKeys`: the key of each function they hold and of
those whose signature the source leaves to the body, with `leavesSignatureToInference` called once per function. It is kept in
the session's database (`SessionState.declarationKeys`, a computed kind by module id, put every build by
`FrontendCompilation.keptDeclarations`): a module whose canonical arrays are the ones its keys were made from puts the same object
again, so only a module canonicalized again pays. The key is the canonicalization rather than the parse: a module canonicalized
again (its alias revision moved) has new function objects even when its parse is kept.

The table (`DeclarationKeys`, owned by `DeclarationTypeTable`) finds a function's keys through the file its span names, then in
a small map of its own for the functions the semantic program made itself: an abstract's methods with the owner's type
parameters, implicit constructors, interface accessors, a function given its new body (`replaceBodies`), and the typer's
aliases. Those are found by walking the program's declarations and skipping each one whose methods array is a module's own: a
class `replaceBodies` refreshed is another object, but keeps the methods array it did not change, so 603 classes cost one
comparison each and about 75 functions get keys of their own.

Two things went with it. Seeding is by read: a function this build does not type gets the signature an earlier build gave it
when it is first read, from the module that owns its key (`DeclarationTypeTable.seed`), instead of every signature of every
module being merged and seeded up front; and a cycle diagnostic takes the function from the forced functions, not from a
program-wide map by key.

`--check-reuse` makes the keys afresh from the whole program, as the table did before, and compares every function's
(`DeclarationKeys.check`).

Measured (edit-cost session on the frozen input, against 182e4bf3d): `setup` of the no-op 16.3 → 7.7 ms and of the body edit
16.6 → 8.9 ms, the table itself 12 → 0.5 ms; allocation of the no-op 67.8 → 66.1 MB and of the body edit 166.2 → 164.5 MB.
Main-thread instructions did not move (no-op 0.606 → 0.605G, body edit 1.538 → 1.540G): the table's cost was memory, maps of
15,000 entries filled every build, not instructions.

### Piece 5: the names every module sees

What `SemanticAssembly` built before canonicalizing (the alias setup: source type aliases by spelling, module and package, the
enums' cases, module-level members and their storage, pattern constants, inferred declarations, `@:discoverMethods` prefixes,
the alias universe and the static-extension table) is `ProgramNames`, made from each module's `ModuleNames`. A module's
`ModuleNames` is made once per parse (and entry module) and kept by module id (`SessionState.moduleNames`); `ProgramNames` is
kept at one key (`SessionState.programNames`) and made again only when a module's names differ from those it was made from,
compared by content where the object is another one (a body edit parses again, with the same names). What a `using` reads of a
module is part of its names (`StaticExtensionTable.contributionKey`: its `using`s, its types' `@:using`, and each declaration's
name, privacy, kind and static functions as written), so the table is kept with the rest.

Changed from the plan: the tables are one summary made whole when a module's names change, not tables updated per
contribution. A module's names change only with its declarations, and every such change already canonicalizes every module
again (the alias universe moves); per-key updates would cost more code than the rebuild they save. The alias universe's
revision stays the per-state one of 8bca2e7f0 (`SessionState.aliasUniverseRevision`), compared once per build against the kept
universe, so a build that reverts a declaration a rejected build added keeps the revision its modules were canonicalized at.
The prefixes a subclass inherits are found only when a module is canonicalized again.

These kinds and the declaration keys hold values a build puts from its own state, which the engine's rollback did not touch
when it undid no result (a build that fails while typing writes none). Such a kind is now made `ofState`: a rollback to a
commit before a value was put drops it (`QueryKindBase.forgetStateAfter`), so after a build that is not taken or a rejected
publication each holds what the state returned to held, or nothing (`TyperStateMain`, `QueryEngineMain.stateKinds`).

`--check-reuse` makes the names afresh from every module and compares them with the kept ones (`ProgramNames.difference`).

Measured (edit-cost session, after piece 1): `alias-setup` of the no-op 10.0 → 0.2 ms, `frontend` 18.7 → 12.1 ms (body edit
22.8 → 14.5 ms); main-thread instructions of the no-op 0.605 → 0.561G (−7.3%) and of the body edit 1.540 → 1.494G (−3.0%);
allocation of the no-op 66.1 → 62.2 MB and of the body edit 164.5 → 160.1 MB. A cold build's alias setup grows 11 → 25 ms: it
makes every module's names, the static functions' signatures among them.
