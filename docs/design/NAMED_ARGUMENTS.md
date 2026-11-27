# Named arguments, default values and memberwise initializers

Status: decided direction (2026-11-27), not implemented. The call syntax needs a parser check before implementation
(see [Open question](#open-question)). Recorded in [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md); the idea first appeared as
item 10 of [FUTURE_LANGUAGE.md](FUTURE_LANGUAGE.md), and this is the part that lands as a Haxeon extension.

## What it adds

1. **Named arguments.** A call may name its arguments: `f(width: 10, height: 20)`.
2. **Default values that are expressions.** `style:LayoutStyle = defaultStyle()`, evaluated at the call site when the
   argument is omitted, where Haxe allows only constants.
3. **A memberwise initializer for structs.** A struct without a constructor of its own gets one whose parameters are
   its fields in declaration order, each defaulting to the field's initializer:
   `new Rect(x: 0, y: 0, width: 10, height: 10)`.
4. **`with` for structs.** A synthesized method whose parameters are the struct's fields, all optional, returning a
   copy with the named fields replaced: `props.with(enabled: false)`.

Items 3 and 4 are synthesis on top of items 1 and 2, not separate mechanisms: one rule for naming and defaulting
arguments covers construction and copying.

## Why

- **Long argument lists are not only a struct problem.** `SelectionPopup` takes sixteen positional arguments, eight of
  them floats; a rewrite of its test passed two extra values in the wrong position and only the argument count caught
  it. Constructors of widgets, factories such as `BuildContext.styled` and any function with several options of one
  type are read and written by position today.
- **Component inputs become structs.** The UI's components keep their inputs in an `Equatable` struct copied into an
  immutable description ([UI architecture notes](../../packages/ui/docs/ARCHITECTURE_NOTES.md#component-model-end-state)).
  A struct with forty fields needs construction by name and adjustment by copy to be usable; this is that.
- **One explicit mechanism, no type-directed conversion.** Constructing a struct from an anonymous object literal (Haxe's
  `@:structInit` style, `var p:Props = {key: "x"}`) depends on the expected type, fails without one, and sits next to
  the unresolved width-subtyping question for anonymous structures ([STRUCTURE_VALUES.md](STRUCTURE_VALUES.md)).
  Haxeon avoids implicit conversions elsewhere (`Flags`, raw-value enums), and a named call says what it builds.
- **No new kind of type.** C#'s reference `record` gives classes value equality; Haxeon keeps class equality as
  identity and value equality on structs ([STRUCTS.md](STRUCTS.md)). A struct with `Equatable` already has what C#'s
  `record struct` means (value semantics, synthesized equality and hash); this adds what its syntax gives: named
  construction and `with`.

## Rules

- **Order.** Named arguments may follow positional ones, never precede them. Among named arguments any order is
  accepted.
- **Evaluation.** Arguments are evaluated left to right as written, then bound to their parameters; omitted ones then
  take their defaults, in parameter order.
- **Errors.** An unknown name, a name given twice, a name also given positionally, or a missing required parameter is a
  compile error naming the parameter.
- **Defaults.** Any expression the declaration's scope can type. It may refer to earlier parameters. It is evaluated on
  each call that omits the argument.
- **Names are API.** A parameter's name is part of its function's signature: renaming it is a visible change, and
  incremental compilation treats it as one for callers that name it.
- **Synthesis.** The memberwise initializer and `with` are synthesized only when the struct declares no constructor or
  `with` of its own. `final` fields are parameters of the initializer and of `with` alike, since `with` builds a new
  value rather than writing one. Fields without an initializer are required in the initializer.
- **Haxe compatibility.** Every call Haxe accepts keeps its meaning, including skipping optional arguments by type;
  named arguments are only new syntax. Removing skip-by-type is a separate decision for the language after Haxe.

## Open question

The call syntax. `f(key = "x")` is already valid Haxe (an assignment to a local named `key`), so it is out.
`f(key: "x")`, as in Swift, C# and Dart, is the intended form; check that it cannot be confused with Haxe's type check
`(expr : Type)` inside an argument list before implementing it.

## Consumers

- UI components' inputs structs and their callers (`new TextFieldProps(key: "name", placeholder: "Name")`,
  `props.with(enabled: false)`).
- Long positional constructors and factories in the UI kits (`SelectionPopup`, `Button`, `BuildContext.styled`).

## Not done

- Struct construction from anonymous object literals.
- Reference records (classes with value equality).
- Deconstruction.
- Compile-time body purity; the UI keeps the runtime checks, as [PURITY.md](PURITY.md) decides.

## Checks

Focused programs on HashLink, Wasm32 and Wasm GC: named and positional mixes, evaluation order with side effects,
expression defaults referring to earlier parameters, every error case, the synthesized initializer and `with` on
structs with nested struct, nullable and array fields, and incremental recompilation after a parameter rename.
