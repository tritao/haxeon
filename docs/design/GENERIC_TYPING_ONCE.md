# Typing generic code once (design note)

Status: stage 1 in progress (2026-11-18); stage 2 is a proposed plan entry. This is the TODO.md follow-up "generic code
is typed twice". It belongs with step 2.5 ([LAZY_DECLARATION_TYPING.md](LAZY_DECLARATION_TYPING.md)) and step 2.6
([STRUCTURE_VALUES.md](STRUCTURE_VALUES.md)).

## Problem

A generic body is typed more than once, and only one of those typings becomes code. Today's paths:

| # | Path | What is typed | Kept |
|---|---|---|---|
| 1 | `ProgramTyper.checkAbstractMember` | every abstract instance member and constructor, with its own parameters, in a check unit (`TypingSession.beginCheckUnit`) | no |
| 2 | `ProgramTyper.checkGeneric` | every generic function, and every generic method of a class or abstract, with its own parameters, in a check unit | no |
| 3 | `ProgramTyper.signatureOnly` (from `typeInferredFunction`) | an unannotated generic body, an abstract's instance member, or one a warm build does not type again, for the table's signature, in a dropped unit | no |
| 4 | `ProgramTyper.genericFieldType` | an unannotated field of a generic class, typed again with the class's own parameters when the erased type "mentions Dynamic" (`mentionsDynamic`) | no |
| 5 | `TypingSession.typeSharedUnit(checkOnly)` | a callee's specialization at the caller's type parameters, met while 1 to 3 run (`forParameters`) | no |
| 6 | `GenericInstantiation.specialize` → `typeSharedUnit` | each specialization of a generic function or abstract member: the AST typed again with the representation's substitutions | code |
| 7 | `ProgramTyper.typeClassMethods` and `fieldInitializer` | a generic class's methods and initializers, typed with its parameters erased to `Dynamic` | code |
| 8 | `ProgramTyper.typeClass(specialization)` | a generic owner's specialization (`GenericOwnerRepresentation`), typed again for its arguments | code |

Code (6 to 8) is produced by typing the AST again for each representation. Paths 1 to 5 exist to get what code typing
cannot give: diagnostics in the code's own parameters, and the declaration's type in them. Path 4 guesses when it is
needed. That guess is the heuristic behind `60f3e8afd`.

## Measured

Exclusive typing time and allocations per path, measured with a local probe (not committed) around each path. Times are
from one idle 16-core machine.

| Build | Typing | Paths 1 to 5 | Allocations, paths 1 to 5 |
|---|---|---|---|
| self-compile (805 files) | 8.2 s | about 15 ms (55 check units, 23 parameter specializations) | 0.15 M of 49 M |
| UI showcase, `ShowcaseDesktop`, hl | 3.0 to 3.2 s | 510 to 615 ms (3,815 check units, nearly all path 1) | 3.0 M of 18.9 M |

The compiler itself uses few generics, so the cost of repeated typing shows on generic-heavy code: about 18% of the
showcase's typing.

## Is a specialization a substitution of the typed body?

Haxe types each body once and makes `@:generic` copies by substituting types in the typed expression (`generic.ml`).
To see whether Haxeon could do the same, the probe typed each code body (paths 6 and 7) a second time with its own
parameters, mapped that typing through `TypedTypeMap` with the representation's substitutions, and compared the two
structurally. Over the showcase and the 678 `tests/programs`:

| Code | Equal | Differ |
|---|---|---|
| non-generic abstract members and functions (path 6, empty substitutions) | 533 | 0 |
| generic class field initializers, erased (path 7) | 71 | 0 |
| generic class methods, erased (path 7) | 791 | about 330 |
| generic specializations (path 6) | about 213 | about 190 |

Where they differ, the typer has made a decision that depends on the representation:

- boundaries: `TToDynamic`, `TAbiCast` and `TCast` where a `T` meets `Dynamic` or a concrete type;
- value copies: `TCopy` of a struct `T`;
- layout constants: `sizeof<T>()` (16 against 0), `$rawptr.load.flat` against `$rawptr.load`;
- helper choice: `Std.string` against `__std_string`, the equality and hash helpers of a value type;
- nested generic calls: the callee's specialization is named, and its policy chosen (`[shape]` against `[layout]` for
  a type parameter), from the caller's substitutions;
- lambda names, which hash their types.

So a specialization is not a type substitution of the typed body in Haxeon. It is the body *elaborated* for a
representation, and today the body typer does both jobs at once.

## Model

1. **One semantic typing per body.** Every function body and field initializer is typed exactly once, with its own and
   its owner's type parameters as themselves. That typing is the declaration's unit. It gives the declaration's type
   (the `DeclarationTypeTable` answer), all of the body's diagnostics, and the source of its code.
2. **Elaboration per representation, after typing.** The representation decisions listed above move out of body typing
   into a pass that takes the typed body and a representation substitution and produces that representation's code:
   boundaries and copies inserted where a substituted type needs them, layout constants folded, helpers chosen, nested
   generic calls re-requested with substituted arguments, lambdas renamed. Specialization and erasure are both this
   pass. `GenericSpecializationPolicy`'s decisions are unchanged: they choose the substitution, and the pass applies it.
3. **No check units and no dropped units.** Paths 1 to 5 disappear: the semantic typing *is* the check and the
   signature. `mentionsDynamic` and `genericFieldType` go, because a generic field's type is always its own-parameter
   typing's.

Point 2 is the substantial change. The boundary, copy and helper nodes are what `IrGenerator` and the HashLink and Wasm
lowering consume today. Moving their insertion after typing changes the typer→IR boundary, and it meets the erased-owner
work of step 2.6 (`GenericOwnerErasure`, `IrExactTypeFacts`, HashLink lowering). So the model is reached in two stages.

## Stage 1: typer only, byte-identical

Where the representation is the declaration's own, the semantic typing and the code typing are the same typing, as the
experiment shows (533 of 533). Stage 1 removes those repetitions and the heuristic, without moving any elaboration.


- **1a. Members typed once.** A body whose representation substitution is its own (a non-generic abstract member or
  constructor, a non-generic function, specialized with no iteration or key-path argument) is typed once, as its one
  specialization's shared unit. The check (path 1) requests that specialization without recording a use. A call reuses
  it and records its use, and the unit is merged at its first user, as shared units are. A unit nothing uses is never
  merged, as a check unit is dropped today. Diagnostics are the unit's, reported once.
- **1b. No heuristic for generic fields.** An unannotated field of a generic class is always typed with the class's own
  parameters, and that typing is its type (the table's answer) and its diagnostics. `mentionsDynamic` is deleted. The
  erased typing stays the initializer's code until stage 2. A `TypedTypeMap` substitution matched all 71 initializers
  measured, but an initializer with a lambda over `T`, a boundary to `Dynamic` or a string conversion of `T` elaborates
  differently, so substitution waits for the elaboration pass. The two typings must agree once the parameters are
  erased, and no structure in the type may mention one. Otherwise the field needs an annotation (`E1002`), as now.
- **1c.** Unannotated generic bodies (path 3) and generic checks (path 2) share one own-parameter unit, which the table
  keeps for the signature. It is still separate from the code typing until stage 2.

Warm builds: a shared unit is keyed by its specialization name and typed from the current declarations, as now. 1a
changes who types a unit first, not what it contains. 1b adds a dropped unit and changes no code. `--check-reuse`,
`--reverse-typing-order` and the slice 2 invalidation rules (`DeclarationType` edges, per-field units) are unchanged.

What stage 1 leaves typed twice, until stage 2: a generic body's own-parameter typing (paths 2, 3 and 1b's field units)
next to its code typings (paths 6 to 8), and the specializations at type parameters (path 5) met inside them.

## Stage 2: elaboration as a pass (proposed plan entry)

Not started. This stage crosses into erased-generic lowering (`GenericOwnerErasure`, `IrExactTypeFacts`, the HashLink
lowering), so it is sequenced with step 2.6 and its owner. The proposed steps are:

1. The typer stops emitting `TToDynamic`, `TAbiCast` and `TCopy` for a type parameter. It records the semantic
   conversion (`T` to `Dynamic`, `T` to its bound), and the elaboration pass inserts the physical node per
   representation.
2. Layout constants and raw-pointer forms for a type parameter become typed nodes the pass folds.
3. Helper choice (string conversion, equality, hashing) for a type parameter is made by the pass.
4. Nested generic calls keep their semantic substitutions, and the pass requests the callee's specialization with the
   substituted arguments. Lambda names stop hashing physical types.
5. Specialization (path 6), erasure (path 7) and owner specialization (path 8) become the pass. Then every check unit,
   `typeSharedUnit(checkOnly)` and `TypingOutput.checkOnly` are deleted.

Each item is gated on byte-identical programs and self-compile output, as stage 1 is.
