Status: Phase 1 implemented: the model and its JSON (`--no-output --api-json=FILE` on the direct compiler); `--xml` is
deleted. The rest of phase 2 is planned below.

# Haxeon API model

The API model describes the public types, members and module-level functions and variables of a successfully typed
program. It is what Haxeon's package reference is generated from, and what editor hover and signature help will read, so
that the editor and the published reference never disagree. Its serialized form is a Haxeon-owned JSON format with a
version and the schema below. Haxe's type-description XML (`--xml`, the input of dox) is not a goal: it is built from the
syntax tree, so it spells types as written in each module rather than qualified, and loses optional arguments; it is
deleted.

## Built from the semantic program

The model is built by an analysis, not a build: `--api-json` takes `--no-output`, so the sources are typed and nothing is
generated. Every module the request loads, except the standard library's, is typed as a root of that analysis, so the
model describes all of them rather than what an entry reaches, and `--entry` is optional: a library has none. The roots
belong to the one analysis, so a compile server's later builds are unchanged. The model is read from the semantic program
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
| Root | `version` (integer, `1`), `modules`, `types` |
| Module | `path`, `file` (its source, relative to its source root), `members` (its public top-level variables and functions) |
| Declaration | `path`, `module`, `kind` (`class`, `interface`, `enum`, `abstract`, `typedef`, `extern`), `isExtern`, `source`, `typeParameters`, `supertypes`, `interfaces`, `underlying` (type or null), `from`, `to`, `members` |
| Source | `visibility` (`public`), `position` (`file`, with `/` separators, and one-based `line`), `metadata` (`{name, arguments}`, arguments as source text), `documentation` (null or `{markdown, tags}`) |
| Tag | `name` (`param`, `return`, `throws`, `see`, `deprecated`, `since`), `parameter` (the name for `param`, otherwise null), `text` |
| Type parameter | `name`, `constraints` (types) |
| Member | `name`, `kind`, `isStatic`, `source`, then by kind: `field` and `enumValue` have `type`; `property` has `type`, `get` and `set` (`default`, `null`, `never`, `get`, `set`, `dynamic`); `constructor`, `method`, `function` (a module's), `enumConstructor`, `conversion` and `operator` have `typeParameters`, `arguments` and `result`, with `operatorText` for an operator and `conversion` (`from` or `to`) for a conversion |
| Argument | `name` (null for an unnamed enum payload), `type`, `optional`, `defaultValue` (source text or null) |

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

## Phase 2

- `haxeon doc` writes the model for a project, with the arguments its build uses, and records each package's exposed Haxe
  packages from its manifest, so consumers do not guess what is internal.
- Editor hover and signature help read it. `LanguageService.hover` renders the member's type or signature from the model,
  `hoverDocumentation` its comment and tags, and `signatureHelp` the callable, with each `@param` for the active argument;
  the position, symbol and active-argument lookups stay. Locals, incomplete edits and declarations not in the model keep the
  editor's semantic or recovery path.
- The website's `build:api` step renders one page per exposed Haxe package from the model, and reports doc-comment coverage.
