# Test & quality

## test

`haxeon test` builds the project's tests and runs them: a package keeps them in a project of their own,
`tests/haxeon.toml` (or `tests/haxeon.json`) beside its manifest, whose entry runs the tests and exits
with a status other than 0 when one fails. Run in that `tests` directory, it runs the tests project itself. It takes the
options of `run`, `--watch` included (the tests run again after each edit), passes the arguments after `--` to the tests,
and exits with 0 when they pass and 1 when they fail. `haxeon workspace test` runs the tests of many projects at once,
caching passing runs.

## fmt

`haxeon fmt` uses Haxeon's built-in lossless formatter. It rewrites files by
default, while `--check` reports files that would change; a directory stands for
the `.hx` files under it. Use `--stdin` for editor or pipeline integration.

The style comes from the project: the `format` section of the nearest
manifest (`haxeon.toml` or `haxeon.json`) above a file that has one, else tabs and
120 columns. `haxeon fmt`, `haxeon lint --fix` and the language server all read it
(the language server ignores an editor's tab settings), so a file formats the same
everywhere. A package's tests manifest without a `format` section takes the package's.

```toml
[format]
indent = "spaces"
indentWidth = 2
lineWidth = 100
```

(`"format": {"indent": "spaces", "indentWidth": 2, "lineWidth": 100}` in a `haxeon.json`.)

`indent` is `tabs` or `spaces`, `indentWidth` the width of one level (the columns
a tab counts for), `lineWidth` the column limit; every key is optional and an
unknown key or bad value is an error. The formatter accepts any source that lexes
and whose brackets balance, including Haxe that Haxeon's compiler does not support
yet, and refuses output that changes a token or a comment's text. A file that must
keep its layout says `@formatter:off` in a comment; without `@formatter:on` the
rest of the file is kept as written.

```sh
haxeon fmt src/Main.hx
haxeon fmt --check src/Main.hx
cat src/Main.hx | haxeon fmt --stdin
```

## lint

`haxeon lint` reports imports a file never uses and exits with 1 when it finds any;
`--fix` removes them and reformats a file that was formatted before. Imports resolve
against the `sourceRoots` of each `--manifest`. A wildcard, a module that does not
resolve, an alias of another type and an abstract with implicit conversions are
never reported, since removing them could change what the file means. Enum imports
are used through their constructors.

It also reports runs of imports that are not in order, and `--fix` sorts them by path
(ASCII, so `compiler.Compiler` sorts before `compiler.ffi.HxiAbi`). A run is
consecutive import lines; a blank line, a comment, a `#if` line, a `using` or an
import sharing its line with other code ends it, so groups stay where they are. A
later import of a name wins, so a run where two imports make the same short name
visible (module imports count every type the module declares), or with a package
wildcard, keeps its order and is not reported.

It reports a call argument written `name: name`, which `name:` says (rule
`redundant-argument-name`), and `--fix` shortens it. An object literal's
`{name: name}` and an argument that passes anything else are left alone.

It reports a lambda written `function(...)` that an arrow can write (rule
`function-lambda`), so a lambda has one form, and `--fix` writes it as one:
`function(x) return x + 1` becomes `x -> x + 1`. A lambda with a return type
(`function(x):Int ...`) or a rest parameter keeps the `function` form, which is the
only one that can say either, and a named local function is a declaration. An
arrow's block returns the value of its last expression, where a `function` block
drops it, so `--fix` converts a block that ends in an expression only where its
types show that changes nothing: the lambda's type returns Void (a callback of
`Int->Void`), or the expression is itself Void. It asks the typed tool below for
that. One the types do not settle, such as `var f = function() { list.push(x); }`
(`push` returns the new length), stays reported: give it a type, or write the
arrow by hand.

`--only RULE` checks one rule. A file turns a rule off for itself with a line
`// @lint:off RULE`, which may say why after a colon: a test whose subject is the
`function` form keeps it that way.

These four rules read syntax only and run by default. The rule `unbound-local` needs
types, so it is opt-in and runs only when `--only unbound-local` names it:

```bash
haxeon lint --only unbound-local src
```

It names each local whose type nothing fixes, which therefore is `Dynamic`: a
`var x;` never assigned, a `var x = null` never given a value, or a `var list = []`
never used in a way that fixes its element type.

```text
src/Main.hx:4: local "x" is Dynamic: nothing fixes the type of local "x"
src/Main.hx:5: local "list" is Dynamic: nothing fixes the element type of this empty array
```

Haxe accepts such a local and gives it the type `Dynamic` without a warning, and so
does Haxeon's compiler; the rule is there to audit code for them. A local that a
later assignment, a `push` or a typed use (a return, a typed argument) fixes is not
named. Each file is typed as the editor types it: its project is the nearest
`haxeon.toml`, `haxeon.json` or `.hxml` above it (`--manifest` is not used), and the file's module
is the entry. If a file's program has type errors, they go to standard error, the
bodies that typed are still checked, and a body that failed is not. The command exits
with 1 when it names a local or a program does not type. The rule has no `--fix`:
give each local it names a type. It runs in a program that links the compiler, like the
language server: the compiler's own (its `lint` role) when it is current, as in a release, else a tool of its own
(`LintMain`) built on first use.

The opt-in rule `module-namespace` names each module-level variable or function
reached through its module's name, a Haxeon extension stock Haxe rejects (see
[Language support](../LANGUAGE_SUPPORT.md)):

```bash
haxeon lint --only module-namespace src
```

```text
src/Main.hx:8: "Settings.hits" names app.Settings.hits through its module's name, which Haxe rejects: import app.Settings.hits or write it in full
```

Haxe's forms are an import of the member (`import app.Settings.hits;`) or its full
path; a class's own static named through the imported class (`Store.count`) is
Haxe's too and is not named. It reads each file's project as `unbound-local` does,
exits with 1 when it names a use or a program does not compile, and has no `--fix`.

The opt-in rule `throw-non-exception` names each `throw` whose value's static type
is not `haxe.Exception` or a subclass of it: a `String`, an enum, `Dynamic`, or a
type variable nothing has fixed when the `throw` is typed:

```bash
haxeon lint --only throw-non-exception src
```

```text
src/Main.hx:12: throw of String, not a haxe.Exception: throw an Exception subclass
```

Haxe accepts any thrown value, and so does Haxeon; a `catch (e:haxe.Exception)`
sees such a value wrapped in a `haxe.ValueException`. Code that throws only
exceptions never needs that wrap, and this rule checks that it does. Only the
`throw`s written in source are named, not those the compiler generates, and only
in code the project's configuration compiles: a branch of `#if` it does not take
is not typed, so not checked. It reads each file's project as `unbound-local`
does, skips a body that does not type, exits with 1 when it names a `throw` or a
program does not type, and has no `--fix`. Haxeon's own sources keep to the
subset: the compiler and its tools throw `CompileError` for a located compile
error and `compiler.core.InternalError` for any other failure.

```sh
haxeon lint --manifest haxeon.toml src/Main.hx
haxeon lint --fix --manifest haxeon.toml src/Main.hx
```
