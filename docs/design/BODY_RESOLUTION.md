# Resolve a body once, type it, then decide storage

Status (revised 2026-11-19: closure conversion becomes one stage after typing): step 1's check mode is in (`--check-resolution`); step 2 in progress (assigned declarations, map privacy, loops and lambdas read the resolution). Order changed: step 2 before the typer reads the resolver, since step 2 is where the time is and the check mode already holds the two resolvers equal. Replaces `BODY_BINDINGS.md` (a cheaper second resolver). Stage 2 of `INTEGER_IDENTITIES.md`
(function-local names as numbers) and, for storage, ADR 0003's layering (representation decisions after typing).

## Problem

A function body's names are resolved more than once. The typer resolves locals through its `Scope` (`resolve`,
`requireId`: about 160 calls across the typer). Before that, a family of `BindingWalker` analyses walks the raw syntax and
resolves the same names again, each on its own: about 6% of a cold self-compile. Two resolvers must agree on every scoping
rule; `09c62266e` showed what happens when they do not (a pattern binding the storage walk and the typer resolved
differently, and a closure read the wrong value).

The analyses run before typing for different reasons:

| Analysis | What it is for | Needs look-ahead |
|---|---|---|
| `LexicalStorageAnalysis` (2 walks per body, 2 more per lambda; now `StorageRequirements`) | which locals live in cells | no: representation |
| — its closure writes | flow facts of locals a closure may write are dropped at calls | to be checked (Open questions) |
| `AssignedDeclarations` (per body, lambda and loop) | narrowing of never-reassigned locals; loop entry | yes |
| `MapEscapeAnalysis` | map entry facts survive calls for private maps | yes |
| `FreeVariables` (per lambda) | the lambda's captures | no |
| `ScopedEscapeChecker` | a diagnostic | no |

`Scope` itself does five jobs: it resolves local names, and it holds flow facts (already keyed by binding id), definite
assignment, captures and cells, and map privacy. The typed AST encodes the storage decision in eight cell node kinds
(`TCellLocal`, `TCellCaptured`, `TCellAssign`, `TCellCapturedAssign`, `TPostfixCellLocal`, `TPostfixCellCaptured`,
`TCellIncrement`, `TCellCapturedIncrement`), made in six typer files and read by `IrGenerator` and `SemanticIndex`.

## Decision

Three layers, each with one job.

1. **Resolution.** One resolver per body, the only implementation of the scoping rules (blocks, shadowing, loops, catches,
   patterns, lambdas, local functions, comprehensions). It numbers the body's declarations from 0 and maps every
   reference to the declaration it names, or to none. The typer reads a local's binding from it instead of looking the
   name up in `Scope`; `Scope` keeps the facts about bindings (types, flow facts, assignment), keyed by binding id. The
   resolver is a per-body query once the typer is on the engine (`QUERY_ENGINE.md`, step 3).
2. **Typing facts.** The facts typing needs before it reaches the code that decides them (assigned declarations, private
   maps, and closure writes if they need look-ahead) are computed from the resolution in one pass over its references, not
   by walking the syntax. Loops and lambdas read their part by span. What typing finds itself (a lambda's captures and
   writes) it records as it types.
3. **Closure conversion after typing.** Cells, closure environments and lifted lambdas are representation. Today
   `ClosureConversion` collects them while typing, from decisions the typer makes along the way (`ClosureTyper`'s capture
   sources, the storage plan), and hands IR generation a finished plan (`TypedClosurePlan`). Instead, the typer emits plain
   locals and captures, and each typed lambda its captures by binding id with whether it writes them; one closure-conversion
   stage per typed function, after typing and before IR generation, decides the cells, builds the environments and lifts
   the lambdas, producing the plan IR generation reads today. Closure conversion then has one owner and one layer; generic
   elaboration of cell types stays where it is. Moving it further, into the IR, would mean rebuilding lambda lifting over IR
   for little more than a purer layering, so it is not planned. Locals kept in a cell only because they are written in a
   `try` and read after it follow HashLink's trap semantics, so they move to HashLink lowering if the Wasm backends do not
   need them.

`BindingWalker` becomes the resolver; `LexicalStorageAnalysis`, `FreeVariables`, the walks of `MapEscapeAnalysis` and
`AssignedDeclarations`, the storage paths of the typer and the eight cell node kinds go.

## Rules

- **One answer, checked.** Before the typer reads the resolver for a kind of local, a check mode compares the resolver's
  binding with `Scope`'s at every reference on the self-compile and the test suites; a difference fails the build.
- **Scoping edge cases against Haxe first**, as differential fixtures: shadowing in sibling blocks, a name declared after a
  lambda that reads the outer one, loop variables captured by closures, catches, pattern bindings in guards and in several
  patterns of one case, local functions calling themselves, a closure made in a loop and called on a later iteration.
- **Byte-identical** through step 4; step 5 may change the IR and is checked by the compiler reaching the same bytes when it
  compiles itself, the capture fixtures, and the program and Wasm suites.

## Steps

1. **Resolver.** `BindingWalker` produces the resolution (declarations and references); the typer reads a reference's
   binding from it, behind the check mode, kind by kind (parameters and locals, then patterns, catches, loop variables,
   comprehensions, captures); `Scope`'s name lookup for locals goes when every kind agrees.
2. **Typing facts** from the resolution: assigned declarations and private maps in one pass; a lambda's captures and
   writes recorded by `ClosureTyper`. The walks of `AssignedDeclarations`, `MapEscapeAnalysis` and `FreeVariables` go.
3. **Captures on typed lambdas.** `ClosureTyper` records each lambda's captures by binding id with whether it writes them;
   compared with the storage pre-pass under the check mode. The typer still emits cells.
4. **The closure-conversion stage.** From the typed function and its lambdas' captures it decides the cells (captured and
   written; value bindings written through a field; local functions that refer to themselves; written in a `try` and read
   after it), rewrites locals and captures to their cell forms, builds the environments and lifts the lambdas, with
   today's names and order. Checked first against the plan the typer makes (check mode), then in its place. Byte-identical.
   Then the typer stops deciding storage: `BindingStoragePlan`, `LexicalStorageAnalysis`, the cell metadata of `Scope`,
   `ClosureTyper`'s capture-source decisions and E1013 (a written capture without a cell, which cannot happen once every
   write is known) go.
5. **Exception-edge cells in HashLink lowering**, if the Wasm backends do not need them.

Measured at each step; the target is the walker time, about 6%, down to the one resolution walk.

## What the typer rewrites

The typer builds syntax of its own while it types: held iterables and `match` temporaries (`ExpressionTyper`,
`CallResolver`), the old value of a postfix update, intrinsic expansions (`DiffIntrinsics`), and the rewrites of extractor
and structure patterns into nested switches. A resolution made before typing has no entry for it. So:

- the resolver resolves the syntax as the typer receives it (after canonicalization and `AbstractConstructorNormalizer`);
- the typer finds a reference's binding by the reference's position and name;
- a local the typer itself introduces stays in `Scope`: its name is generated and unique, and it is used only inside the
  syntax that introduced it, so no scoping rule is implemented twice;
- the pattern rewrites carry the user's bindings over with their names and spans; the check mode shows whether every one
  still finds its binding, and a rewrite that does not moves before resolution.

## Open questions

- **Closure writes and look-ahead.** A call can only run a closure made before it, so recording a lambda's writes when
  it is typed is sound in straight-line code. A closure made late in a loop body can run from a call early in the next
  iteration; `LoopFlow` drops at the loop head what the loop body assigns, lambdas included, which may already cover it.
  Step 2's check mode answers whether a look-ahead is still needed.
- **Narrowing and cells.** `BodyTyper` excludes some captured cells from narrowing (`TCellCaptured` with a
  closure-written name). After step 3 it decides from the recorded closure writes, not the node form.
- **Binding id text.** The typer's ids (`$l<N>:name`) and the walkers' keys (`name@offset`) both exist and reach the
  output (local and cell names). The resolver's ids are numbers; their text stays as today's until a step chooses to
  change the output.

## One binding model (2026-11-19)

The end state: names are resolved once (the resolution), every local is an integer binding id, and `Scope` keeps only
flow state per binding (narrowed type, assignment, map key sources), with no name lookup. What stands in the way is the
syntax the typer builds while typing and types by name. Inventory (self-compile and all programs under
`--check-resolution`, references the resolution has not seen, all of them locals):

| Family | Built by | References | Needs types |
|---|---|---:|---|
| `$diff:*` temporaries | `DiffIntrinsics` (field-by-field diff and patch) | 1,533 | yes |
| `__haxeon_incremented` | `ExpressionTyper.arithmetic` (increment of a place that is not a local) | 108 | yes |
| `__haxeon_array*` | `ExpressionTyper.typeIndex`, `StatementTyper` (an element's array evaluated once) | about 100 | yes |
| source locals of a `scoped var` | its cleanup, at generated positions | about 70 | yes (`Disposable`) |
| source locals of `for (k => v in a)` | key-value iteration and comprehensions | about 45 | yes (array or map) |
| `$downcast` | `CallResolver.typeExpressionValue`, `ExpressionTyper.typeCast` | 42 | yes |
| `$compound:receiver` | `AssignmentTarget` (a compound assignment's receiver) | 18 | to check |
| local function default arguments | the lambda's prologue | 12 | argument types |
| `__haxeon_bound*`, `__haxeon_argument*`, `__haxeon_match`, pattern temporaries | `CallResolver`, `ExtractorPatterns`, `StructurePatterns` | a few | yes |

Nearly all of it needs types, so a lowering before resolution would take almost nothing. And two families refer to
source locals from generated syntax, not only to temporaries. So the way is synthetic references: syntax the typer
builds refers to a binding by id (a temporary's, allocated from the body's resolution, or a source local's), never by
name. About 100 construction sites in 12 files (`CallResolver`, `BodyTyper`, `DiffIntrinsics`, `ExpressionTyper`,
`StatementTyper`, the pattern typers and a few more); generated functions (`EnumEqualityGenerator`,
`WireCodecGenerator` and the like) are typed through `typeFunction` and resolved like source, so they need nothing.
Then the typer reads every local by id and `Scope`'s name chain goes (with the check mode), and Haxe's same-block
redeclaration becomes a change to the resolver alone. Speed is not the reason: name lookups are about 1.2% of a
self-compile.

Pilot (`DiffIntrinsics`, the largest family): a temporary is a `TemporaryLocal` object, declared, assigned and read with
`TemporaryDeclaration`, `TemporaryAssignment` and `TemporaryVariable`, so syntax the typer builds no longer names it.
Until the typer reads locals by binding, it types these as the named forms under the temporary's name, and the walker
treats them the same way; the switches over syntax take them beside their named forms. Byte-identical: the self-compile,
and the six programs that use the diff intrinsics compiled before and after.

The other temporary families followed: the held array of key-value iteration and comprehensions, the increment of a
place, compound assignment receivers (`AssignmentTarget`, which the parser uses too), the subjects of `.match`,
`Std.downcast` and the pattern rewrites, and the bound value of an extension or enum function value. A holder that is
already a temporary is used as it is, as a local name was. Every program compiles to the same bytes before and after
(638). Left: the parameters of lambdas the typer builds (`__haxeon_argument*`, which needs a temporary parameter), the
extractor's `part` (a binding in pattern position), and the two families that refer to source locals.

Generated syntax that reads or writes a source local names its declaration: `DeclaredVariable` and `DeclaredAssignment`
carry the local's name and declaration offset, its key in the resolution. They are used by the cleanup of a `scoped var`,
the index of key-value loops and comprehensions, and the default-argument prologue (a lambda's is built after its body was
resolved). Typed and walked as the named forms until the typer reads locals by binding. Byte-identical on all 638
programs and the self-compile.

Step 4.1 is done. Field initializers are typed with the resolution of their expression (`BodyResolution.ofExpression`).
The extractor's `part` is a temporary, bound in pattern position (`switchSubjectBinding`, enum payloads, array payload
elements and `bindPattern` take `TemporaryVariable`), and the parameters of the lambdas the typer builds are temporaries
(`AstArgument.local`). Logged over the self-compile and all programs: no plain reference the resolution has not seen,
and none typed without a resolution. Making an unseen reference an error waits for step 4.2, since the temporary and
declared forms are still typed through their names until then. Byte-identical on all 638 programs and the self-compile.

## Step 4: the typer reads locals by binding

**Today.** `Scope` finds a local by walking its chain of scopes by name (`resolveLocal`), and then reads its state:
binding id (`$l<n>:<name>`, which the typed AST and IR carry), declared type, flow facts and assignment by binding id,
captures, map key sources. Only the name lookup is what this step replaces; the state is already keyed by binding.

**Every typing context has a resolution.** Function bodies have one. Field initializers do not (106 references on the
self-compile and the programs, all `__init.<field>` and lambdas in them): they get the resolution of the initializer
expression. Syntax the typer builds names nothing by itself except the parameters of the lambdas it builds
(`__haxeon_argument*`), the extractor's `part`, and locals it defines in a scope directly (`EnumReflection`, bound
values): these become `TemporaryLocal`s first. After that, a reference the resolution has not seen is an internal error.

**A binding table per context.** `TypingContext` maps each binding it defines to its `Scope` record (made a class,
`LocalBinding`): source locals by declaration key, temporaries by object, the receiver on its own. `Scope.define` takes
the key or the temporary and enters it. A lambda's context enters each capture under the captured declaration's key. A
name lookup is then one map access, with no walk; what the binding is in a given scope (its refined type, whether it is
assigned) is read from the scope chain by binding id, as now.

**References.** `Variable(name, span)`: the resolution's declaration at `span` (null: not a local, so a field, a
static or a type). `TemporaryVariable`: the temporary's binding. `DeclaredVariable`: the binding of its key. Writes,
increments and captures the same way. The free names of a lambda (`lambdaFacts`) are given as declaration keys.

**Names stay where they are names:** diagnostics, binding ids (unchanged, so the output is byte-identical; integer ids
are the separate stage 3 of `INTEGER_IDENTITIES.md`), and enumerations of what is visible (`visibleValues`, for flow
invalidation and purity).

**Order, each byte-identical** (all programs compiled before and after, the self-compile, the compiler suite):

1. Resolutions for field initializers; the remaining typer-made names become temporaries; an unseen reference is an
   error under `--check-resolution`.
2. Binding tables and `Scope` methods taking a binding, beside the name ones. The typer's reference sites move to
   bindings, kind by kind: reads, writes and increments, captures, pattern, catch and loop bindings, the receiver.
   `--check-resolution` compares the binding found with the one the name finds.
3. The name lookups go: `resolveLocal`, `ScopeDefinitions.named`, `declarationOf(name)` and the check mode.
4. Haxe's same-block redeclaration: `Scope`'s duplicate check (E1001) goes; the resolver's scoping decides
   (`local-redeclared-same-block` becomes a case that agrees with Haxe).

## Progress

- `BodyResolution` records a body's declarations and references; `--check-resolution` compares it with the typer's
  scope at every local the typer resolves (`BodyTyper.typeVariableExpression`). On the self-compile the two agree on all
  147,602 references compared; 38 are not compared, nearly all the typer's own `__haxeon_match` temporaries. All 637
  programs agree.
- The check also covers writes and increments (`StatementTyper.checkWritten`); calls of locals and member calls reach
  `typeVariableExpression`. The differential fixture `local-scoping` (sibling and nested blocks, a lambda reading an outer
  name a later declaration shadows, loop variables captured per iteration, a closure made in one iteration and run in the
  next, catches, local recursion, pattern bindings in guards, comprehension variables) agrees with Haxe and passes the
  check. It found a divergence from Haxe outside this work: a second `var x` in the same block is `E1001` in Haxeon
  (`local-redeclared-same-block`, `LANGUAGE_SUPPORT.md`).
- The check found one disagreement: a key-path constant a lambda reads was declared in the lambda's scope with a new
  identity (`path@<lambda>`) instead of its declaration's; `ClosureTyper` now keeps the declaration, as for any capture.
- Step 2: `BodyTyper.typeFunction` resolves each body once (`BodyResolution`) and reads assigned declarations
  (`AssignedDeclarations.fromResolution`) and map privacy (`MapEscapeAnalysis.fromResolution`) from it; loop entry reads a
  loop's writes by its span (`writesInLoop`), and a lambda's free variables and writes by its span (`lambdaFacts`, plus
  the default-argument prologue, which the typer builds). Under `--check-resolution` each answer is compared with the walk
  it replaces. The self-compile and all 637 programs agree; main-thread instructions -0.8%, cycles about -1%, output
  byte-identical. The record allocates 33 MB more than the walks it replaces; compacting it is next.
- The record is compact (references in four arrays, kind and flags packed with the lambda depth; declarations have no
  reference entries): allocation back to within 3 MB of before the resolution.
- Storage requirements (`StorageRequirements`) are read from the resolution: which locals need a cell and which a closure
  can write, for a body or one lambda, its own declarations only. The resolution records what this needs beyond names:
  place writes (a field assignment's object, a method call's receiver, an increment's target, a `set` key whose receiver
  may be a key path), local functions, and per reference whether it is captured or in a deeper `try` of its own function.
  The walker's `try` depth counts per lambda. `LexicalStorageAnalysis` and its four walks per body (two, and two per
  lambda) are gone. Compared under `--check-resolution` before the deletion: the self-compile, all 638 programs and the
  capture, closure and `try` tests agree. Main-thread instructions -1.9%, allocation -73 MB, output byte-identical.
- The typed AST has no cell node kinds. A local or capture is `TLocal`/`TCaptured`; writes to a capture have their own
  forms (`TCapturedAssign`, `TCapturedIncrement`, `TPostfixCaptured`), and `TIncrement` carries its value type. Which
  locals and captures are cells is data on the function (`TypedFunction.cells`, `cellCaptures`), and IR generation reads
  and writes through the cell where it says so. A captured write without a cell is an internal error in IR generation;
  the typer still reports it (E1013). Output byte-identical; all 638 programs, the compiler suite and the capture
  fixtures pass.
- Step 3 as planned (a typed lambda's captures with whether it writes them) is not needed: the cell decision is made from
  the resolution's facts and the binding's type when the binding is declared (`BindingStoragePlan`), not from what typing
  finds. What remains of the closure-conversion stage is moving that decision, the environments and lambda lifting out
  of the typer; it changes where code lives, not what it does.
- `ScopedEscapeChecker` walks a body only when its resolution records a scoped binding (`declaresScoped`), lambdas
  included: nothing else can escape. Main-thread instructions -1.0%. The walkers left are cheaper than porting them:
  `PurityInference` (about 1.1%, spread thin, judging calls and fields rather than names) and the resolution itself
  (about 1%, built once per distinct body; generic specializations add under 2%).
