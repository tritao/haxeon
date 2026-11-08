# Typed metadata merge: warm rebuilds and the cold-build frontend restart

Status: steps 1 and 2 done, step 3 (restart continuation) next (2026-11-08). Branch `typer-metadata-merge`.

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

### 3. Make the frontend restart a continuation
Rebuild the experiment cleanly (no traces): the dependency check after publication in `FrontendCompilation.run`,
empty change sets for pass 2, carried `regenerated`/`retyped` sets, and a continuation flag for
`SemanticAssembly.run` so pass 2 does not invalidate every function for `source-revision`.
Extend `FrontendRestartMain` (or add a test) to check that the restart no longer retypes unchanged functions.
Gate: cold `app` build succeeds and `compile-count` (objects allocated, deterministic) drops clearly below the step-2
number; output equivalence on `cnckit/tests` (byte-identical .hl, see Measuring).

### 4. Results
Record before/after for cold `app` and warm `app` (compiler ms, `compile-count`, `compile-bytes`, functions typed in
pass 2) in this file, plus anything left undone.

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
