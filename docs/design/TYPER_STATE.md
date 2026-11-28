# The typer's per-build state as results

Status: accepted (pieces 1, 2 and 5 first; piece 4 with engine slices 6 and 7); pieces 1, 2, 3 and 5 are built, and of piece 4 the prune's and retention's edges ("As built", below); piece 4's object tables are not yet. Step 3e of [QUERY_ENGINE.md](QUERY_ENGINE.md)'s plan, beside 3c and 3d.

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

- Piece 4 lands with engine slices 6 and 7, which hold the same object tables. Slice 6 shares none of them: its steps read the
  final IR's tables, which the publication's (the program's objects, `irObjects`) first meet in lowering's object facts
  (`HlLoweringView`), so piece 4 lands with slice 7 ([QUERY_ENGINE.md](QUERY_ENGINE.md), "Slice 6 as built").
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

Live data: on the UI app's server after the live edits the census is 363.3 → 363.4 MB against origin/main at 87532f049
(`aot_ui_server_live_bytes` 380.95 → 381.05 MB, +0.03%): the names every module sees (0.85 MB, `ProgramNames`) are new and the
old table's map of keys (0.95 MB) is gone. A semantic program kept across builds holds the function objects of the
canonicalization it was made from, which a module canonicalized since no longer holds, so the table makes their keys itself
(4,500 in the UI app); the publications' snapshots kept those of each build's table (0.73 MB) until the table forgot them, with
the keys it looked up, once the program is typed (`DeclarationKeys.forgetLookups`, made again if a later lookup needs them).

### Piece 3: generic-owner specializations kept

A specialization is a unit with an output of its own: `TypingSession.typeOwnerSpecialization` types it into its own
`TypingOutput`, merged into the program's at once (so a cold build's output is as before), and records its reads under the
specialization's name: the generic class's shape and members, each instance method's signature and body, each instance
field's initializer, and the unit of each specialized method and initializer. The kept value is the engine's: a kind,
`SessionState.ownerSpecializations`, holds the class and its output by symbol, rolled back with the build. `retainedFromPrevious`
keeps one when the kind holds the previous program's class, it has a record and the build's invalidation does not name it
(`RetainedFromPrevious.specializations`); `SemanticAssembly.unitExists` knows a specialization (`GeneratedNames.isOwnerSpecialization`),
so a changed one is invalidated rather than losing its record. Keeping it (`TypingSession.keepOwnerSpecialization`) merges its
output again: it asks again for its helpers, owners and enums, brings back its lambdas and structures and its owners' aliases,
and the same class and method objects go back into the program, so IR generation skips them. A specialization whose typing made
a key path definition is typed again, as those live outside the outputs. `TypingOutput.mergeInto` no longer marks a shared unit
merged when the build has no output for it, and `pruneModule` drops a specialization's record with its methods. A specialization's
record asks for what its methods call only while the program still has it (`reachedSpecializations`), so a generic function's
specialization only a dropped one called goes with it; the specializations a build asks for again before typing
(`retainedFromPrevious`) follow the same rule, through the records of the units it keeps.

The compiler's own sources have 33 specializations with 733 methods, typed again on every warm build before this (about 100 ms
of a 138 ms `generated` phase, and 40 ms of IR, in a 362 ms no-op). The frozen perf-guard input has 7, so its gain there is
small; `tests/compiler/TyperStateMain.hx` covers an `@:generic` class kept, and taken back when a publication is refused.

### Piece 4: the prune and retention follow edges kept by module

What the publication's whole-program questions read of a module's functions is that module's contribution, kept with it
(`ModuleFunctionEdges`, `ModuleState.functionEdges`) and copied with it, so a build that is not taken leaves the edges of the
state it copied. Two parts, each made the first time it is asked for:

- **The prune's**: which of the module's typed functions are shared provider helpers, and the shared helpers each of its IR
  functions calls. `stillCalled` answers what `generatedHelpersStillCalled` answered by reading every body of the program: which
  shared helpers a function that stays, or a helper that stays on its own, still calls.
- **Retention's**: for each IR function that has one, the generated class it is a method of (or a lambda of one), the enum
  specialization it is a helper of, the function specialization it is made in, and the generated types it names. Only these
  functions are read by `retainedFromPrevious`; a function that belongs to none and names no generated type has nothing to
  retain. Its walk no longer builds maps of every function of the program, nor reads every function's type mentions.

Where publication or the prune changes a function (`publishFunctions`, `generatePendingIr`, `removeCachedFunctions`), it marks it
(`ModuleFunctionEdges.changed`); each part reads the marked functions again the next time it is asked for, so a kept function is
not read at all, and a changed one is read in the build that asks, as before (the prune after publication, retention in the next
build). The kinds that held each function's calls and type mentions (`SessionState.irCalls`, `irTypeMentions`) are gone: the
edges read a function once per change.

A call is recorded by its callee's name (the callee may be in a module not read yet), so the shared helpers' names are one prefix
per generator; retention's generated types are known by name too (`$generic:`, an enum specialization, an enum's interface
adapter, a key path cache). `--check-reuse` holds every shared helper and every type retention may keep to those names, and makes
every module's edges afresh and compares them with the kept ones (`ModuleFunctionEdges.check`); the programs suite with
`--check-reuse` is what found the interface adapters missing from a first list.

Warm-equals-cold bug 3 is fixed on the same edges: `Slot.map` at `String` in `Main.main` made a shared helper whose origin is
`Main.main`; undoing the edit typed `Main.main` again without the call, and the prune dropped the helper, but retention had counted
its IR before typing, so `Slot<String>` stayed in the warm program. Retention now counts a helper made for a function typed again
(directly or through another such helper) only when a caller that stays calls it, which is the prune's question asked with
"typed again" before typing (`helpersMadeAgain`, `stillCalled`). One rule serves both. A helper is held by the module of its
origin, so only the modules of the functions typed again are read; a no-op reads none. The warm-edit catalogue has no known
failure left.

Not built, with the reasons:

- **`objectsFrom` per class as a contribution.** A class's object is a function of its typed class, but also of how its field
  types lower and of its bases and observable facts, which a kept typed class does not record; a contribution keyed by the class
  would need those as recorded reads. It stays with slice 7, which holds the same object tables (above, "Decided"). Measured
  share on the no-op: `objectsFrom` about 10 ms of a 250 ms build.
- **The rest of the prune.** `pruneModule` still runs for every module (about 15 ms on a no-op): it also gives every kept generated
  function its owner, which a build needs each time, and its decisions read build-wide sets (what was typed, invalidated, still
  called), so skipping a module needs those as recorded reads first. `reachedSpecializations` and retention's scan of the unit
  records (about 3 ms each) and retention's `units` (about 7 ms, every kept function by name, which `keepAnonymousUnits` reads)
  are also whole-program; `units` went with piece 2 (below).

Lines in `src/`: 194 deleted and 499 added (`ModuleFunctionEdges` 347 of them, with its check).

Measured (perf-guard, all four parts, origin/main and this change back to back on one machine): no-op 0.767G → 0.723G
main-thread instructions (−5.7%), body edit 2.011G → 1.967G (−2.2%), signature edit 19.646G → 19.611G (−0.2%); allocation of the
no-op 84.1 → 81.5 MB, of the first no-op 133.3 → 126.3 MB, of the body edit 236.5 → 233.9 MB; the session's live data 893.3 →
889.4 MB (the two memo kinds gone, the edges kept), the UI app's live session 302.0 → 301.3 MB, the small project's 7.76 → 7.65 MB.
The small project builds and checks within 0.7% (all lower), and the cold self-compile within 0.1% (instructions +0.05%, live data at
the phase boundaries +0.2 to +0.3 MB), its output byte-identical. A first version without per-function marks made a module's
edges again whenever one of its functions changed, which made the signature edit 0.4% slower and read every function's type
mentions in the build that changed it; one that kept every function naming any `$` name held 5,600 entries instead of 1,600 and
grew live data by 0.9 MB.

### Piece 2: program types by unit

Before it, `generated` on a no-op of the compiler's own sources was about 36 ms of a 166 ms compile (VM, wall): `keepAnonymousUnits`
10 ms (3,295 units of the previous program's `anonymousUnits`, 12,158 entries, for 519 structures), the two
`registerProgramTypes` calls over every class, interface, enum and native 13 ms, and the signatures of the build's 1,036 functions
(733 of them the kept specializations' methods) 4.5 ms; retention's `units` 6 to 7 ms besides. Two contributions replace them,
each kept where its unit is:

- **Program types as uses** (`ProgramTypeUses`): the one walk of types for the three registries. It collects what types give them
  (the structures and key path descriptors, the enum specializations, and the class instances with arguments and the maps that
  may need a generic owner, each in walk order), and the registries register from what it collected: a body's types at once
  (`AnonymousTypeRegistry.register`, `EnumRuntimeRepresentations.discover`), a declaration's (a class's fields, an interface's
  methods, an enum's cases, the natives' signatures, a function's signature) by the program typer. The walks the registries had
  (`AnonymousTypeRegistry.discover` and `recordUses`, `EnumRuntimeRepresentations.discover`'s, `discoverGenericOwners`) are gone;
  stopping at what is registered already is a property of registering (`addStructure`), not of walking. A structure or enum that
  still holds a type variable is a waiting entry of the uses, registered by the same path once typing settles it
  (`MonomorphFrames.whenKnown`). The walk makes the uses only when it meets something to register, so the types that reach
  nothing, most of them, cost no allocation: a first version that made them for every type allocated 89 MB more in a cold build
  (enum discovery runs on every expression's type). Whether an instance needs an owner, or a map which one, reads the program's
  declarations, so that is decided when the uses are registered.
- **A declaration's uses kept.** The uses a build registered for its declarations are a value of the state it made
  (`SessionState.programTypeUses`, by declaration name, replaced by each build that types, as the pipeline snapshot is), and the
  next build keeps a declaration's while it is the object they were made of (a class's fields array, a function), so a kept
  declaration registers what its types name, in the order the walk met it, and walks nothing: enum specializations and owners are
  listed in the same order as before. Only uses that register something and that typing has settled (no type variable or open
  structure in the types) are kept; the natives are one declaration (their array is the program's while no declaration changes,
  and they have no origin); and of the functions, only a generated class's methods, the one function registered again as the same
  object (a kept specialization). Keeping every function's uses added 1.8 MB of live data; a version that kept them in a kind of
  the database by symbol, whose columns run to the largest symbol id, with one entry per native, cost the UI app's server 0.4 MB.
- **A unit's structures** (`ModuleStructures`, `ModuleState.structures`): what each unit met while it was typed or registered
  (`UnitRecords`), published with the unit's module as the key path uses are (`publishStructures`): a unit typed again gives its
  own, one only registered adds to what it had, and a module is written only when what it keeps changes; a function the prune
  removes takes its record with it. A generic owner's specialization keeps the structures of its members, and of what was made for
  them (their lambdas, their helpers), itself: a kept one merges its output again and registers its methods' kept uses, so its
  units have no record in a module, where they would outlive it until the prune (an edit of the structure an owner is specialized
  for left the old specialization's lambdas listing the old structure). The program lists the structures of the units the build keeps (`RetainedFromPrevious.structures`):
  each module's whole list, made once and kept until a record changes or the module is canonicalized again, unless one of its units
  is typed again or one of its functions is selected or invalidated, when its units are read one by one with the rule
  `keepAnonymousUnits` had (declared, a field's initializer, or a held function the build keeps). A module has a few units with a
  record, so they are two arrays, not a map. `TypedProgram.anonymousUnits`, `keepAnonymousUnits` and the unit records' kept half
  are gone; the build lets go of its own records once its modules have them.

Retention's `units` went with it: the generated helpers a build may keep are listed per module (`ModuleFunctionEdges.madeHelpers`,
marked as the other parts are, one shared empty list for the modules without any), so retention reads the helpers instead of every
function. One rule changed: a unit only registered in a build (a kept function's signature) used to replace what it had met; it now
adds to it, as a fresh build, which types it, would list both.

`--check-reuse` makes every kept declaration's uses again by the same walk and compares them (`TypedProgramAssembler.keptOrMade`),
and every module's kept list of structures with the one its records give (`ModuleStructures.check`). The warm-edit catalogue gained
two edits for this piece: the only field naming a generic enum or an `@:generic` class at a type removed. Two more, a body's only
structure removed and a static initializer that was the only structure of its shape removed, failed in live mode on origin/main
too: the session's objects never lost a structure the program no longer had, so its printer stayed in a live program. That fix
is a commit of its own, before this piece ("Drop the object and printer of a structure the program no longer has"); the catalogue
has no known failure.

Not done: the alias registration of the setup phase still walks every alias each build, and retention's scan of unit records
(about 2 ms) is unchanged. The objects a dropped function made stayed in the session; that is fixed below ("Objects by owner").
Package syntax trees cannot be released yet: piece 2's state is typed, and what reads the trees every
build is the frontend (SERVER_MEMORY.md, step 4).

Lines in `src/`: 299 deleted and 887 added (`ProgramTypeUses` 290, the walk with its registering and check, which replaces the
registries' walks; `ModuleStructures` 190; the program typer's loops over kept uses about 120, a third of it doc comments).

Measured (perf-guard, origin/main at eb417c4fa and this change built in two worktrees and run back to back on one machine): no-op
0.670G → 0.557G main-thread instructions (−16.8%), body edit 1.913G → 1.803G (−5.7%), signature edit 19.596G → 19.523G (−0.4%);
allocation of the no-op 72.5 → 63.0 MB, of the first no-op 117.4 → 108.4 MB, of the body edit 221.4 → 211.9 MB, of the signature
edit 1,067.2 → 1,059.3 MB; the session's live data 889.09 MB both. The UI app's live session 300.00 → 300.10 MB (one step of the
census's rounding, in every pair), the small project's 7.65 MB both, its builds and checks within 0.1% on the VM and lower ahead of
time. The cold self-compile is byte-identical, 62.82G → 62.66G instructions (−0.25%), allocation 2,901.7 → 2,887.5 MB, its live
data at the phase boundaries the same; the build lets go of its records once published (holding them to the end had added 3 MB).

### Objects by owner

The session kept the program's objects as one set (`SessionState.objects`) and removed from it by three rules: a class the
program no longer declared, a structure it no longer listed (3ee519728), and the closure objects of a function typed again, found
by name prefix (`isGeneratedObjectOfRetypedFunction`). Nothing removed the objects of a function that went without being typed
again: a specialization nothing asked for any more left its captured locals' cells, a conversion edited away left its iteration
adapter's environment (a prefix the rule did not know). Assembly filtered the set again (`resolvedObjectsFrom`: environments
whose lambda or adapter was not in the program, by two more name rules, and a fixpoint over objects whose field types did not
resolve), and `--check-reuse` compared only the objects a fresh build made, which hid the rest: a live build kept them.

Now every object has an owner, and is the program's while its owner is (`FrontendCompilation.programObjects`). A class or
structure of the typed program gives its object, made each build (`publishObjects`, as before). A function gives the objects its
typing made, the environment it runs in (its `owner`) and its locals' cells (`cells`), kept with it in its module
(`ModuleState.madeObjects`): set when the function is typed, kept with a function kept as the last build made it, and dropped with
it (`removeCachedFunctions`), so a candidate build's copy and a rejected build's rollback follow the module, as its functions do.
The program's objects are the declared ones and those of the functions its modules hold. `SessionState.objects`, the removal
rules, the name rules and the resolution fixpoint are gone; the generator lowers against the objects this build made, as it reads
only value classes' layouts. `--check-reuse` compares the objects whole, and checks that every closure object this build made has
a function that made it (`checkClosureObjectsOwned`). The warm-edit catalogue gained the two edits that showed it: a specialization
with a cell no longer asked for, and the only conversion needing an iteration adapter removed; both failed in plain and live mode
with the filter gone, and pass now.

Lines in `src/`: 144 deleted and 114 added.

Measured (perf-guard, origin/main at c98a03dcc and this change built in two worktrees and run back to back on one machine): no-op
430.5M → 404.9M main-thread instructions (−5.9%), body edit 1.592G → 1.568G (−1.5%), signature edit 19.10G → 19.08G; allocation
of the no-op 47.1 → 42.1 MB, of the first no-op 92.5 → 87.4 MB, of the body edit 159.2 → 154.1 MB, of the late body edit 168.1
→ 163.0 MB; the session's live data 886.05 MB both. The UI app's live session 300.00 → 299.79 MB, the small project's 7.65 MB both,
its builds and checks on the VM and ahead of time the same or lower. The cold self-compile is byte-identical.
