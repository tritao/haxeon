# Tokens as a table

Status: proposed, design only (`COMPILER_DATA_LAYOUT.md`, front end).

## Problem

`Lexer.tokenize` returns an `Array<Token>`: each token is an object (kind, text, span) and its `SourceSpan` another, made
for every identifier, operator and literal, about 3% of all the bytes the compiler allocates compiling itself and the
largest single site left in the front end. Most tokens never outlive the parse: punctuation, keywords and operators only
steer the parser, and an identifier's span is copied into the node that uses it. The parser reaches tokens through a few
accessors (`current`, `advance`, `previous`, `peekKind`, `check`), but `Token` objects also travel into the formatter's
token checks, the language service's recovered parses, the linter and the semantic index.

## Proposal

1. **One table per file.** `TokenTable` holds parallel columns indexed by token number: `kind` (the `TokenKind` index),
   `start` and `end` (byte offsets), and `text` only where the text is not implied by the kind (identifiers, interned as
   today, and literals). The lexer appends rows; nothing is allocated for an operator or keyword token.
2. **Spans on demand.** `table.span(index)` makes a `SourceSpan` for the parser when it builds a node; a node's span is made
   once, as today, and tokens the AST does not keep get none.
3. **The parser reads by index.** Its accessors return token numbers (`current():Int`) and the parser asks the table for
   kind, text and span. The rewinds of speculative parsing are a position, as they are now.
4. **Consumers that want objects get a view.** The formatter, language service, linter and semantic index read the same
   table; where one needs a token value to keep, `table.token(index)` makes the `Token` it uses today, so they can move
   one at a time.
5. **Both builds.** The table is plain arrays in both, so it needs no dual declaration. A token may become a struct row only
   under the amended ADR 0006, and only if measuring shows it pays.

## Migration

Each step leaves the compiler's output byte-identical:

1. `TokenTable` and a lexer that fills it, with `toTokens()` making today's array; `Lexer.tokenize` returns
   `toTokens()`, and a check compares the two on every parse in the test driver.
2. The parser moves to the table behind its accessors. Spans come from `table.span`, and `toTokens()` is no longer made for
   the compiler's own parse.
3. The other consumers move to the table or to `table.token(index)`; `Lexer.tokenize` and `Token` remain only where a
   caller keeps tokens.
4. `TypeArguments.splitAssignments` and the `>=` splitting in the parser become row edits in the table instead of new
   arrays of tokens.

## Checks

Allocated bytes, main-thread instructions and peak memory on the frozen input at each step; the self-compile
byte-identical; the formatter's token preservation check and the language service tests when their step lands.
