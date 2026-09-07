# Upstream utest compatibility

This baseline tracks unmodified upstream utest against Haxeon's analysis
pipeline. The source is pinned as the `vendor/utest` submodule at commit
`a055e05e2e872ae12a32b53d0200612345059c38`; its manifest version is
`2.0.0-alpha` and its license is MIT.

Run the probe with:

```sh
./scripts/probe-utest-upstream.sh
```

The probe loads every upstream source module, imports each module from a small
executable entry point, and records its first analysis failure. A passing row
means the module and its reachable dependencies analyze unchanged; it does not
yet promise complete runtime behavior.

## Baseline

| Module | Status | Diagnostic | First blocker |
| --- | --- | --- | --- |
| `utest.Assert` | blocked | `E0002` | Expected Semicolon, got Identifier |
| `utest.Assertation` | blocked | `E1020` | Unknown type "Any" |
| `utest.Async` | blocked | `E1020` | Unknown type "haxe.Timer" |
| `utest.Dispatcher` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ITest` | pass | `-` | - |
| `utest.IgnoredFixture` | blocked | `E0002` | Expected Function, got Var |
| `utest.MacroRunner` | blocked | `E0002` | Field "macro" requires a type or initializer |
| `utest.Runner` | blocked | `E0001` | Unexpected character "~" |
| `utest.Test` | blocked | `E1020` | Unknown type "ITest" |
| `utest.TestData` | blocked | `E0002` | Expected Colon, got LeftParen |
| `utest.TestFixture` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.TestHandler` | blocked | `E0002` | Expected expression |
| `utest.TestResult` | blocked | `E1020` | Unknown type "Any" |
| `utest.UTest` | blocked | `E0002` | Expected Function, got Final |
| `utest.exceptions.AssertFailureException` | blocked | `E1020` | Unknown type "haxe.Exception" |
| `utest.exceptions.UTestException` | blocked | `E1020` | Unknown type "haxe.Exception" |
| `utest.ui.Report` | blocked | `E0001` | Unexpected character "~" |
| `utest.ui.common.ClassResult` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ui.common.FixtureResult` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ui.common.HeaderDisplayMode` | pass | `-` | - |
| `utest.ui.common.IReport` | blocked | `E0002` | Expected Function, got Public |
| `utest.ui.common.PackageResult` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ui.common.ReportTools` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ui.common.ResultAggregator` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ui.common.ResultStats` | blocked | `E0002` | Expected Less, got LeftParen |
| `utest.ui.macro.MacroReport` | pass | `-` | - |
| `utest.ui.text.DiagnosticsReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.HtmlReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.PlainTextReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.PrintReport` | blocked | `E0001` | Unexpected character "~" |
| `utest.ui.text.TeamcityReport` | blocked | `E0002` | Field "override" requires a type or initializer |
| `utest.utils.AccessoriesUtils` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.utils.AsyncUtils` | blocked | `E2001` | Missing module "utest.utils.Async" |
| `utest.utils.Macro` | blocked | `E0002` | Field "macro" requires a type or initializer |
| `utest.utils.Print` | blocked | `E1020` | Unresolved inferred type |
| `utest.utils.TestBuilder` | blocked | `E0001` | Unexpected character "$" |

Baseline result: **3 of 36 modules analyze unchanged**.

## Priority order

1. Support function-type syntax with named and optional arguments. The current
   `Expected Less, got LeftParen` failures share this parser limitation.
2. Add core aliases and classes used throughout upstream utest: `Any`,
   `haxe.Exception`, and `List`.
3. Add regular-expression literals and `EReg`; the newly selected target
   branches in `Runner`, `Report`, and `PrintReport` now reach this syntax.
4. Improve same-package and secondary-type module resolution, beginning with
   upstream `utest.Test` and `utest.utils.AsyncUtils`.
5. Broaden `Type`/`Reflect` APIs, then add `haxe.Timer`; these unlock typed
   exception assertions, reports, and asynchronous tests.

The local compatibility layer remains the active implementation until an
upstream module passes both analysis and runtime tests. Modules should be
replaced individually rather than carrying speculative edits in `vendor/utest`.
