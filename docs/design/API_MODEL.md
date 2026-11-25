Status: Implemented: the model, its JSON, `haxeon doc`, the website's package reference, editor hover and signature
help, and the deletion of `--xml`.

# Haxeon API model

The API model describes the public types, members and module-level functions and variables of a successfully typed
program. It is what Haxeon's package reference is generated from, and what editor hover and signature help will read, so
that the editor and the published reference never disagree. Its serialized form is a Haxeon-owned JSON format with a
version and the schema below. Haxe's type-description XML (`--xml`, the input of dox) is not a goal: it is built from the
syntax tree, so it spells types as written in each module rather than qualified, and loses optional arguments; it is
deleted.

## Built from the semantic program

The model is built by an analysis, not a build: `--api-json` takes `--no-output`, so the sources are typed and nothing is
generated. The modules it describes are the roots of that analysis, so the model covers all of them rather than what an
entry reaches, and `--entry` is optional: a library has none. They are the modules loaded from the source roots given with
`--api-source` (every module but the standard library's without it). What a package keeps to itself is written
`internal`, and described with that visibility (below). The roots belong to the one analysis, so a compile
server's later builds are unchanged. The model also holds every declaration the described ones refer to, from
dependencies and the standard library included, and lists the described modules (`described`), so a reader can tell the
API from what it uses.

`haxeon doc` runs this analysis for a project with the arguments its build uses, describing the root package's source
roots, and writes `build/api.json` (or `--output`). The model is read from the semantic program
the analysis keeps, not from the syntax tree, which cannot give resolved types, caller-visible nullability or inferred
signatures.

- `SemanticProgram.program` gives the canonical declarations (names already qualified), their members, visibility, spans,
  metadata, accessor policies, argument names, optional markers and default expressions. The module table maps each
  declaration's source to its module, which can differ from its qualified type path.
- `SemanticProgram.signaturesByOwner` and `signatures` give the checked signatures, including inferred types, and
  `DeclarationIndex` resolves types in their generic scope.
- `DocumentationTools.scan` and `forSpan` attach the same comments the editor reads; the model separates prose from the
  recognized tags.

A type is given as written where the source writes one, and as checked where it is inferred:

- A typedef keeps its name. `options:Options` is a reference to `sample.Options`, not that typedef's fields, and so is a
  typedef inside another type (`Pair<Int, Options>`, `Array<Settings>`). A typedef naming another keeps the first name; the
  typedef's own declaration carries what it stands for (`underlying`). The declaration index decides what a name is, with
  the typer's scope: a name is a typedef's when the index has a typedef of that name and no type parameter in scope takes it.
- Haxe's structural iteration types (`Iterator`, `Iterable`, `KeyValueIterator`, `KeyValueIterable`) keep their names
  rather than their method structure.
- Everything else, and everything inferred, is the type the typer resolved.

An optional argument's checked type is `Null<T>`; the model gives the type as declared, `T`, beside `optional: true`, as the
source says `?x:T`. A type written `Null<T>` stays `Null<T>`.

Private declarations and private members are not in the model. A public signature can still name a private type (a private
typedef of a native handle, for one): it stays a `named` reference to that type's path, which consumers show without a
link. A language-level conversion or operator is usable even when its implementation method is private, so it gets its own
member under the operation's name. Compiler-generated interface accessors and storage classes are not members. Abstract
statics appear under their abstract, and a module's variables, which Haxeon stores as statics of a hidden class
(`ModuleFields`), appear under their module.

## JSON version 1

All names are case-sensitive. A record's fields are written in the order listed, and a member's or type's fields only as its
kind has them (`ApiJsonWriter` writes them field by field, so the output is this schema).

| Record | Fields |
| --- | --- |
| Root | `version` (integer, `1`), `described` (the module paths described), `modules`, `types` |
| Module | `path`, `package`, `file` (its source), `members` (its public top-level variables and functions) |
| Declaration | `path`, `module`, `package`, `kind` (`class`, `interface`, `enum`, `abstract`, `typedef`, `extern`), `isExtern`, `source`, `typeParameters`, `supertypes`, `interfaces`, `underlying` (type or null), `from`, `to`, `members` |
| Source | `visibility` (`public`, or `internal` for a declaration written `internal`, which only its own package may use), `position` (`file`, with `/` separators, and one-based `line`), `metadata` (`{name, arguments}`, arguments as source text), `documentation` (null or `{markdown, tags}`) |

`package` is the name of the package whose sources hold the declaration (`--api-package=NAME=DIRECTORY`; `haxeon doc`
passes every package of the project), and a `file` is relative to that package's root, so a reader finds the source as
the package's location joined with it. Without a package (the standard library, FFI modules generated into a build),
`package` is null and the file is relative to its source root. No path in the model is this machine's.
| Tag | `name` (`param`, `return`, `throws`, `see`, `deprecated`, `since`), `parameter` (the name for `param`, otherwise null), `text` |
| Type parameter | `name`, `constraints` (types) |
| Member | `name`, `kind`, `isStatic`, `source`, then by kind: `field` has `isFinal`, `type` and `overrides`, `enumValue` has `type`; `property` has `type`, `get` and `set` (`default`, `null`, `never`, `get`, `set`, `dynamic`) and `overrides`; `constructor`, `method`, `function` (a module's), `enumConstructor`, `conversion` and `operator` have `typeParameters`, `arguments` and `result`, with `overrides` for a method, `operatorText` for an operator and `conversion` (`from` or `to`) for a conversion |
| Argument | `name` (null for an unnamed enum payload), `type`, `optional`, `defaultValue` (source text or null) |

A declaration written `internal` (docs/reference/LANGUAGE_SUPPORT.md) is described, with `visibility` `internal`: the
editor shows it to its own package's code, and the reference and the documentation coverage leave it out.

`overrides` is, for an instance member of a class or interface, the path of the supertype whose member of the same name it
overrides or implements, and null otherwise (a static member, a new one, or one of an enum, abstract or module). It is
found as Javadoc finds inherited documentation: the interfaces a type implements, each with its own bases, before its
superclass chain. A member without a comment of its own is documented by that member's comment, followed up the
hierarchy until one has a comment; the reference says which type it is from, the editor shows it on hover, and the
coverage counts it as documented. A comment is then written once, on the interface or base class, and not repeated on
every implementation.

Class inheritance and interface extension are `supertypes`; implemented interfaces and declared conformances are
`interfaces`. An extern abstract has kind `abstract` with `isExtern: true`. The metadata kept is `deprecated`,
`noCompletion` and `dox(hide)`.

A type is an object with a `kind`:

| Kind | Fields |
| --- | --- |
| `named` | `path` (a declaration's qualified path), `arguments` (types) |
| `builtin` | `path` (`Int`, `String`, `Array`, `Null`, `Map`, `Iterable`, ...), `arguments` |
| `parameter` | `owner` (the declaration or method that declares it), `name` |
| `function` | `arguments` (types, as declared), `optional` (one flag per argument), `result` |
| `anonymous` | `id`, `fields` (`{name, type, optional, isFinal}`, by name) |
| `anonymousRef` | `id` of an enclosing `anonymous` in the same type, for a structure that contains itself |
| `nativeAbstract`, `nativeScalar` | `name` (the runtime or ABI identifier) |

A typedef, as written in a module:

```json
{"path":"example.Label","module":"example.Label","kind":"typedef","isExtern":false,
 "source":{"visibility":"public","position":{"file":"example/Label.hx","line":4},"metadata":[],
  "documentation":{"markdown":"A display label.","tags":[]}},
 "typeParameters":[],"supertypes":[],"interfaces":[],
 "underlying":{"kind":"builtin","path":"String","arguments":[]},"from":[],"to":[],"members":[]}
```

The same program always gives the same bytes: types and modules are sorted by path; members stay in the order the source
declares them (a module's variables and functions by line), which is how their author grouped them; signature arguments,
constraints and annotations keep their declaration order; and the JSON is written field by field. A description is the
same with or without an entry.

## Rendering

The website's reference (site/api.mjs, as HTML with links) and the editor's hover and signature help (`ApiText`) show the
model as Haxe declarations, by the same rules: a type by its short name, a typedef by its own name, type arguments in
`<>`, a function type as `(A, ?B) -> R`; an argument `?name:T` when it may be left out and `name:T = value` when it has a
default; a field as `final` or `var`, a property with its accessors, a method as `function name<T>(...):R`, a
constructor as `new(...)`, an enum constructor by its name and payload; a type's declaration line with its kind, type
parameters and what it extends, implements or stands for. A member is shown without its owner, as Haxe's own display
does. A change to these rules changes both renderers.

## Editor

Hover and signature help describe a declaration from the model, built one declaration at a time
(`ApiModelBuilder.typeNamed`, `moduleMember`) from the semantic program the last analysis kept, so the editor and the
reference show the same signature. Hovering a type shows its declaration line; signature help for `new T(` shows the
constructor, inherited ones included. A local, a type parameter, a built-in type's member, or a declaration an edit
added since the last analysis are described as the semantic index has them.
