# Lazy declaration typing (design note)

Status: proposed, no code yet (2026-11-17). Architecture plan step 2.5 (`../reports/2026-11-architecture-review.md`).
Follows 2.2 (per-unit typing output), 2.3 (inference variables) and 2.4 (error recovery, `7baff2763`). Reported by
haxeon-7b; the user rejected a fix for fields alone.

## Problem

Haxeon decides every declaration's type from syntax, before anything is typed:

- `FieldInference.resolvedType` (628 lines) guesses an unannotated field's type from its initializer's shape: literals,
  `new`, constructors, arithmetic over sibling constants, calls to annotated static methods. It fails on
  `var pending = [for (...) ...]`, `names.map(...)`, a lambda, and anything else it does not pattern-match.
  `SemanticAssembly` builds a fake view in which each class sees its module's functions as static methods, only so that
  this guesser can follow `static var x = f()`.
- `SignatureInference` (732 lines) rewrites the AST before typing. It guesses an unannotated function's return type from
  its `return` expressions, and an unannotated argument's type from call sites in the same class, from field
  assignments (`function new(x) this.x = x`), from default values and from property accessors.

Both are second, approximate typers. What they cannot type is an error, and what they type differently from the real
typer is a silent divergence. Warm builds also miss changes through them (see "Invalidation today").

The fix is Haxe's model: the type of an unannotated declaration is the type of its typed initializer or body, typed the
first time anything needs it.

## What Haxe 4.3.7 does

The mechanism is in `typeloadFields.ml` (`bind_var`, `bind_type`) and `exc_protect`. Each behaviour below was checked
with the pinned compiler (`.tools/haxe/haxe`, `-hl`, `$type`):

- **When typing is forced.** An unannotated field gets a fresh monomorph as its type, and its `cf_type` becomes
  `TLazy r`, where `r` types the initializer (`bind_var`, `exc_protect`). A method whose signature is not fully known
  (`is_full_type` false: an unannotated return or argument) gets the same treatment over its whole body. The first
  `follow` of the field's type runs `r`. At the end of typing the module, every remaining lazy type is forced, in
  declaration order. A fully annotated declaration's body is instead delayed to the `PTypeField` pass and never forced
  early.
- **Recursion.** While `r` runs, the field's type is `lazy_processing`: a read returns the provisional type, the
  unbound monomorph (for a method, `TFun(args, mono)`). There is no cycle error.
  - `static function f(n:Int) return if (n == 0) 1 else f(n - 1) * 2` types as `(n:Int) -> Int`.
  - `c() return d() + 1; d() return c();` types both as `() -> Int`: `d` reads `c`'s provisional monomorph and
    `c` fixes it.
  - `static var a = b; static var b = a;` and `g() return h(); h() return g();` leave `Unknown<0>`, which the HashLink
    generator emits as `Dynamic`. Haxe compiles them without a word.
- **Several returns.** The return type is the monomorph the first `return` binds; every later `return` must unify
  with it. There is no common supertype.
  - Int then Float: `Float should be Int`.
  - Float then Int: `Float`.
  - `return 1; return null;`: `Int` (a static target); `return null; return 1;`: `Null<Int>`.
  - `new Child()` then `new Parent()`: `Parent should be Child`.
  - `return;` then `return 1;`: `Int should be Void`. No value return at all, or only `throw`: `Void`.
- **Monomorphs left open.** An unannotated declaration's monomorph is not settled when its own initializer or body
  ends. Any later typing can bind it, in any unit:
  - `static var e = [];` followed by `e.push("x")` in `main` gives `Array<String>`. With a second function doing
    `e.push(1)`, which of the two errors depends on which is declared first.
  - `static var cache = new Map();` is fixed by `cache.set("a", 1)` in another function.
  - `static function k(x) return x;` stays `Unknown -> Unknown` until a caller binds it; `g(x) {}` called as `g("s")`
    becomes `(x:String) -> Void`.
  - What nothing ever binds is `Unknown`, emitted as `Dynamic`.
- **Overrides** do not inherit an unannotated type. The overriding body is typed and the override check runs on the
  result (`override function f() return 2` against `f():Null<Int>` fails with `Int should be Null<Int>`).
- **Accessors.** An unannotated `get_x`/`set_x` takes the property's declared type.

So Haxe's results depend on typing order: declaration order within a module, and module load order across modules.
Haxeon's must not. `--reverse-typing-order` gives identical bytes today, and must still do so.

## Semantics for Haxeon

1. **The type.** An unannotated field's type is its initializer's type. An unannotated function's return type is
   built from its returns, as in Haxe: the first value `return` fixes it, later ones must unify with it, `null` first
   gives `Null<T>`, no value return gives `Void`. An unannotated argument's type is a type variable of the function's
   unit, fixed by its default value and by the body.
2. **One unit, closed at its end.** The declaration's initializer or body is typed in its own unit, with its own
   type-variable frame (`MonomorphFrames`), like any body since 2.3. When that frame is settled (`settleFrame`), the
   declaration's type is final. No other unit ever sees one of its type variables. This is the one deliberate departure
   from Haxe, and it is what makes the result independent of order: a declaration's type is a function of its own
   source and of the types it reads, never of who reads it or when.
3. **A type left open at the end of the unit is an error, not Dynamic.** If the settled declaration type still
   contains a type variable that nothing in the unit fixed (an element of `[]`, the `T` of a lone `return null`, an
   argument the body never constrains), typing reports
   `Cannot infer the type of field "C.x": nothing in its initializer fixes <origin>; annotate it` (likewise for a
   return type or an argument). A local's unfixed variable inside the unit still becomes `Dynamic`, as 2.3 decided.
   Haxe would let a later unit fix it, which depends on order. The error keeps today's behaviour for the empty array
   field (`E1002`, "annotate it") and never accepts a program with different types than Haxe would give it.
4. **Self-recursion works as in Haxe.** A function that reads its own type while its body is being typed gets the
   provisional type: its arguments and its unbound return variable, which belong to its own frame and are settled with
   it.
5. **A cycle between units is an error.** If typing declaration A forces B and B reads A while A is in progress, B
   cannot be closed without A's open variable. Typing reports, once,
   `"A" needs its own type: its type depends on "B", which depends on it; annotate one of them`. The diagnostic is put
   on the member of the cycle that comes first in declaration order, and names the others, so it does not depend on
   which member was forced first. Every member of the cycle becomes failed (below). Haxe accepts these programs: with
   `Unknown`/`Dynamic` when nothing fixes the cycle, and with a real type when one member fixes it (`c`/`d` above). Both
   are rare, and the annotation is the fix.
6. **Override and interface checks** run on the inferred type, through the same query. An unannotated override does
   not take its parent's type.
7. **Accessors** keep Haxe's rule: an unannotated `get_x`/`set_x` takes the declared type of property `x`. This is a
   declared rule of the query, not an inference.
8. **Inline constants** keep their own path (`InlineConstantResolver`): they are already typed on demand, once, as
   shared units, with a cycle error.

What differs from Haxe, all of it a rejection of a program that Haxe accepts with order-dependent or `Dynamic` types:

| Program | Haxe 4.3.7 | Haxeon |
|---|---|---|
| `static var e = [];` fixed by a use elsewhere | the first use in typing order fixes it | error, annotate (as today) |
| `static var c = new Map();` fixed elsewhere | the first use fixes it | error, annotate (as 2.3 for locals) |
| `function f() return null;` | `Null<Unknown>` | error, annotate |
| `function g(x) {}` fixed only by callers | the first caller fixes it | error, annotate (see decisions) |
| `a = b; b = a`, or `g`/`h` returning each other | `Unknown`, emitted as `Dynamic` | cycle error |
| `c() return d() + 1; d() return c();` | both `Int` | cycle error |

Everything Haxe accepts with a type fixed inside the declaration's own initializer or body, Haxeon accepts with the same
type. Everything Haxe rejects, Haxeon rejects.

## The query

### Where it lives

One query answers "the type of this declaration", as a resolved `CompilerType`:

```haxe
interface DeclarationTypes {
	/** The field's type, in its class's own type parameters, then substituted. */
	function fieldType(owner:String, field:AstField, ?substitutions:Map<String, CompilerType>):CompilerType;
	/** The function's argument and result types, in its own and its owner's type parameters, then substituted. */
	function signature(name:String, ?substitutions:Map<String, CompilerType>):ResolvedSignature;
}
```

- The interface lives in `compiler.types`, so that `DeclarationIndex`, `TypeRelations`, `StructProperties` and
  `IterationProtocol` (which are below the typer) can call it. The implementation, `typing/DeclarationTypeTable.hx`,
  belongs to the `TypingSession` program view; `TypingSession.bindSemantic` gives `DeclarationIndex` its reference.
- An annotated declaration resolves its annotation, exactly as callers do today
  (`declarations.resolve(type, span, substitutions)`). Nothing is cached for it and nothing is typed.
- An unannotated one looks up its table entry: `Done(type)`, `Failed`, `InProgress(unit)`, or absent. Absent forces it
  (below). The entry holds the type in the declaration's own type parameters (`TTypeParameter(owner, name)`); callers
  with substitutions get it through a `CompilerType` substitution map, the same walk as `TypedTypeMap`.
- The entry is keyed by the declaration's semantic symbol id, not by a built string, so a read is one map lookup.

### Why it is deterministic

An entry's value is computed by typing the declaration's own unit against the program view, reading other declarations
only through this query. Its value therefore does not depend on which unit forced it, on the scope or type variables of
that unit, or on typing order. That holds if forcing gives the unit a clean start, which the 2.2 and 2.4 machinery
already provides:

- a new body context (`enterBody`) with an empty scope, never the forcing body's;
- a new type-variable frame, settled before the query returns;
- a new `TypingOutput` (`beginUnit`), with names generated from the unit's name and a local index (2.2);
- a checkpoint (`TypingSession.checkpoint`) taken at the current depth, so a failure returns exactly there.

### Merging the output

The forced unit's `TypingOutput` is merged at the declaration's own place in declaration order, not at its first user.
Every unannotated declaration has its own slot in `ProgramTyper`'s unit lists, so the place always exists. This differs
from the shared units of 2.2 (generic specializations, inline constants), which have no slot of their own and are merged
at their first user. Merging at the declaration's own slot follows the rule of `HELPER_OWNERSHIP.md`: an artifact's
attributes are a function of its subject, never of its uses. A warm build that retypes a different set of users then
produces the same order.

This needs one change to the unit layout. Today one class's field initializers are a single unit (`Class.__init`,
`TypingOutput`). An unannotated field must be a unit of its own, as the 2.2 decision already says ("one function body or
field initializer"). Annotated fields can stay grouped; per-field units for all fields are simpler and are the default
unless they cost measurable time.

### Typed once

The forced typing is the declaration's real typed output, kept, not thrown away and typed again:

- The table entry holds the typed result (a `TypedFunction`, or a field's typed initializer and warnings) and its unit
  output, alongside the type.
- When `ProgramTyper` reaches the declaration in its own loop (`typeClass`, `typeClassMethods`, `typeModuleFunctions`,
  `typeAbstractFunctions`), it takes the stored result and output instead of typing.
- A function body is a pure function of the program view and the unit since 2.2, so the result is the one the loop
  would have produced.

Typing twice would be simpler only in appearance. The first typing would still make lambdas, helper requests and
specializations that must then be discarded without trace, the type variables would be settled twice, and the types of
the two typings would have to be shown equal. It would also double the cost of every forced body.

Two ordering hazards follow from forcing a body earlier than its turn, and slice 4 must clear both first:

- **Native layouts.** `layoutNativeClasses` runs after the class fields are typed, and body typing reads
  `TypingSession.nativeLayoutsByName` (`ExpressionTyper`, `CallResolver`). A method body forced from a field initializer
  would run before the layouts exist. Fix: compute the layouts before any initializer is typed. They need only the field
  types of native-value records and value structs, and those fields must be annotated (their type is ABI). Make that a
  rule with its own error.
- **Deferred method bodies.** `typeDeclaredClasses` types fields with method bodies deferred. Forcing a method body from
  there is allowed, and the deferred loop finds it already typed.

Forcing nests. The depth is bounded by the length of the longest chain of unannotated declarations, each reading the
next. That is small in practice, but the HashLink stack is finite, so slice 3 adds a test that forces a chain of 200.

### Warm builds: reused declarations

In a warm build only the selected bodies are typed. When a selected unit reads an unannotated declaration that is not
selected, the query must not retype it: the table is seeded from the previous build's entries (the type only; the typed
body is reused the way it is today). The seed is valid because the declaration is unchanged and, by the invalidation rule
below, so is every type it read. `--check-reuse` retypes every seeded declaration and compares the types, naming the
declaration on a difference.

## Error recovery and the language service

- A failed declaration (its initializer or body throws a `CompileError`, or it is in a cycle) becomes `Failed`. The
  query returns `Dynamic` for it from then on, as 2.4 does for the type variables of a failed body. The declaration's
  own diagnostic is reported once, by its unit, whoever forced it. A dependent sees `Dynamic` and reports nothing
  because of it.
- This is a body-level failure, recoverable per 2.4, not a declaration-level one. 2.4's "declaration-level errors still
  abort" stays true for annotations and shapes.
- The language service gets real types for unannotated declarations. Hover and completion read the typed program and
  the table, not the AST, whose unannotated types are `_`. `SemanticIndex.recoveredType` and the `.result` reads in
  `SemanticIndex` move to the table. A failed declaration shows as `Dynamic` with its diagnostic.
- `TypingFailure` already carries the functions that did type. It also carries the table's `Done` entries, so the
  editor keeps the types of everything that typed.

## Invalidation

### Today

- A function's signature fingerprint renders an unannotated result as `_` (`SemanticSignature`). So an edit that changes
  only an unannotated body is classified as a body change, even when its inferred result changes.
- A static field's initializer edit is structural (`static:C.x`), and so is an instance initializer edit (through the
  class's wire fingerprint).
- Callers are found from signature changes only: Body edges, typed callees (`purityQueries`) and the syntactic call
  map, walked from `changedSignatures` in `SemanticAssembly`.
- `FrontendCompilation` reuses the previous `SemanticProgram` only if every selected function is explicitly typed
  (`selectedSignaturesExplicit`). Otherwise `SignatureInference` reruns over the whole program.

Two cases are missed already (read from the code, not reproduced):

1. Edit an unannotated function's body so its inferred result changes. Callers in the same module are retyped, but only
   because the whole module is. Callers in other modules keep their cached bodies, typed against the old result.
   Through `SignatureInference`'s same-class chaining, `g() return f()` changes too, with no edit to `g`.
2. `static var y = Other.x`, then edit `Other.x`. The readers of `Other.x` are invalidated. `y`'s own type changes, but
   its edge is an `Initializer` edge owned by a field, which the structural queue does not re-enqueue, so readers of
   `y` elsewhere are not.

Lazy typing makes both common: every unannotated declaration's type becomes a function of other declarations' bodies.
So invalidation must be in place before on-demand typing ships (slice 2, below).

### The dependency to record

A unit that reads an unannotated declaration's type through the query records the read: `declarationTypeReads` in
`UnitRecords`, merged like `purityQueries`. After typing, `FrontendCompilation.publishResolvedDependencies` publishes it
as a new edge kind, `SemanticDependencyKind.DeclarationType`, from the reader to the declaration, with the target's
`targetId`. Reads of annotated declarations are not recorded: their types change only with their source, and the
existing signature fingerprints cover that.

Each unannotated declaration also publishes its type's digest (`SemanticSignature` of the resolved type) in its module
state, next to the body fingerprints. The digest is the recorded answer in the sense of ADR 0003 decision 1.

### Coarse rule first (slice 2)

Before typing, the change analyzer cannot know a declaration's new type. So:

- An edit to the body or initializer of an unannotated declaration is a signature change of that declaration. Its
  signature fingerprint includes its body fingerprint.
- `SemanticAssembly`'s work queue walks `DeclarationType` edges backwards from each changed signature and invalidates
  the readers (reason `DependencySignature`, via `declaration-type`).
- An invalidated reader that is itself unannotated is put on the queue as a changed signature too, since its type may
  have changed with what it read. This makes the rule transitive and closes both missed cases.
- The `Initializer` edge is kept for what it means today (callees of an initializer). The type dependency moves to the
  new edge.

This is correct but not minimal: editing an unannotated body retypes every reader, even when its type did not change.
It is still cheaper than today, where such an edit discards the `SemanticProgram`. Once slice 5 removes
`SignatureInference`, `selectedSignaturesExplicit` goes, and the semantic program is reused across such edits.

### Early cutoff (slice 6)

The precise rule compares the new digest with the old one after typing and stops when they are equal:

- `ProgramTyper` types the selected units.
- For each unannotated declaration it retyped whose digest changed, it adds the readers recorded against it that it has
  not typed yet to the selection, and types them.
- It repeats until nothing more is added.

Every added unit is merged at its own slot, so the result is the same as a fresh build. This needs a selection that can
grow during typing and the previous build's readers per declaration, which is the query engine of ADR 0003 M4. It
belongs there, not as a second hand-written invalidation path.

### Live patching

An inferred type that changes behaves exactly as if its annotation had been edited. `PatchPlanner` compares lowered
runtime ABI, which does not know whether a type was written or inferred:

- a changed function signature patches: the old function is retired, its direct callers are recompiled (they are the
  invalidated readers), and stored closures get an adapter or a guard;
- a prototype-dispatched method whose signature changes reloads (`function_signature_changed`);
- a changed instance field type reloads (`object_field_type_changed`), and so does a changed static type
  (`GlobalLayoutChanged`).

`LIVE_PATCHING.md` gains one sentence: an edit to an unannotated body can change its declaration's type, with the
consequences of a signature change.

## Performance

The step must not slow the self-compile (about 29 s with the current GC threshold). Expected effects:

- **Removed:** the `SignatureInference` pass over the whole program on every analysis, the `FieldInference` resolution
  in `SemanticAssembly` and in each of its 15 callers, and the module-function view.
- **Unchanged:** each body is still typed once. Forcing changes when a body is typed, not how often.
- **Added:** one table lookup per read of an unannotated declaration (keyed by symbol id), the digest per unannotated
  declaration, and the read records. `src/` has roughly 1,200 unannotated class fields and 240 methods without a
  return type (a grep, not a parse).
- **Warm:** an edit to an unannotated body stops discarding the semantic program (after slice 5). Under the coarse rule
  it retypes that declaration's readers.

Gate for each slice: the self-compile time on the same machine, before and after, no slower than noise, with the
analysis and typing phase timers (`signatureTypingMs`, the body phases) in the commit message.

## Slices

Every slice is one or more commits on `main` that leave the tree green. Gates per slice: the self-hosting fixed point,
`--reverse-typing-order` byte-identical, the warm-edit sweep with `--check-reuse`, and the slice's own tests.

| Slice | Change | Behaviour | Main files |
|---|---|---|---|
| 1 | The `DeclarationTypes` query, backed by `FieldInference` and the AST that `SignatureInference` filled in. The ~15 callers of `DeclarationIndex.resolvedFieldType` and the consumers of a function's resolved argument and result types move to it; `resolvedFieldType` is deleted. | Byte-identical | new `types/DeclarationTypes.hx`, `types/typing/DeclarationTypeTable.hx`; `TypingSession`, `DeclarationIndex`, `TypeRelations`, `StructProperties`, `IterationProtocol`, `typing/{ProgramTyper, BodyTyper, CallResolver, TypeRepresentation, KeyPathTyping, DiffIntrinsics, ValueCopy, EnumRecursion}` |
| 2 | Invalidation, coarse rule: `declarationTypeReads`, the `DeclarationType` edge, type digests in module state, the analyzer and work-queue rule. Closes the two missed cases. | Warm builds only | `typing/UnitRecords`, `modules/ModuleState`, `semantic/{ModuleChangeAnalyzer, SemanticAssembly, SemanticSignature}`, `compilation/FrontendCompilation` (publish), `Invalidation`, new warm tests |
| 3 | On-demand typing of unannotated fields: per-field units, the table's states, the closing rule (semantics 3), cycle detection and its diagnostic, failed entries as `Dynamic`, typed once, merge at own slot. `SemanticAssembly` stops writing `FieldInference.resolvedType` into canonical fields; `validateSignatures` skips unannotated fields. | Accepts more fields; differential tests | `DeclarationTypeTable`, `ProgramTyper.typeClass`, `BodyTyper.typeFieldInitializer`, `TypingOutput`, `TypingSession`, `SemanticAssembly`, `DeclarationIndex` |
| 4 | On-demand typing of unannotated returns and arguments: native layouts computed before initializers; the return variable and argument variables in the function's frame; typed once in the four method loops; override and interface checks through the query; `SemanticProgram` no longer runs `SignatureInference`. | Accepts more functions; differential tests | `DeclarationTypeTable`, `BodyTyper.typeFunction`, `ProgramTyper` (method loops, `layoutNativeClasses` order, `validateInterfaceImplementation`), `CallResolver`, `DeclarationIndex.validateInheritedMethods`, `SemanticProgram` |
| 5 | Deletion: `SignatureInference`, the inference half of `FieldInference` (what stays is "the declared type, or `_`" for fingerprints), the module-function view in `SemanticAssembly`, `inferFieldBoundArguments`, `selectedSignaturesExplicit`, the language service's syntactic type fallbacks for declarations. | Byte-identical to slice 4 | `types/{FieldInference, SignatureInference}`, `semantic/{SemanticAssembly, SemanticProgram, ModuleChangeAnalyzer, SemanticDependencyCollector, ModuleAnalyzer, SemanticIndex}`, `compilation/FrontendCompilation`, `service/LanguageService` |
| 6 | Early cutoff (optional; with ADR 0003 M4). | Warm builds only | `ProgramTyper`, the M4 query engine |

Order and parallelism:

- Slice 1 comes first. Everything else reads through the query.
- Slice 2 depends on slice 1 only for the hook that records reads. Its analyzer and work-queue half (`semantic/`,
  `modules/`) touches no file of slice 1 and can be written in parallel. It must land before slice 3, because the
  missed cases exist today and slice 3 multiplies them.
- Slices 3 and 4 both change `DeclarationTypeTable` and `ProgramTyper`, so they run in order. Moving native layouts
  ahead of initializers (the first commit of slice 4) can be done in parallel with slice 3.
- Slice 5 follows slice 4. Slice 6 waits for M4.
- Step 2.3's remaining cases (`BodyTyper.inferBodyLocalTypes`, object-literal structures) are independent of this
  step, except that both touch `BodyTyper`.

Slice 4 needs a census before the argument rule ships: build `src/`, `packages/` and the test programs with a
diagnostic that lists every argument whose type only call-site constraints fixed (`SignatureInference`'s
`collectCallConstraints`). Each one is annotated in the same slice, or the decision on arguments (below) changes.

## Tests

Differential fixtures against Haxe 4.3.7 (`tests/differential/`, identical `.official.hx` and `.realtime.hx`; runtime
output and exit status compared):

- `lazy-field-comprehension`: `static var pending = [for (i in 0...3) i * 2];` and an instance field.
- `lazy-field-map-lambda`: `static var upper = names.map(s -> s.toUpperCase());` and a field holding a lambda.
- `lazy-field-order`: `w = v + 1` declared before `v = 1 + Std.int(2.5)`, across two classes and two modules.
- `lazy-field-call`: a field typed from an unannotated static method and from a module-level function.
- `lazy-generic-field`: `var items = new Array<T>();` in a generic class, used through two instantiations.
- `lazy-return-several`: Float then Int returns, `return null` then a value (`Null<Int>`), value then `null` (`Int`),
  no value return, a body that only throws.
- `lazy-return-recursive`: self-recursion fixed by a base case.
- `lazy-return-object`: a returned object literal and a returned lambda, then used through field access and calls.
- `lazy-argument-body`: `function new(x) this.x = x;`, `f(x) return x + 1`, a default value.
- `lazy-accessor`: unannotated `get_x`/`set_x` for a typed property.

Compile-error fixtures where both compilers must reject (`type-error` pattern): Int then Float returns
(`Float should be Int`), `return;` then a value, `new Child()` then `new Parent()`, a mixed array field, an unannotated
override whose type does not match.

Haxeon-only error tests (Haxe accepts; the message and its position are checked), each listed in
`LANGUAGE_SUPPORT.md`: a field cycle, a return cycle, the `c`/`d` cycle that Haxe types as `Int`, `static var e = [];`,
`static var m = new Map();`, `function f() return null;`, an argument only call sites fix. Also, the cycle diagnostic is
the same with `--reverse-typing-order`.

Recovery tests: a failed unannotated field and a failed unannotated function, each read by two other bodies. One
diagnostic each, the readers type against `Dynamic` and add none, and the language service shows the readers' other
types.

Order tests: every fixture above, and the self-compile, built with `--reverse-typing-order`, byte-identical. A forced
chain of 200 declarations.

Warm-edit cases (`tests/compiler`, warm against fresh bytes, with `--check-reuse`):

- an unannotated function's body changes its result type, read from another module (missed case 1);
- the same edit when the result type stays the same (correct output; under slice 2, the reader is retyped anyway);
- `static var y = Other.x` with `Other.x`'s initializer changing type, and a reader of `y` in a third module (missed
  case 2);
- `static var x = f()` where `f`'s body changes its result;
- an edit that creates a cycle, then one that removes it;
- an edit that breaks an unannotated declaration, then one that fixes it (the recovered state, then the clean one);
- annotating a previously unannotated declaration with the same type: no reader retyped after slice 6;
- live: an inferred result change patches with callers recompiled; an inferred static field type change reloads with
  `GlobalLayoutChanged`; an inferred instance field type change reloads with `object_field_type_changed`.

## Decisions for the user

1. **An open type at the end of a declaration's unit** (`[]`, `new Map()`, a lone `return null`, an unconstrained
   argument). Proposed: an error asking for an annotation. The alternative is `Dynamic`, which Haxe gives only when no
   later use fixes it, so it would silently give some programs `Dynamic` where Haxe gives a real type.
2. **Arguments fixed only by call sites.** `SignatureInference` infers them today from callers in the same class; that is
   a Haxeon rule, order-free, standing in for Haxe's "the first caller fixes it". Proposed: drop it with the rest of
   `SignatureInference`, after the slice 4 census, and annotate what the census finds. The alternative is to keep it as a
   declared rule of the query, which keeps a piece of syntactic inference alive.
3. **Cycles.** The brief assumed Haxe fails on a cycle. It does not: it types the cycle as `Unknown` (`Dynamic`), or as a
   real type when one member fixes it. Proposed: a cycle across units is an error anyway, since accepting it needs
   either `Dynamic` or the members of the cycle typed as one unit. Typing a cycle as one unit (a strongly connected
   component) is possible but costs complexity for a rare case.
