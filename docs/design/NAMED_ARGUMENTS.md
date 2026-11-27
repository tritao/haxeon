# Named arguments, default values and memberwise initializers

Status: named arguments implemented (2026-11-27); the memberwise initializer and `with` are next. Recorded in
[LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md) and [LANGUAGE_SUPPORT.md](../reference/LANGUAGE_SUPPORT.md); the idea first
appeared as item 10 of [FUTURE_LANGUAGE.md](FUTURE_LANGUAGE.md), and this is the part that lands as a Haxeon extension.

## What it adds

1. **Named arguments.** A call may name its arguments: `f(width: 10, height: 20)`.
2. **Defaults for skipped parameters.** A parameter skipped before a named one takes its default, typed in the callee's
   declaration scope as an omitted trailing one is.
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

- **Order.** Named arguments follow the positional ones and name parameters in the order they are declared, as in
  Swift. A call reads like its declaration, and binding never reorders, so arguments are evaluated in the order written
  without temporaries. Any order (C#, Kotlin) was considered and left out for that reason.
- **Skipping.** A parameter skipped before a named one must be optional and takes its default; for an overridden method,
  the default of the method that runs. Trailing parameters are omitted as without names.
- **Errors.** An unknown name, a name given twice or out of order, a name also given positionally, a positional argument
  after a named one, a skipped required parameter, a named rest parameter, or a named argument to a function value (which
  has no parameter names) is a compile error naming the parameter.
- **Names are API.** A parameter's name is part of its function's signature: renaming it is a visible change, and
  incremental compilation treats it as one for callers that name it.
- **Synthesis.** The memberwise initializer and `with` are synthesized only when the struct declares no constructor or
  `with` of its own. `final` fields are parameters of the initializer and of `with` alike, since `with` builds a new
  value rather than writing one. Fields without an initializer are required in the initializer.
- **Haxe compatibility.** Every call Haxe accepts keeps its meaning, including skipping optional arguments by type;
  named arguments are only new syntax. Removing skip-by-type is a separate decision for the language after Haxe.

## Syntax

`f(key: "x")`, as in Swift, C# and Dart. `f(key = "x")` is already valid Haxe (an assignment to a local named `key`).
An identifier then a colon starts nothing else in an argument list: Haxe's type check `(expr : Type)` has its own
parentheses, a ternary's colon follows its `?`, and an object literal starts with a brace.

## Implementation

The parser makes `NamedArgument(name, value)`; `NamedArguments.bind` puts each at its parameter's position and a
`DefaultArgument` in the place of each skipped one, before rest packing, in the three paths that type a declared callee's
arguments (declared calls, generic calls and constructors) and for enum constructors. A skipped parameter's default is
typed where an omitted trailing one is, after inference for a generic call. A named argument that reaches ordinary
expression typing belongs to a call with no parameter names, which is the function-value error.

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

`tests/programs/named-arguments.hx` covers functions, methods and overrides, interface calls, static extensions,
constructors, generic functions and constructors, enum constructors and evaluation order; `NamedArgumentsMain` covers
every error cold and incrementally and a parameter rename reaching a caller that names it. The initializer and `with` will
add structs with nested struct, nullable and array fields.
