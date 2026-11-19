# Resolve a body once, type it, then decide storage

Status: step 1 in progress: the check mode is in (`--check-resolution`); the typer does not read the resolver yet. Replaces `BODY_BINDINGS.md` (a cheaper second resolver). Stage 2 of `INTEGER_IDENTITIES.md`
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
| `LexicalStorageAnalysis` (2 walks per body, 2 more per lambda) | which locals live in cells | no: representation |
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
3. **Storage in the IR.** Cells, closure environments and cell classes are representation: a closure-conversion pass over
   the IR decides them, where every local is a value and every capture is explicit. The typed AST then has no cell nodes.

`BindingWalker` becomes the resolver; `LexicalStorageAnalysis`, `FreeVariables`, the walks of `MapEscapeAnalysis` and
`AssignedDeclarations`, the storage paths of the typer and the eight cell node kinds go.

## Rules

- **One answer, checked.** Before the typer reads the resolver for a kind of local, a check mode compares the resolver's
  binding with `Scope`'s at every reference on the self-compile and the test suites; a difference fails the build.
- **Scoping edge cases against Haxe first**, as differential fixtures: shadowing in sibling blocks, a name declared after a
  lambda that reads the outer one, loop variables captured by closures, catches, pattern bindings in guards and in several
  patterns of one case, local functions calling themselves, a closure made in a loop and called on a later iteration.
- **Byte-identical** through step 3; step 4 changes the IR and is checked by the compiler reaching the same bytes when it
  compiles itself, and by the program and Wasm suites.

## Steps

1. **Resolver.** `BindingWalker` produces the resolution (declarations and references); the typer reads a reference's
   binding from it, behind the check mode, kind by kind (parameters and locals, then patterns, catches, loop variables,
   comprehensions, captures); `Scope`'s name lookup for locals goes when every kind agrees.
2. **Typing facts** from the resolution: assigned declarations and private maps in one pass; a lambda's captures and
   writes recorded by `ClosureTyper`. The walks of `AssignedDeclarations`, `MapEscapeAnalysis` and `FreeVariables` go.
3. **Storage after typing**, as a pass over the typed body that produces today's typed AST (cells by binding id).
   `LexicalStorageAnalysis` and the typer's storage paths go. Byte-identical.
4. **Storage in the IR**: the pass becomes closure conversion over the IR, and the typed cell nodes go.

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

## Progress

- `BodyResolution` records a body's declarations and references; `--check-resolution` compares it with the typer's
  scope at every local the typer resolves (`BodyTyper.typeVariableExpression`). On the self-compile the two agree on all
  147,602 references compared; 38 are not compared, nearly all the typer's own `__haxeon_match` temporaries. All 637
  programs agree.
- The check found one disagreement: a key-path constant a lambda reads was declared in the lambda's scope with a new
  identity (`path@<lambda>`) instead of its declaration's; `ClosureTyper` now keeps the declaration, as for any capture.
