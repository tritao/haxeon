# Typing generic code once (design note)

Status: stage 1 landed (2026-11-18); stage 2 approved by the user on 2026-11-18 (plan step 2.7), items 1 to 3 in
progress. This is the TODO.md follow-up "generic code
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

### As built (stage 1)

- 1a: `ProgramTyper.checkAbstractMember` types a member of a non-generic abstract through
  `GenericInstantiation.typeMemberBody`, which requests the specialization exactly as `specialize` names it and types it
  with `TypingSession.typeSharedUnit(unused)`: into an output of its own, merged only where a call records its use.
  Whichever of the check and the first call comes first types it, and the other reuses it. A generic abstract's members
  are still checked in a check unit.
- 1b: `ProgramTyper.ownParameterFieldType` types every unannotated field of a generic class with its own parameters. An
  error there is the field's error, reported as Haxe reports it: `var r = { var f = (x:T) -> Std.int(x); 0; }` was
  accepted, since its erased type `Int` mentions no `Dynamic`, and is now rejected
  (`tests/differential/generic-field-own-parameters-error`). `mentionsDynamic` is deleted.
- 1c is not done. A generic body's own-parameter typing (paths 2 and 3) already happens once per body: the check of an
  unannotated generic body reads its signature from the table, which types it once.
- Output is byte-identical for the test programs that build (669), the self-compile and the UI showcase. Before stage 1
  (`4d119532e`) and after it, with the same sources: the typing phase allocates 49.047 M objects instead of 49.031 M on
  the self-compile, and 18.79 M instead of 18.63 M (-0.9%, 653 MB instead of 650 MB) on the showcase. Typing time, the
  median of three interleaved runs on a machine with a load of about 8: self-compile 8.55 s against 8.20 s, showcase
  3.28 s against 3.16 s. Both differences are within noise. The showcase gains less than the 18% that paths 1 to 5 cost,
  because most of its 3,815 abstract members are never called. For those, the check unit was the only typing, and
  still is.

## Stage 2: elaboration as a pass

Approved by the user on 2026-11-18. This stage crosses into erased-generic lowering (`GenericOwnerErasure`,
`IrExactTypeFacts`, the HashLink lowering), so it is sequenced with step 2.6 and its owner, haxeon-e4. The steps are:

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

### Contract with the IR lane

haxeon-e4 reviewed this stage. Its conditions are the contract:

1. **Placement and output.** The pass runs on the typed AST, before `IrGenerator`. Its output for a representation is
   exactly today's typed code (the output of paths 6, 7 and 8), so `IrGenerator`, `GenericOwnerErasure`,
   `IrExactTypeFacts` and the HashLink and Wasm lowering see the same input. The equivalence ("elaborated at the erased
   representation equals path 7's typing", and likewise for each specialization) is a permanent test, not a local
   probe.
2. **Boundaries keep their source type.** Every boundary the pass inserts carries its semantic source type (`T`, its
   substitution, the bound), as a field on the node or in a side table, not only the physical `TToDynamic` or
   `TAbiCast`. `GenericOwnerErasure`'s fast path (a `Box<Int>` read through `Box<Dynamic>`), exact-type facts at erased
   boundaries and 2.6 slice 8 use it.
3. **One naming function.** Owner and specialization names (`$generic-erased:Owner:get|set|call:member`,
   `GenericOwnerErasure.isOperation` and `DISPATCH_PREFIX`) come from one function both lanes share. A change to it is
   agreed with haxeon-e4 first.
4. **Structured lambda names.** A lambda is named by its owner, member, index and representation, not by a hash of
   types, to fit `IrSymbol` ([IR_SYMBOLS.md](IR_SYMBOLS.md)) and ADR 0003 M3. This is decided with haxeon-e4 before
   item 4 lands, so names change once.
5. **Order.** Items 1 to 3 now, in parallel with haxeon-e4's slice 2a (`IrType.Structure`). Items 4 and 5 start only
   after the naming (3) and the boundary contract (2) are agreed.

Points 3 and 4, as haxeon-e4 proposed them (2026-11-18), are the contract for items 4 and 5:

- **Naming.** One module, `compiler.semantic.GeneratedNames`, shared by the typer, the elaboration pass and the IR, owns
  every generated generic name and its predicate: `specialization(base, policy, arguments)` (today's
  `$generic:Owner.method[layout]<…>`), `erasedOperation(owner, operation, member)` and `erasedDispatch(...)` (today's
  `$generic-erased:Owner:get|set|call:member` and `$generic-erased-dispatch:`), and `isSpecialization`,
  `isErasedOperation` and the like, which replace the `startsWith(name, "$generic:")` checks in `IrOptionalFieldStorage`,
  `IrValueArrayPlaceMethods`, `IrGenerator`, `WasmFlattenValueFields`, `SemanticAssembly` and `SemanticIndex`. Its first
  step is a pure move: the same text, byte-identical, with IR call targets through `IrSymbol.of`. ADR 0003 M3 later
  replaces the text by a structured identity behind the same functions.
- **Lambda names** stay a content hash, because live patching aligns functions by name (`LambdaAlignment`,
  `PositionalName`), but the hash covers the semantic types (the own parameters, unsubstituted), not the physical ones:
  `$lambda:<owner>.<member>#<index>@<semantic hash>` for the own-parameter body, and `[<representation key>]` after it for
  an elaborated body, the key being the argument part of `GeneratedNames.specialization`. Before the switch, check what
  `LambdaAlignment` and the patch planner match on. The change renames lambdas once for live sessions.

Items 1 to 3 are typer-local: the typer records the semantic decision and the pass produces today's nodes from it, so
output stays byte-identical. They go to the service lane.

### As built (stage 2, first piece)

- **The pass.** `GenericElaboration` (a `TypedTypeMap`) replaces the owner's type parameters by a representation's
  substitutions and makes each recorded decision for the substituted types. It runs inside `BodyTyper.typeFunction`, in
  the body's context before it is left, so a helper or adapter the decision asks for is named and requested as typing
  the body again would. It also elaborates the closures the body made and its cell types.
- **The test.** `--elaborate-generics` (`CompileOptions.elaborateGenerics`) makes a generic class's erased methods
  (path 7) from their own-parameter typing passed through the pass. The test driver builds every program with and without
  it in the warm-edit builds (`--check-reuse`) and requires the same bytes; `elaborationKnownDifferences` in
  `tests/driver/TestRunner.hx` names each program that still differs and the item that fixes it. A name there that no
  longer differs fails. `tests/compiler/GenericElaborationMain.hx` checks the bytes and the boundary's source type across
  warm rebuilds. Paths 6 and 8 are not under the option yet.
- **Item 1, boundaries.** Where either side mentions a type parameter, `ConversionResolver.coerce` and
  `TypeRepresentation.boundaryCast` return `TParameterConversion(value, Coerce | Boundary)` instead of a physical node (a
  null literal made a nullable's null excepted). The pass makes the conversion with the same function at the substituted
  types, and sets `TypedExpression.parameterSource` (the unsubstituted source and target, and the substitutions) on the
  node it makes. Analyses that looked through `TCast`/`TAbiCast` also look through it. `IrGenerator` throws if one
  reaches it.
- **Item 3, first helpers.** `Equality.equals`, `Equality.sameForChange` and `Hashing.keyEquals` on a type parameter's
  value, and `Array.indexOf`, `contains` and `remove` on an array of one, are `TParameterOperation`s the pass resolves
  (`CallResolver.equalityCall`, `CallResolver.arraySearch`).
- **`Null<T>` is a `T`**, as Haxe unifies them (`TypeRelations`). Own-parameter typing rejected `return values.shift()`
  in a method returning `T`, which the erased typing and Haxe accept.
- Without the option, programs, the self-compile and the UI showcase on HashLink, Wasm32 and Wasm GC are byte-identical
  to the previous commit's. With it, 666 of the 670 test programs that build are identical. The rest wait for item 4: a
  lambda's name hashes its types (`structural-iteration`), and a nested generic call in a body typed with its own
  parameters names a specialization at those parameters (`haxeon.reactive.Derived`, which also keeps the UI showcase
  from building with the option).
- Typing, against the previous commit on the same sources: the self-compile allocates 50.12 M objects instead of
  49.83 M (+0.6%, the conversions recorded in check units), the UI showcase 18.625 M instead of 18.624 M. Typing time is
  within noise on a loaded machine (self-compile 4.5 to 5.2 s, showcase 1.8 to 2.2 s, both builds).
- Left: item 2 (layout constants and raw-pointer forms) and the rest of item 3 (string conversion, hashing) show only in
  specializations, so they come with putting paths 6 and 8 under the option.
