# Typed metadata merge: warm rebuilds and the cold-build frontend restart

Status: planned (2026-11-08). Branch `typer-metadata-merge`.

## Problem

Two symptoms with one root cause.

1. **Warm rebuild fails.** Build `materia/app` (`haxeon build --project haxeon.json --compiler-only`), then build it
   again while the first compiler worker is still alive ("reusing compiler session"). The second build fails on `main`:
   `Missing target for generic method reference ... haxeon.platform.async.Promise:cancel`
   (thrown in `src/compiler/ir/GenericOwnerErasure.hx`).
2. **A cold build types the program twice.** Typing discovers runtime helper modules late (`haxeon.DynamicOps`,
   `HashMap`, `Reflect`), and `FrontendCompilation.run` restarts the whole front end
   (`includeTypedRuntimeDependencies(...)` then `return run(...)`). On a cold `app` build the second pass repeats
   semantic analysis (~3.2 s) and typing (~11.9 s), about 19% of an ~80 s build.

**Root cause (found 2026-11-08, not yet fixed).** When `ProgramTyper.typeProgramMeasured` gets `cachedMetadata`, it
takes enums, interfaces and classes wholesale from the previous typed program (`cachedMetadata.enums`,
`cachedMetadata.interfaces`, `refreshCachedClasses(...)`, lines ~155-219). It cannot accept declarations from modules
that were added since, and generic specializations created by the previous program's functions (retained owners,
`currentSpecializedOwners` in `FrontendCompilation`, around line 223 and the prune at line ~438) are dropped. The prune
step then retires specialized methods that are still referenced, so erasure cannot find
`$generic:$owner:haxeon.platform.async.Promise[layout]<Array<String>>.cancel`.

An earlier experiment (`/home/joao/dev/materia-cache/claude-scratch/restart-continuation-experiment.patch`, against an older base, with debug traces) made the restart a continuation:
publish pass 1's results, then run pass 2 as a normal incremental compile with empty change sets. Pass 2 then
selected 10,366 of 33,609 functions instead of all of them, but failed with the same missing-target error. So fixing
the metadata merge fixes the warm rebuild and unblocks the restart win.

## Steps

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
