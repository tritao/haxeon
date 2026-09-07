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
| `utest.Assertation` | pass | `-` | - |
| `utest.Async` | blocked | `E2001` | Missing module "haxe.Timer" |
| `utest.Dispatcher` | pass | `-` | - |
| `utest.ITest` | pass | `-` | - |
| `utest.IgnoredFixture` | blocked | `E0002` | Expected Function, got Var |
| `utest.MacroRunner` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.Runner` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.Test` | blocked | `E1020` | Unknown type "ITest" |
| `utest.TestData` | blocked | `E0002` | Expected Colon, got LeftParen |
| `utest.TestFixture` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.TestHandler` | blocked | `E0002` | Expected expression |
| `utest.TestResult` | blocked | `E0002` | Expected expression |
| `utest.UTest` | blocked | `E0002` | Expected Function, got Final |
| `utest.exceptions.AssertFailureException` | pass | `-` | - |
| `utest.exceptions.UTestException` | pass | `-` | - |
| `utest.ui.Report` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.common.ClassResult` | pass | `-` | - |
| `utest.ui.common.FixtureResult` | pass | `-` | - |
| `utest.ui.common.HeaderDisplayMode` | pass | `-` | - |
| `utest.ui.common.IReport` | blocked | `E0002` | Expected Function, got Public |
| `utest.ui.common.PackageResult` | blocked | `E0002` | Expected expression |
| `utest.ui.common.ReportTools` | blocked | `E0002` | Expected Function, got Public |
| `utest.ui.common.ResultAggregator` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.common.ResultStats` | pass | `-` | - |
| `utest.ui.macro.MacroReport` | pass | `-` | - |
| `utest.ui.text.DiagnosticsReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.HtmlReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.PlainTextReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.PrintReport` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.ui.text.TeamcityReport` | blocked | `E0002` | Unterminated string interpolation |
| `utest.utils.AccessoriesUtils` | blocked | `E0002` | Expected Function, got Identifier |
| `utest.utils.AsyncUtils` | blocked | `E2001` | Missing module "utest.utils.Async" |
| `utest.utils.Macro` | blocked | `E2001` | Missing module "haxe.macro.Compiler" |
| `utest.utils.Print` | blocked | `E1007` | Unknown function "Sys.print" |
| `utest.utils.TestBuilder` | blocked | `E0002` | Expected Function, got Identifier |

Baseline result: **10 of 36 modules analyze unchanged**.

## Priority order

1. Parse `using` declarations; macro-only declarations are now safely omitted
   from the runtime AST, exposing `using` as the shared next syntax blocker.
2. Expand property and interface-field parsing; `TestResult`, `PackageResult`,
   `ReportTools`, and `IReport` now stop at these declaration/expression forms.
3. Improve same-package and secondary-type module resolution, beginning with
   upstream `utest.Test` and `utest.utils.AsyncUtils`.
4. Add `Sys.print`, then broaden `Type`/`Reflect` APIs and add `haxe.Timer`;
   these unlock text output, typed exception assertions, reports, and
   asynchronous tests.

The local compatibility layer remains the active implementation until an
upstream module passes both analysis and runtime tests. Modules should be
replaced individually rather than carrying speculative edits in `vendor/utest`.
