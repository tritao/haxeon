# The typer's per-build state as results

Status: accepted (pieces 1, 2 and 5 first; piece 4 with engine slices 6 and 7); pieces 1 and 5 are built ("As built", below), piece 2 is not yet. Step 3e of [QUERY_ENGINE.md](QUERY_ENGINE.md)'s plan, beside 3c and 3d.

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
`canonicalInterfaces`, `canonicalProgramFunctions`) give a `ModuleDeclarationKeys`, kept in the session's database
(`SessionState.declarationKeys`, a computed kind by module id, put every build by `FrontendCompilation.keptDeclarations`): a
module whose canonical arrays are the ones its keys were made from puts the same object again, so only a module canonicalized
again pays. The key is the canonicalization rather than the parse: a module canonicalized again (its alias revision moved) has
new function objects even when its parse is kept. What is kept is small: the canonical arrays, which the module holds anyway,
and one flag per function, `leavesSignatureToInference` of it, computed once. A function's key (its owner's name and its own)
is made the first time a build looks the function up (`ModuleDeclarationKeys.find`, a walk of the module's declarations), and
the build keeps it in a map of its own, which the table forgets once the program is typed (`DeclarationTypeTable.endTyping`): the
semantic program keeps the last table. A module's functions are found through the file most of them name. A first version
kept a map of keys per module, which added 1.8 MB of live data on the UI app's server.

The table (`DeclarationKeys`, owned by `DeclarationTypeTable`) finds a function's module through the file its span names; the
functions the semantic program made itself (an abstract's methods with the owner's type parameters, implicit constructors,
interface accessors, a function given its new body by `replaceBodies`) and the typer's aliases get keys of their own. Those are
found by walking the program's declarations and skipping each one whose methods array is a module's own: a class
`replaceBodies` refreshed is another object, but keeps the methods array it did not change, so 603 classes cost one comparison
each and about 75 functions get keys of their own.

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

What `SemanticAssembly` built before canonicalizing (the alias setup: source type aliases by spelling and module, the enums'
cases, module-level members and their storage, pattern constants, inferred declarations, `@:discoverMethods` prefixes, the
alias universe and the static-extension table) is `ProgramNames`, made from each module's `ModuleNames`. A module's
`ModuleNames` is made once per parse (and entry module) and kept by module id (`SessionState.moduleNames`); `ProgramNames` is
kept at one key (`SessionState.programNames`) and made again only when a module's names differ from those it was made from,
compared by content where the object is another one (a body edit parses again, with the same names); it then takes the same
tables without the old parses. What a `using` reads of a module is compared too, only for a module the static-extension table
resolved a `using` to (`StaticExtensionTable.offeredKey`, its declarations and static functions as written, made the first
time it is compared). What only a module canonicalized again reads (the dotted and plain aliases, the aliases by package and the
types each package sees) is indexed in the build that first canonicalizes one (`ProgramNameIndex`), and the prefixes a subclass
inherits are found then too.

Changed from the plan: the tables are one summary made whole when a module's names change, not tables updated per
contribution. A module's names change only with its declarations, and every such change already canonicalizes every module
again (the alias universe moves); per-key updates would cost more code than the rebuild they save. The alias universe's
revision stays the per-state one of 8bca2e7f0 (`SessionState.aliasUniverseRevision`), compared once per build against the kept
universe, so a build that reverts a declaration a rejected build added keeps the revision its modules were canonicalized at.

These kinds and the declaration keys hold values a build puts from its own state, which the engine's rollback did not touch
when it undid no result (a build that fails while typing writes none). Such a kind is now made `ofState`: a rollback to a
commit before a value was put drops it (`QueryKindBase.forgetStateAfter`), so after a build that is not taken or a rejected
publication each holds what the state returned to held, or nothing (`TyperStateMain`, `QueryEngineMain.stateKinds`).

`--check-reuse` makes the names afresh from every module and compares them with the kept ones (`ProgramNames.difference`).

A module's names are kept as a digest of their parts (`ModuleNameParts`), which are made again from the parse when the whole
is made, and checked against names made afresh under `--check-reuse`.

Measured (edit-cost session, after piece 1, before the per-build index): `alias-setup` of the no-op 10.0 → 0.2 ms, `frontend`
18.7 → 12.1 ms (body edit 22.8 → 14.5 ms); main-thread instructions of the no-op 0.605 → 0.561G (−7.3%) and of the body edit
1.540 → 1.494G (−3.0%); allocation of the no-op 66.1 → 62.2 MB and of the body edit 164.5 → 160.1 MB. Making the index per
build costs the body edit about 4 ms and 17M instructions (it canonicalizes the edited module again) and saves its tables on
every build in between.

### Pieces 1 and 5 together

Against 182e4bf3d, perf-guard on one machine: no-op 0.585 → 0.542G main-thread instructions (−7.4%), body edit 1.523 →
1.489G (−2.2%), signature edit 17.36 → 16.90G (−2.6%); allocation of the no-op 66.5 → 61.1 MB and of the body edit 176.9 →
172.4 MB; the incremental session's live data 792.7 → 791.6 MB. The edit-cost session's phases: `setup` 16.3 → 8–10 ms,
`frontend` 24.5 → 11.6 ms (`alias-setup` 13 → 0.2 ms), `generated` unchanged (about 23 ms, piece 2). A cold alias setup is
11 → 13 ms. The small project is unchanged (instructions and allocation within 0.7% of origin/main measured the same day).

Live data: the UI app's server holds 0.7 MB more after the live edits (census 439.8 → 440.5 MB, `aot_ui_server_live_bytes`
+0.16%): the names every module sees (0.85 MB, `ProgramNames`) are new, the old table's map of keys (0.95 MB) is gone, and the
keys the last table looked up (0.73 MB, `DeclarationKey` and its map) are still there: something in that session looks them
up after the program is typed, which the compile server on the compiler's own sources does not; not found yet.

### Piece 2: not built yet

Measured on the same session after pieces 1 and 5 (`generated` about 24 ms on a no-op): `keepAnonymousUnits` 10–12 ms (every
unit of the previous program's `anonymousUnits` looked up and its types discovered again), the two `registerProgramTypes` calls
14 ms over the classes, interfaces, enums and natives (all of them, kept or not; the functions are only the build's own, about 100,
0.7 ms), of which registering anonymous types 6 ms, generic owners 4 ms and enum representations 1.5 ms; the generators and the
drain of generic owners about 10 ms, part of which is piece 3's 26 specializations. Replaying a kept unit's recorded discoveries
into a new `TypingSession` would cost about what walking its types costs now, so the piece needs the registries
(`TypingSession.anonymousTypes`, `EnumRepresentations`, the generic-owner requests) to outlive the session as summaries over
the units' contributions, with their order (the program lists enum representations and owners in discovery order) a result of
the summary rather than of the walk.
