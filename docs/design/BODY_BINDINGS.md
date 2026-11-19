# Body bindings: resolve a function body's names once

Status: proposed 2026-11-19. Stage 2 of `INTEGER_IDENTITIES.md` (function-local names as numbers), done where the
profile says.

## Problem

The analyses that look at a function body before typing extend `BindingWalker`, which walks the body and resolves each
name to the declaration it refers to (`name@offset`) by scanning a stack of visible bindings. Each analysis walks the body
again and resolves every name again. On a cold self-compile (2026-11-19) the walkers take about 6% of the time:

| Entry | Share | Walks |
|---|---:|---|
| `BodyTyper.typeFunction` (`LexicalStorageAnalysis.analyze`) | 2.8% | two per body, again per lambda |
| `SemanticAssembly.run`, `TypingSession.bodyStores` (`PurityInference`) | 1.2% | per body, twice |
| `MapEscapeAnalysis.analyze` | 0.6% | per body |
| `Parser.parseFunctionDeclaration` | 0.55% | per body |
| `LoopFlow.enter` (`AssignedDeclarations`) | 0.4% | per loop, over its body |

`resolve` and its string comparisons are 1.3% on their own; the rest is the walking.

## Decision

1. **One resolution per body.** `BodyBindings.of(function)` walks a body once and records, in source order:
   - its declarations, numbered densely from 0 (`Int` ids), with name, span, kind, type and initializer;
   - every reference to a name: a read, a write, a call, a member call, a collection receiver, with the declaration id
     it resolves to (or none), its span, and the lambda and `try` depth it is at.
   The record is cached with the function's syntax for as long as the syntax lives, so the parser's check, semantic
   assembly and typing share it.
2. **Analyses that only use the hooks replay the record** instead of walking: `FreeVariables`, `FinalLocalChecker`,
   `MapEscapeAnalysis`, `AssignedDeclarations` (a loop's body is the references within its span). A replay is a loop over
   an array.
3. **Analyses that inspect constructs keep their walk but stop resolving:** `LexicalStorageAnalysis`,
   `ReceiverMutationInference`, `ClosureEffects`, `ScopedEscapeChecker`, `MutableIterationAliases`, `GenericEnumUsage`
   and `PurityInference` read a reference's declaration from the record by its position instead of scanning the binding
   stack. Where an analysis needs only hooks plus a little context (the lambda or `try` depth), it moves to replay.
4. **Declarations are numbers inside the analyses.** Sets and maps of declarations become arrays or bit sets indexed by
   id. The `name@offset` text stays where it leaves the analyses: the typer's scope (`Scope.define`), cell names, and
   diagnostics. `BodyBindings` gives the text of an id.

## Rules

- **Same answers.** The record resolves exactly as `BindingWalker` does today (shadowing, patterns, lambdas, loops,
  catches, comprehensions); the walker becomes the record's builder. Every step is byte-identical on the self-compile.
- **Scoping edge cases are tested against Haxe**, not only by the self-compile (`self-compile-oracle-blind-spots`):
  shadowing in sibling blocks, a name declared after a lambda that reads the outer one, a pattern binding in a guard,
  `for` loop variables captured by closures, catches. Small programs in `tests/differential`.

## Steps

1. `BodyBindings` built by today's walker, and `FreeVariables`, `FinalLocalChecker`, `MapEscapeAnalysis` and
   `AssignedDeclarations` replaying it. Measured.
2. The walking analyses read declarations from the record; `resolve` leaves them.
3. Declaration ids inside the analyses: arrays and bit sets for their sets of declarations.
4. Share the record across the parser, semantic assembly and typing (cache lifetime with the syntax).
