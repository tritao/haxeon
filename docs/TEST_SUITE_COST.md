# Test suite cost

Status: investigation report, 2026-11-10; the proposals below are approved in this order (compilation server for the named cases, the checked-suite split, HelperFixtures, -j8 behind a MemAvailable floor) and not yet done.

**The "80 minutes" for both suites in the first gate runs was an invocation, not the suite.** `scripts/test-driver.sh` run alone had no `HAXEON_MAIN_HL`, so every program compile ran `haxe --run Main` (the Haxe interpreter over the whole compiler). With the compiler prebuilt to HashLink, as `scripts/test.sh` does and the driver now does itself, one suite takes 13 to 15 minutes at -j4 (wave 3: plain 893 s, checked 929 s, 847 cases each).

Measured on the branch at the sources of commit 5f2bd5aa, 20 cores, 31 GB (22 GB in use by other sessions during the runs), load 6-13.

## 0. Done

- `scripts/test-driver.sh` builds Main to HashLink by default (e5 below); `HAXEON_TEST_INTERPRETED=1` keeps the interpreter path.
- Two program cases wrote one fixed directory from both builds at once and failed 2 in 60 concurrent runs; fixed (e11e60b9).

## 1. Program-case runner

Each program is compiled twice (live, plain), each as a separate process: `hl haxeon-main.hl <src> <out> [--plain]`, then run twice.
There is no shared worker. What a compile costs with the prebuilt compiler, under load 8 (CPU time; wall is within 0.1 s):

| case | live | plain | peak RSS |
| --- | --- | --- | --- |
| add | 0.34 s | 0.37 s | 62 MB |
| try-branch-local | 0.36 s | 0.42 s | 62 MB |
| generic-erased-reference-checks | 0.37 s | 0.36 s | 65 MB |
| array-last-index-of | 0.38 s | 0.41 s | 124 MB |
| struct-optional-flow | 0.46 s | 0.58 s | 149 MB |

The floor is about 0.3 s: hl start, loading the compiler's 2.3 MB of bytecode, the reachable stdlib modules (the stdlib is not
re-parsed whole; only modules the program reaches). So with the prebuilt compiler a program case costs well under a second to compile and
a fraction to run, and the whole program phase takes about 115 s at -j4 for 565 sources x 2 modes.

**The slow part was the invocation, not the runner.** Run alone, test-driver.sh had no HAXEON_MAIN_HL, so each compile was
`haxe --run Main` (the Haxe interpreter over the whole compiler, ~2 s or more each); scripts/test.sh builds the HL compiler once and
exports it. That is what made the wave 1 gates 80 minutes. Fixed by making the driver build it by default.

A warm shared compiler per worker would save at most the 0.3 s floor per compile (about 5 min of CPU across 1130 compiles, ~1.3 min at
-j4) and would need a fresh session per case to keep cases independent. Not worth the risk of shared state: **recommend no warm
worker for program cases**.

## 2. Check-mode coverage

HAXEON_CHECK_REUSE=1 verifies reuse, and a program case is one cold compile in a fresh process: `src/Main.hx` sets `livePatching =
!plain`, which disables pipeline reuse for the live build, and the plain build has no earlier build in its process. What check mode does
on a program case is therefore only (a) the within-compile inliner memo comparison and (b) the new provider-table assertion, which is
the most useful part. Everything the checked suite adds over the plain one for the 565 programs is those two checks.

Cost: the checked program phase is 117-120 s vs 112-115 s plain (+5%): small. The checked suite as a whole (13 min) is dominated by
named cases (530 s), not programs.

Proposal (coverage goes up, nothing dropped):
- Plain both-mode suite: keeps all 565 programs, as now.
- Checked suite: runs the named cases, the warm-rebuild and hot-reload tests (WarmRebuildReuseMain, the Live* mains), the provider
  assertion sweep over all programs (compile only, no run: about 3 min at -j4 with the prebuilt compiler, already scripted as
  `warm-prof/sweep.sh`), and *a reuse-exercising subset*: each program compiled, edited (append a unused function), and rebuilt warm
  in one process under check mode. That last part is new coverage: today no program case exercises warm reuse at all.
- Net: the checked suite's program phase becomes "compile all 565 under check mode (~3 min) + warm edit-rebuild of all programs (~3 min)"
  instead of "compile and run all 565 x 2 under check mode (~2 min of compile + run)". Time is similar; coverage of reuse rises from
  none to every program.

## 3. Named cases (239 mains), measured one at a time

Each main is compiled with stock `haxe -hl` (typing the compiler's own sources the main imports) and run on hl. 182 compiled with the
tree as measured; the other 57 had stopped compiling because of the `IrFunction` change (fixed since) and are not in these numbers.

- Compile: median 5.5 s CPU, p90 6.7 s, **931 s of the 1049 s total (89%)**, peak 485 MB. Run: median 0.4 s, total 118 s CPU, peak 592 MB.
- 160 of 182 compiles take at least 4 s: the cost is shared setup (type-checking the same compiler sources again for each main), not the
  test content.
- Slowest by wall (compile + run): LiveClosureHostMain 33.7 s (27 s run, mostly waiting), GcIncrementalMain 20.2 s (20 s CPU in the run),
  CompilerGapsMain 15.3 s, CompilerKeepAliveMain 12.1 s, LiveStrictRefusalMain 12.1 s, InheritedMethodContractMain 10.9 s,
  BuildSystemMain 10.5 s (10 s run), TypedMetadataMergeMain 9.9 s, CodeIdentityMain 9.2 s, LiveStrictSignatureLambdaMain 9.0 s.
- They share one cost, the compile. **Tried: a Haxe compilation server (one `haxe --wait` per worker, mains connecting with `--connect`)
  and rejected.** On 32 named cases at -j4 it took 62 s against 87 s without servers, a 29% gain including the warm-up of the four
  servers, not the 2-4x that six single compiles suggested (four servers each type-check the compiler's sources once). More important,
  its output depends on typing order: a fresh compile is byte-identical to another fresh compile, and a cold server equals a fresh
  compile, but a warm server's module for the same main differs (same length of dump, different function indices and constant-pool
  order). A sample audit that recompiled three mains fresh and compared bytes failed on two of them. The difference is probably benign
  ordering, but a cache whose results cannot be shown equal to a fresh build is not a safe speed-up for a gate, and weakening the audit to
  a behavioral comparison would only restate what the case checks. The patch is kept in the scratch directory, not in the tree.
- What remains for the named phase: compile all mains into one module and select the main by argument (feasibility not yet checked:
  every class's static initializers would run at every start, and mains may depend on isolated global state), only if the named phase
  still matters after the other changes.

## 4. -j8

Per job: named compile <= 485 MB, named run <= 592 MB, program compile <= 150 MB, program run small. -j8 therefore needs at most about
8 x 600 MB = 5 GB. The machine has 31 GB but other sessions held 22 GB during these runs, leaving 8 GB, so -j8 fits but not with
much slack when those sessions run big builds. CPU: 20 cores, load 6-13 from other work. Recommend -j8 for the driver's compile phases
only if a memory floor check (`MemAvailable` >= 12 GB) passes, else fall back to -j4. The compile phases are CPU-bound, so expect
close to linear speed-up only while the load allows.

## 5. Fixtures that imitate generator output

Test mains that build IR helpers by hand with the names or rows a generator would give them, and so can drift from the compiler:
InlineEnumPayloadMain, InlineEnumEqualityAbiMain (both just needed provider rows added), ScalarClosureSelectionMain and
ScalarClosureCarrierMain (`$scalar-arguments:` names), InlinerMain, InlineEnumCarrierBoundaryMain, InterfaceValueDispatchMain,
ValueArrayAccessMain, SourceInlineEnumMain (`$inline-enum:` values). Proposal: a `tests/compiler/HelperFixtures.hx` that builds such
helpers by calling the real generator entry points (or, where those need a typing session, a function that wraps them), so the name
and the `provides` row come from the generator and a change in either fails the fixture loudly instead of passing by name.

## 6. Order I would do it in

1. ~~Compilation server for named cases~~ (rejected, see section 3).
2. The checked-suite split above, with the warm edit-rebuild addition. Done in part: the checked suite builds every program a third time, edited and rebuilt warm (it adds about 1 minute to the program phase, 150 s to 210 s); the plain suite is unchanged, and the rest of the split (compile-only checked sweep in place of the live and plain runs) is not done. What the sweep found is in WARM_REBUILD_REUSE.md.
3. HelperFixtures.
4. -j8 behind the memory floor check.

## 7. Measuring a cold build

`scripts/measure-cold.sh <label> [runs]` builds an app cold `runs` times (default 3) and prints, per run, the wall time, the compiler's own
time, the compile-count, the worker's CPU seconds and its peak RSS. `MEASURE_APP` names the app project; `HAXEON_ROOT` the checkout whose
compiler is measured, so one app can be built by two checkouts and the lines compared. It waits while the load average is at or above
`MEASURE_MAX_LOAD` (default 6) and for earlier compiler workers to exit, because a build that finds a worker alive reuses it and is not cold.

The worker is followed by pid, not picked by CPU: the first version took the busiest compiler process on the machine, and read a leftover
worker's 91 s and 6.5 GB for a build that used 64 s and 5.5 GB. Quote medians of at least 3, interleave the sides, and never compare a
number taken with a different app tree or at a different load.

## 8. The gate

`scripts/gate.sh quick|wave|full [jobs]` is the one way to run the suites for a report. It builds the compiler entry point and the build tool
once (a failed build stops it), refuses a tree with tracked changes (`GATE_ALLOW_DIRTY=1` runs and records "dirty"), and runs, in order:

| mode | suites |
|---|---|
| quick | the NUL guard; the driver in its default configuration (each program built live and plain, named cases, executables) |
| wave | quick, then the driver with `HAXEON_CHECK_REUSE=1` (adds the warm-edit rebuilds and the reuse comparisons) |
| full | wave, then `scripts/test.sh` |

Results go to `out/gate/<commit>-<mode>-<time>/`: a log per suite and `summary.txt` with the commit, mode, jobs, load at start and end,
cores, per suite the exit code, seconds and the driver's pass/fail line, a coverage line per driver run (`programs: N live, N plain,
warm-edit: yes (N)`) and the exit code. A gate report quotes that file and nothing else, so a report cannot describe a configuration the
run did not use. The coverage line counts the passing program cases in the log, so a driver that silently ran fewer cases shows it.
