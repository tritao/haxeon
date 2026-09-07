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

Optional `haxe.PosInfos` parameters are populated by the compiler with the
call-site file, one-based line, enclosing class, and method. These values are
embedded in generated code and refreshed when an incremental edit moves the
call site.

The source exception subset provides `haxe.Exception`, `haxe.ValueException`,
and `haxe.CallStack`. Exception objects retain messages, wrapped values, and
previous-exception chains. Stack snapshots are currently deterministic and
empty until native HashLink stack capture is exposed through the runtime ABI.

The pinned upstream source and module-by-module analysis baseline are documented
in [Upstream utest compatibility](../docs/UTEST_UPSTREAM_COMPATIBILITY.md).
