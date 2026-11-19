# Local storage decided after typing

Status: proposed 2026-11-19. Replaces the plan of `BODY_BINDINGS.md` (a cheaper second resolver) with fewer resolvers.

## Problem

A function body's names are resolved twice. The typer resolves every name through its `Scope`, giving each local a binding
id. Before it does, a family of `BindingWalker` analyses walks the raw syntax and resolves the same names again, each on its
own: about 6% of a cold self-compile (`BODY_BINDINGS.md`, Problem). Two resolvers must agree on every scoping rule;
`09c62266e` showed what happens when they do not (a pattern binding that the storage walk and the typer resolved
differently).

The analyses run before typing for two different reasons:

| Analysis | What typing does with it | Needs look-ahead |
|---|---|---|
| `LexicalStorageAnalysis` (2 walks per body, 2 more per lambda) | decides which locals live in cells: captured and written, written in a `try` and read after it, value bindings written through a field | no: it is representation |
| — its closure writes | invalidates flow facts of locals a closure may write, at calls (`closureWritableNames`) | partly (see Open questions) |
| `AssignedDeclarations` (per body, per lambda, per loop) | narrowing of never-reassigned locals; loop entry invalidation | yes: a later write undoes an earlier fact |
| `MapEscapeAnalysis` | map entry facts survive calls for private maps | yes: a later escape undoes them |
| `FreeVariables` (per lambda) | the lambda's captures | no: typing the lambda finds them |
| `ScopedEscapeChecker` | a diagnostic | no |

The typed AST encodes the storage decision: `TCellLocal`, `TCellCaptured`, `TCellAssign`, `TCellCapturedAssign`,
`TPostfixCellLocal`, `TPostfixCellCaptured`, `TCellIncrement`, `TCellCapturedIncrement`, the cell maps and
`CellStorageKind`, made by `BodyTyper`, `StatementTyper`, `ExpressionTyper`, `ClosureTyper`, `KeyPathOperations` and
`ValuePlaceRules`, and consumed by `IrGenerator` and `SemanticIndex`.

## Decision

1. **Storage is decided after typing.** The typer types locals and captures as plain (`TLocal`, `TCaptured`, `TAssign`,
   ...). A storage pass over the typed body, where every local is a binding id and every capture is explicit, finds the
   locals that need a cell (captured and written, written in a `try` and read after its catch, value bindings written
   through a field), rewrites their nodes to the cell forms, adds the cell fields to the closure environments and makes
   the cell classes. Its output is the typed AST of today, so IR generation and the semantic index do not change.
2. **What typing finds, typing records.** A lambda's free variables and the locals it writes are what typing its body
   resolves; `ClosureTyper` records them instead of walking the lambda first.
3. **One look-ahead pass.** The facts typing needs before it reaches the code that decides them (assigned declarations,
   private maps, and closure writes if they need look-ahead) come from one walk per body, not one per analysis. Loops and
   lambdas read their part of it by span instead of walking again.
4. **Checks after typing.** `ScopedEscapeChecker` runs on the typed body.

`LexicalStorageAnalysis`, `FreeVariables` and the storage paths in the typer go; `BindingWalker` remains only as the
builder of the look-ahead pass.

## Rules

- Each step is byte-identical on the self-compile: the storage pass must produce the typed AST the typer produces today.
- Before a step replaces an analysis, a check mode compares the new answer with the old one on the self-compile and the
  test suites, and a difference fails the build.
- Scoping edge cases (shadowing, sibling blocks, loop variables captured by closures, catches, pattern bindings, local
  functions calling themselves, closures created in a loop and called on a later iteration) get differential fixtures
  against Haxe first.

## Steps

1. `ClosureTyper` records each lambda's captures and writes as it types it; compared with `FreeVariables` and the closure
   writes of `LexicalStorageAnalysis` in check mode.
2. The look-ahead facts from one walk per body (`AssignedDeclarations`, `MapEscapeAnalysis`, closure writes if needed);
   loops and lambdas read it by span.
3. The storage pass after typing; the typer stops emitting cell forms; `LexicalStorageAnalysis` goes.
4. `ScopedEscapeChecker` on the typed body.

Each step is measured; the target is the walker time, about 6%, down to one walk per body.

## Open questions

- **Closure writes and look-ahead.** A call can only run a closure made before it, so recording a lambda's writes when it
  is typed is sound in straight-line code. A closure made late in a loop body can run from a call early in the next
  iteration; `LoopFlow` invalidates what the loop body assigns at its head, lambdas included, which may already cover it.
  Step 1's check mode answers whether the pre-pass is still needed for these.
- **Narrowing and cells.** `BodyTyper` excludes some captured cells from narrowing (`TCellCaptured` with a closure-written
  name). After step 3 it decides that from the recorded closure writes, not the node form; the check mode covers it.
