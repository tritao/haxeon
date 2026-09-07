# Realtime Haxe standard library

This directory contains the source-level standard library compiled by
realtime-haxe. Sources under `haxe/` are selectively adapted from the Haxe
4.3.7 standard library rather than copied wholesale: the compiler currently
uses a deliberately smaller language and runtime ABI than the official Haxe
HashLink target.

The pinned upstream version and every imported file are recorded in
`UPSTREAM.md`. Imported sources retain their upstream copyright and MIT
license notices. Keep local compatibility edits small and document them next
to the source entry.

Declarations under `hl/` are target ABI façades owned by this project. They
carry explicit representation metadata and are not copies of upstream stdlib
implementations.

Register this directory with `Compiler.addSourceRoot("stdlib")`. Modules are
then discovered from their imports and type references, loaded only when they
enter the reachable dependency graph, and retained in the compiler's module
cache. Explicitly supplied modules take precedence over files in source roots.

Do not put compiler implementation sources from HaxeFoundation/haxe here. The
compiler and the standard library have different licenses.

## utest compatibility

The `utest` package provides a synchronous subset of the upstream API:
`utest.Test`, `utest.Assert`, `utest.Runner`, and `utest.ui.Report`. Assertions
include `equals`, `notEquals`, `isTrue`, `isFalse`, `isNull`, `notNull`, and
`fail`, plus `floatEquals`, `contains`, `notContains`, and untyped `raises`.

The synchronous runner supports `setupClass` and `teardownClass` around each
case, plus `setup` and `teardown` around every test. Teardown hooks still run
after setup or assertion failures, and hook failures have separate counters.
`Runner.addCase(test, filter)` and `Runner.globalPattern` provide substring
filtering without requiring `EReg`. Synchronous events are available through
`onStart`, `onProgress`, and `onComplete`; listeners use the familiar
`dispatcher.add(callback)` form.

Haxeon does not yet execute build macros. Instead, `utest.Test` uses
`@:discoverMethods("test", "spec")` to generate registration for parameterless
instance methods with those prefixes. Explicit `registerTests()` overrides the
generated registration. Async tests, positional assertion metadata, regular
expression patterns, and alternate report formats are not yet supported.
