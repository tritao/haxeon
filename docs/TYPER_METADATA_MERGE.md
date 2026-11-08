# Typed metadata merge: warm rebuilds and the cold-build frontend restart

Status: done (2026-11-08). Open items at the end of Results. Branch `typer-metadata-merge`.

## Findings from step 1 (refined root cause)

The warm failure needs three things together, which is why plain unit tests did not reproduce it:

1. The program reads a code identity, so the generated module `haxeon.build.CodeIdentityTable` is part of it.
2. A reused session reads every loaded module from disk again (`CompilerSession.prepare`, then
   `Compiler.refreshLoadedSource`). The table module is generated text: its file holds the template and the compiler renders
   the identities between the markers. The template differs from the rendered text, so the module was treated as edited
   on every warm build, `CodeIdentityTable.refresh` rendered it again, and the compiler saw a structural change to
   `static:haxeon.build.CodeIdentityTable.data`.
3. Any structural change makes `canReuseSemantic` false (`FrontendCompilation`). The typer then runs without cached
   metadata but with a partial `selected` set (one function here), builds specialized owners only for the functions it
   retypes, and the prune step retires every other specialization (`fn.physicalOwner` not in `currentSpecializedOwners`).
   Unchanged callers still reference them, here through a bound method of `Promise<Array<String>>`, and erasure fails
   with `Missing target for generic method reference`. The class needs an owner of its own: `Promise<T>` reaches the
   generic enum `Outcome<T>` through `Future<T>` (`TypeRepresentation.genericOwner`).

So there are two defects. (A) re-reading a generated module's template is not an edit. (B) the non-reuse typer path
drops specialized owners that unchanged code still uses; this is also what a restart with added modules needs fixed.
The "metadata merge" of the plan is therefore about carrying specialization state (owners, aliases, enum
specializations) into the non-reuse path, not about the cost of declaration metadata: with a small `selected` set the
"metadata" phase is cheap, since it is mostly the typing of the selected bodies.

Design of fix (A): `ModuleState` keeps `loadedText`, the text the caller supplied (the file as read from disk), apart from
`source`, the text that is compiled. `Compiler.update` and `refreshLoadedSource` compare an incoming file with
`loadedText` for every module; the generated identity table renders into `source` through `ModuleState.render` and leaves
`loadedText` alone. `Compiler` knows nothing about the table.

Design of fix (B), `RetainedFromPrevious` (`ProgramTyper.takeFromPrevious`): every typing pass, reused metadata or not,
asks again for what unchanged code still takes from the previous typed program. Owners and enum specializations are
requested again and typed from the current declarations (a specialization of an edited generic class is rebuilt, not
copied; one whose type arguments no longer exist is dropped, `TypeRepresentation.typeNamesExist`). Generated classes no
source declares (key path caches) are copied with only the static fields retained code reads. What is retained is
decided by `FrontendCompilation.retainedFromPrevious`, which scans every function that stays in the program (not only
those a source function reaches: later IR passes inline helper calls into the cached callers, so the helpers left behind
are what still name their classes and fields). The methods of a generated class and the helpers of an enum
specialization count only once something else retains their type, otherwise they would keep it alive for ever.
`callersOfSpecializations` also follows `$generic-method-reference:` closures.

Scenarios in `tests/compiler/TypedMetadataMergeMain.hx`: second compile without an edit; after editing the entry module, the
module that makes the specialization, the module that binds the method, the generic class; after giving the generic class
a method; after adding a module; after removing the modules that make and bind the specialization while `Promise<Int>`
stays in the program. Each compares the specialized owners (fields, methods), enums and aliases with a fresh compile of the
final sources. Mutation checks: with the enum filter removed the removal scenario fails; with the all-functions scan seeded
from owner methods too it fails (owners pile up).

Key path caches: a retained cache class is copied from the previous program (fields in a new array), so a retyped function that
asks for the same cache finds that copy by name and adds its field to it: one class, fields united. A key path helper is shared
and recorded under one origin (the root's constructor, `Node.new`), which used to keep it after its last user was edited away.
Each typed function now records the key path literals it uses (`TypingSession.keyPathUses`, kept in `ModuleState.keyPathUses`
and dropped with the function), and after the prune `pruneUnusedKeyPathHelpers` removes a literal's helper and its `:read` and
`:write` accessors when no function that stays uses the literal. `dropUnusedKeyPathFields` then leaves one static field per
helper in the program, so the cache equals a fresh compile's. The scenarios that end a key path's last use require exact equality.

Cost of `retainedFromPrevious` on `app` (31,841 functions, every instruction of every non-selected function): 354-357 ms
per pass on the warm builds (loaded machine). Below the 0.5 s bar, so no per-function summaries yet; the restart pass will
run it once more.

Name parsing: the enum helper ownership and the method reference origin are read through `EnumRuntimeType.helperHash` /
`specializationHash` and `GenericOwnerErasure.methodReferenceOf`, next to the code that builds those names. A helper's hash
is its last `HASH_LENGTH` characters; a method reference's class is a declared generic class (no colon) and everything
after the member may contain colons. Debt: these are still names, not fields; a structured record of the helper's enum and
the reference's class and member where the IR function or closure is made would remove the parsing.

Results of step 2 (materia at e11c35e2f^, since `app` on main needs `haxeon.build.InputFiles` from uncommitted stdlib edits):

| `app` build | compiler | functions retyped | objects allocated | bytes |
|---|---|---|---|---|
| cold | 74-106 s (noisy) | 30,479 | 878.9M | 36.5 GB |
| warm, no edit (fails before) | 31-57 s | 0 | 223.3M | 11.6 GB |
| warm, after editing `Main.hx` (fails before) | 41 s | 33 | 272.6M | 13.6 GB |

Where a warm no-op build spends its 223M objects (`--timings` allocation phases): backend assembly 100.2M (function lowering
71.2M, verification 19.9M, debug 4.7M; the same as a cold build, 99.8M), IR assembly 98.5M (whole-program IR passes; cold
168.5M, the difference is IR generation), semantic 9.9M, typing and lowering 10.3M, graph 1.3M, ABI 2.6M, encode 25.8M. By time:
IR assembly 12.3 s, backend lowering 11.8 s (lowering 6.3 s, verify 1.8 s), output 2.5 s, frontend 1.9 s, typing 1.5 s. A plain build
assembles from scratch, so the per-function lowering cache never applies; not changed here.

## Steps

Step 1 (done): `tests/compiler/TypedMetadataMergeMain.hx`; its failing scenarios are added together with their fix (no
failing tests on the branch). Step 2 is split: 2a is (A) with the scenario that passes; 2b is (B).

### 1. Reproduce in a small compiler test
Add a test in `tests/compiler/` (pattern: `FrontendRestartMain.hx`, `SpecializedMapIncrementalMain.hx`) that reproduces
the warm-rebuild failure with a `Compiler` instance compiled twice, ideally with a small generic class
specialized by a method of another module (as `Promise<Array<String>>.cancel` is). Find the smallest trigger: no edit
at all, an edit to an unrelated module, an added module. Record which ones fail on `main`. Commit the test, expected
to fail, only together with the fix in step 2 (no failing tests on the branch).

### 2. Merge typed metadata instead of taking it wholesale
In `ProgramTyper`, on the cached path:
- type the enums, interfaces and classes of modules that are new or changed since `cachedMetadata`, and merge them with
  the cached declarations of unchanged modules (one rule, no special case for "restart");
- keep the generic owners that retained functions still reference, so the prune in `FrontendCompilation` only
  retires specializations nobody uses.
Pick the long-term clean design: metadata tracked per declaring module, so merging is "replace the entries of
changed modules", not ad-hoc patching. Write down the design in this file before coding it.
Gate: the step-1 test passes; the warm second `app` build succeeds; the full driver suite has no new failures.

### 3. Make the frontend restart a continuation (landed 2026-11-08)

Two kinds of reason made the frontend restart, and they need different treatment:
- **A module a function only calls** (`haxeon.DynamicOps`, `Reflect`, `ObservableSource`, `ReactiveRuntime`, `Std`, `FloatBits`,
  `Int64`): typing a body does not depend on the module being present. The dependency check runs after the typed functions are
  published and the next pass is a continuation: it gets empty change sets, carries `regenerated` and `retyped`, and
  `SemanticAssembly.run(..., continuation)` does not treat it as a first build. It types the new module's functions only. Reasons
  are reported in `metrics.frontendRestarts` and the functions each pass typed in `metrics.frontendPassFunctions`.
- **A module that changes a representation**: only `haxeon.collections.HashMap` does (`RuntimeDependencyTracker.changesRepresentation`).
  The specialized map owner exists only while the module is in the program, so everything typed without it is typed against the
  wrong representation (the first attempt failed IR verification on `TextLayout.graphemeGeometry`). Such a module is never
  discovered late: `FrontendCompilation.seedRepresentationModules` makes `RuntimeType.SPECIALIZED_MAP` a root module of every
  compile that can find it (two functions, +7.5 KB, in a program that has no use for it). An intermediate version found it from the
  declarations (`TypingSession.requiresSpecializedMap` over typed fields and signatures, before any body) and restarted the
  frontend to add it; seeding replaced it (see the experiment below). If typing reports a representation module that is not in
  the program anyway, the compile stops with `Representation module "X" must be seeded but is not in the program (needed by "Y")`
  instead of compiling against the wrong representation. A compiler with no stdlib root has no such module and could not make a
  specialized map before either (the old restart threw "has no source module"), so no working configuration changed.

With indexing on (`indexSemantics`, the editor), `SemanticAssembly` refreshes every module on purpose, so a continuation there
retypes everything as the old restart did; the command line builds with it off.

Gates: cold `app` (materia at e11c35e2f^) has six `continued` restarts (`DynamicOps`) and none else: 752.6M objects and
32.0 GB allocated against 878.9M and 36.3 GB at the start. `cnckit/tests` has exactly the two `HashMap` functions
(`haxeon.Hashing.mix`, `haxeon.collections.HashMap.insertionBucket`) more than the baseline compiler (`d78093d3`) in the same
install path and nothing less, and the program prints the same output and exits 0 ("CncKit tests passed (436 assertions)").
Before seeding it was byte-identical.

Per-pass timeline of the declaration-scan version (allocation, time): declaration pass 5.1 GB and 9.1 s, of which graph and parse is
3.9 GB and needed anyway; the one full typing pass about 11.9 GB and 17 s with publication; the continuation 2.7 GB and about 7 s,
of which typing and publication are 1.2 GB. The semantic assembly and analysis of the whole program run again in every pass
(2.1 GB, 5.2 s), because `SemanticAssembly` reuses a module's canonical contribution only when no signature or structural change
is pending and a new module always brings some.

#### Seeding experiment (2026-11-08)

Instead of discovering the runtime modules, always put them in the program. Measured with a temporary `HAXEON_SEED` root-module
hook (not committed); the modules are `HashMap`, `DynamicOps`, `Reflect`, `Std`, `FloatBits`, `Int64`, `ObservableSource` and
`ReactiveRuntime`.

Cold `app` (materia at e11c35e2f^):

| seeded | restarts | objects | bytes | output |
|---|---|---|---|---|
| nothing (the landed design) | 1 declared, 6 continued | 806.4M | 34.35 GB | 101,204,743 |
| `HashMap` | 6 continued | 752.6M | 32.0 GB | 101,204,743 |
| all eight | none | 686.1M | 29.18 GB | 101,205,143 |

The function names are identical in the three builds (35,169), so seeding produces the same program; the `.hl` hash differs
(ordering and debug data only).

What a program that does not need them pays, because seeded modules stay in the output (the backend does not drop uncalled
functions): hello world (9.2k objects, 1.5 KB) gains +59k objects and +7.5 KB with `HashMap`, +25k and +9.8 KB with `Std`,
+22k and +0.4 KB with `FloatBits`, +19k and +0.4 KB with `Int64`, +183k and +39 KB with `Reflect` (22 functions), +263k and
+49 KB with `DynamicOps` (39 functions), +956k and +123 KB with the reactive runtime (104 functions), +1.27M and +168 KB with
all. In `cnckit/tests` (23.9M objects, 3.46 MB) `HashMap` adds 2 functions and 7.5 KB, the four cheap modules 4 functions, all
eight 129 functions, 136 KB and 1.08M objects (+4.5%).

Decision: seed `HashMap` only. It costs two functions and 7.5 KB where it is not needed and removes the declaration pass (-54M
objects on `app`) and every representation restart. The called-only modules stay discovered: seeding `DynamicOps`, `Reflect` and
the reactive runtime would add +49, +39 and +123 KB to every program to save one continuation (about 66M objects) in the programs
that use them. Seeding all eight would also have let the continuation be deleted (686.1M objects, no restarts) at +168 KB per
program; rejected.

### 4. Results

Branch `typer-metadata-merge`, on top of `d78093d3` (main with the perf commits). Commits:
- `5eedb8e7` Reading the generated identity table's template again is not an edit (the warm failure, with `TypedMetadataMergeMain`).
- `9ad82bec` A module remembers the text it was loaded from, apart from the text it compiles (`ModuleState.loadedText`).
- `d72c5615` Typing keeps what unchanged code still uses of the previous program, reused metadata or not.
- `3e65a97a` Key path caches settle after the prune; name parsing sits next to the names.
- `2f6cbb4d`, then the final step 3 commit: restart reasons by kind, the continuation, and `HashMap` seeded in place of the scan.
- the key path helper lifetime (`pruneUnusedKeyPathHelpers`, exact equality in the tests).

`app` (materia at e11c35e2f^; the current `app` on main needs `haxeon.build.InputFiles` from uncommitted stdlib edits). Objects and
bytes are `compile-count` / `compile-bytes`; times are noisy (the machine was loaded):

| build | restarts | functions typed per pass | objects | bytes | compiler |
|---|---|---|---|---|---|
| cold, start of this plan | 7 reasons, 1 restart (everything typed twice) | all, all | 878.9M | 36.3 GB | 76-79 s |
| cold, now | 6 `continued`, 0 else | all, then the new module only | 752.6M | 32.0 GB | 67-94 s |
| warm, no edit (failed before) | 0 | 0 retyped | 223.3M | 11.6 GB | 29-50 s |
| warm, after editing `Main.hx` (failed before) | 0 | 33 retyped | 272.7M | 13.6 GB | 35-68 s |

Warm no-op, where the 223M objects go (`--timings` allocation phases): backend assembly 100.2M (function lowering 71.2M, verification
19.9M, debug 4.7M; the same as a cold build, 99.8M), IR assembly 98.5M (cold 168.5M; the difference is IR generation), semantic 9.9M,
typing and lowering 10.3M, graph 1.3M, ABI 2.6M, encode 25.8M. By time: IR assembly 12.3 s, backend lowering 11.8 s (lowering 6.3 s,
verify 1.8 s), output 2.5 s, frontend 1.9 s, typing 1.5 s.

Suite (`HAXEON_NATIVE_READY=1 scripts/test-driver.sh 8`): the same failure set as the untouched branch after every commit (only
`LspProtocolMain`, already failing on main), 1114 passing checks. `retainedFromPrevious` costs 354-357 ms per pass on a warm `app`.

Design decisions: the plan's "metadata merge" became carrying specialization state into every typing pass (`RetainedFromPrevious`),
because declaration metadata was cheap and not the problem; generated classes and enum helpers count only once their type is
retained; a loaded module keeps the caller's text apart from the compiled text; a representation-changing module is part of the
program instead of being discovered; restarts for called-only modules are continuations.

Open (not started):
- (i) Backend relowering on warm builds: a warm no-op `app` build still allocates 100M objects and takes about 12 s in the backend, because
  a plain build assembles from scratch (`BackendAssembly`, live patching off) and the per-function IR cache is used only under live
  patching. This is the next big item.
- (ii) Per-pass `SemanticAssembly` reuse when a module is added: each continuation redoes the assembly and analysis of the whole
  program (2.1 GB, about 5 s) because contributions are reused only when no signature or structural change is pending.
- (iii) The HashLink backend keeps uncalled functions (the Wasm backend prunes by reachability, `WasmModuleSupport`), which is why
  seeding a module costs output size. I believe the reason is live patching (the assembler gives every function a stable slot and
  id, so a patch that starts calling a function finds it already in the module); I have not verified that.
- A shared generated helper still has one recorded origin for the other helper families (`$value$equality:`, `$wire:`, `$json:`,
  enum helpers); only key path helpers are tied to their users.
- The enum helper and method reference names are still parsed, not recorded as fields.

## Baselines (main + perf commits, 2026-11-08)
- Cold `app`: ~76-79 s compiler time (noisy), 878.9M objects / 36.3 GB allocated (`compile-count`, `compile-bytes`).
- Warm second `app` build: fails (missing generic target).
- `tests/compiler/ModuleMain` fails on `main` (unset output path); ignore it.

## Measuring
- Cold build = a fresh compiler worker. A second `build` within a short time reuses the session ("reusing compiler
  session"); that is the warm case. Kill only your own worker (its command line contains your worktree path).
- Compare allocation counts, not wall time: other sessions load the machine (+-5 s).
- Byte-comparing `app` output across compiler versions is invalid (code-identity hashes embed the compiler
  fingerprint). Use `cnckit/tests` for exact byte equality, and build both versions from the same install path.
