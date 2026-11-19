# Switch cases with several patterns

Status: step 1 done; steps 2 to 4 open.

## Problem

`case A, B, C: body` is one case with three patterns in Haxe: the body is typed once, and when the patterns bind
variables, each must bind the same names with the same types. Haxeon's parser splits it into three cases that point at the
same statements, and every later stage works per value:

- the canonicalizer canonicalizes the body once per value;
- the typer types it once per value, so it cannot check that the patterns agree on their bindings, and a diagnostic in
  the body could be reported once per value;
- the IR lowers it once per value, so the code is emitted once per value.

About 4% of the compiler's own lines are in such bodies (1,329 of 11,944 cases have several values). Commit `2e9ad93e5`
shares the work for statement switches whose patterns bind nothing, by recognizing values that point at the same
statements. That recovers, by identity, a grouping the parser had and dropped; it does not reach switch expressions,
which would need the same trick on spans, or cases whose patterns bind, which are common in the compiler's IR passes
(`case Call(_, name, _), StaticClosure(_, name):`).

## Decision

A case carries its patterns, as Haxe's does, from the parser to the IR.

1. **Syntax.** `AstSwitchCase` and `AstSwitchExpressionCase` have `patterns:Array<AstExpression>` in place of `value`.
   The parser keeps a case's comma-separated patterns and the alternatives of `A | B` together in one case.
2. **Typed AST.** `TypedSwitchArm` stays the match of one pattern (value, constructor, predicates, array pattern,
   subject binding, bindings) without the guard. A typed case is `{patterns:Array<TypedSwitchArm>, guard, statements}`
   (statement switch) or `{patterns, guard, result}` (switch expression). Readers that look at every pattern
   (exhaustiveness, null coverage, duplicate cases) iterate the patterns of every case.
3. **Typing.** The typer types each pattern, then the guard and the body once in the case's scope. The first pattern
   declares the case's bindings; every other pattern must bind the same names with types that unify, and its bindings
   are given the first pattern's binding ids, so one body reads them whichever pattern matched. A pattern that binds a
   name another does not, or with another type, fails as in Haxe ("Variable x must appear exactly once in each
   sub-pattern").
4. **IR.** Each pattern lowers to its own test and binding stores, which continue into the case's one guard and body.
   An integer or enum jump table points each entry at the match block of the first pattern that takes it; a pattern's
   failed predicates continue at the next pattern that can take the same value, then at the next case.
5. **Removed:** the identity-based sharing of `2e9ad93e5` in `StatementTyper`, `ModuleCanonicalizer` and `IrGenerator`.

## Scope

The rename of `value` to `patterns` reaches about 65 sites in 16 files (parser, canonicalizer, dependency and lambda
collectors, purity, binding walker, extractor and structure pattern rewrites, the typers); the typed case reaches about
56 sites in 10 files (typers, control flow, `SemanticIndex`, `TypedTypeMap`, `IrGenerator`). Plain Haxe throughout, so
the stock-built compiler is unaffected. The formatter and the language server read neither.

## Steps

1. Syntax: `patterns` on both AST cases; the parser stops splitting; every reader iterates patterns where it read
   `value`. The typer still splits a case into one typed case per pattern, so output is byte-identical.
2. Typed AST and typing: typed cases with patterns, one guard and one body; the bindings rule. Output changes (bodies
   emitted once); checked by the self-compile reaching the same bytes when it compiles itself, and the switch, pattern,
   guard and flow tests.
3. IR: one body per case; remove the `2e9ad93e5` sharing.
4. Tests for the bindings rule, against Haxe's diagnostics (`tests/differential`).
