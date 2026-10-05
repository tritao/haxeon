# Optimization plan execution

The performance gates finished. Bounds elimination and all three GC experiments failed their gates and were
removed. The census, stronger division oracle, counted-loop analysis/fixture and project inline setting remain.
The final bootstrap refresh and validation of the resulting tree passed. The benchmark README retains its
accepted numbers because no runtime optimization from this plan was accepted.

| Stage | Final outcome |
|---|---|
| 0: baseline and division oracle | Full baseline validation passed; accepting 3.0 in the reciprocal mutation makes the fixture fail (exit 7). |
| 1: census | Read-only diagnostic and six-benchmark tables committed; corrected analysis recognizes actual pre-increment frontend IR; allocation explanations, constant-field invariants and finite power classification are tested. |
| 2: fused writes | No-go: no material hot ArraySet target in fasta or nbody; implementation omitted under the census gate. |
| 3: counted-loop reads | Rejected: best gain 0.78%, below 3%; fasta regressed 6.44%. Experimental implementation removed; census analysis and portable fixture retained. |
| 4: GC locality | Profile committed as `c956a9a1`; all three changes rejected (tree results within ±0.3%, below 5%). Pointer-free scanning and contiguous TLAB runs already exist. |
| 5: small items | Project inline setting, CLI documentation and bootstrap refresh committed. Final batch refresh `ecd680c3` rebuilds identically and reaches a fresh fixed point. |

Details: [IR census](IR_OPPORTUNITY_CENSUS.md), [bounds experiment](BOUNDS_CHECK_ELIMINATION.md), and
[GC profile](GC_PROFILE.md). Raw local evidence is under `out/optimization-next`.

## Final validation

These runs use the resulting source tree and restored HashLink/runtime, with fresh tools built under
`out/optimization-next/accepted/`. Off mode means `HAXEON_INLINE=0 HAXEON_LOADSTORE=0 HAXEON_STRENGTH=0`.

| Suite / command | Result | Evidence under `out/optimization-next/` |
|---|---|---|
| Non-Wasm manifest sweep, defaults and off | 324/324 in each mode | `accepted-sweep-on.log`, `accepted-sweep-off.log` |
| GC controls, collection pacing, thread stress | Each x10 at default and 65536 trigger, in each mode; 120 runs | Same sweep logs |
| `build.hl test 8`, defaults and off | 471/471 in each mode | `accepted-driver-on.log`, `accepted-driver-off.log` |
| `scripts/test-wasm-backend.sh` | Passed | `accepted-wasm.log` |
| `scripts/test-wasm-gc-parity.sh` | 321 fixtures agree; 14 established skips | `accepted-parity.log`, `tests/programs/wasm-parity-skips.tsv` |
| `tests/differential/run.sh` | Passed | `accepted-differential.log` |
| `scripts/check-self-hosting.sh` | Seed, stage 1 and stage 2 reach a byte-for-byte fixed point | `accepted-self-host.log` |
| `scripts/bootstrap-compiler.sh`, then `--self` | Converged; checked-in compiler and function map rebuild identically | `accepted-bootstrap.log`, `accepted-bootstrap-self.log` |
| `test-workspace.sh` | Passed | `accepted-integration-workspace.log` |
| `test-compiler-embedding.sh` | Passed | `accepted-integration-embedding.log` |
| `test-git-package-lock.sh` | Passed with private compiler cache | `accepted-integration-lock.log` |
| `test-dap-inline-config.sh` | Manifest inline=false overrides environment inline=1; helper breakpoint stops | `accepted-dap-inline.log` |
| Stock Haxe interpreter, both new/strengthened fixtures | Independently returns 42 | `accepted-stock/float-div-pow2.log`, `accepted-stock/counted-array-loops.log` |
| Unsafe strength mutation accepting 3.0 | Fixture fails with exit 7 | `accepted-oracle-mutation.log`; source untouched |

The driver count is 471 after removing the rejected pass-specific unit (the experimental tree had 472).
The retained driver catalog includes StrengthReductionMain, InlineConfigurationMain, LoopBoundsMain and
OpportunityCensusMain. Experimental GC stress also passed 480 executions, detailed below.

AArch64 was not tested. Other DAP suites were not run. Fused-write tests and timings were omitted because Stage 2
failed its census gate. GC runs on the other four benchmarks were omitted because every candidate failed the
first tree-speed gate. No additional README results refresh was made: no runtime optimization passed, so its
accepted table remains unchanged. Known StringBuf/null and Wasm String.fromCharCode bugs remain; the existing
object-map-remove skip is retained, with all 14 skip reasons in the parity manifest.

## Intermediate validation and failed attempts

Baseline logs:

- `sweep-on.log`, `sweep-off.log`: all 323 then-existing non-Wasm manifest fixtures, both modes; three GC fixtures
  x10 each at default and `HL_GC_MIN_TRIGGER=65536` in each mode.
- `driver-on.log`, `driver-off.log`: 467/467. After census and project configuration, `final-driver-on.log` and
  `final-driver-off.log`: 468/468. Off mode disables inline, load/store and strength passes.
- `wasm.log`: backend suite passed. `parity.log`, `final-parity.log`: 320 supported fixtures, 14 established skips.
- `differential.log`, `self-host.log`, `final-self-host.log`: passed; self-hosting reaches a byte-for-byte fixed point.
- `integration-workspace.log`, `integration-embedding.log`: passed. `integration-lock.log` had a connection reset;
  the unchanged retry in `integration-lock-retry.log` passed.
- `gc-experiment-tests.log`: three GC fixtures x20 at default and low trigger, all three experiment switches enabled
  together; 120 successful executions, including threaded allocation/retained-chain stress. Existing cursor
  assertions and overrun checks remain enabled. `gc-independent-tests.log` adds 120 executions per switch with
  other switches zero; all 360 pass, for 480 combined and independent stress executions.

Bounds experiment logs before the final preheader-proof tightening:

- `bounds-driver-on.log`, `bounds-driver-off.log`: 471/471, experiment enabled with the other IR passes on and off.
- `bounds-sweep-on.log`, `bounds-sweep-off-retry.log`: all 324 non-Wasm manifest fixtures and GC x10 at both triggers.
  The first off run hit a missing compiler file because its artifact was being rebuilt; retry uses an immutable copy.
- `bounds-wasm.log`: backend suite passed. `bounds-parity.log`: 321 supported fixtures agree, 14 established skips.
- `bounds-differential.log`: passed. `bounds-self-host-retry.log`: fixed point passed after correcting the generated
  pointer helper's erased-array signature; the initial signature conflict is retained in `bounds-self-host.log`.
- `bounds-integration-workspace.log`, `bounds-integration-embedding.log`: passed. The package-lock run reset its
  connection again; `bounds-integration-lock-isolated.log` passed with a private XDG compiler cache. Shared-cache
  worker eviction by concurrent builds is a plausible cause, rather than a proven JIT failure.
- `bounds-mutation.log`: weakening call/alias barriers makes the frontend IR unit suite fail.
- Stock Haxe interpreter independently returns 42 for `counted-array-loops`; both checked and unchecked HashLink
  versions return 42. GDB using identical bytecode and `HL_JIT_BOUNDS=0/1` confirms removal of only redundant array
  comparisons/failure branches. Current unit tests also reject captured lengths invalidated in the preheader.
- `bounds-unit-final.log`, `bounds-preheader-mutation.log`: tightened proof passes its units, and dropping the
  preheader check makes the new unit fail. `bounds-self-host-final.log`: the tightened compiler reaches a fixed point.
- `bounds-metadata-unit.log` confirms ordinary reference arrays, excluded value-class/erased arrays and ABI memo
  invalidation. `bounds-binding-mutation.log` fails when native ABI metadata is omitted from the fingerprint.
- `bounds-fastpath-bytecode.log`: avoiding graph construction for functions without candidate reads leaves
  all six benchmark bytecode files byte-for-byte identical. `bounds-fastpath-unit.log` passes, and
  `bounds-self-host-fastpath.log` reaches a fixed point with that fast path included.

Census completion: `census-details-unit.log` passes; `census-details-report.log` confirms unchanged totals for all six benchmarks and allocation explanations. `census-details-self-host.log` reaches a fixed point after replacing unsupported reflection/bit-conversion helpers. `census-driver-on.log` and `census-driver-off.log`: 472/472 each with the final proof and diagnostic tests; off disables inline, load/store and strength.

`census-wasm.log` passes the final compiler backend suite; `census-parity.log` confirms 321 fixtures agree across Wasm32, Wasm GC and HL, with the same 14 established skips.

`census-sweep-on.log` and `census-sweep-off.log` pass all 324 non-Wasm manifest fixtures, plus each of the three GC fixtures x10 at both thresholds in each mode. `census-differential.log` passes stock-bytecode differential checks. `census-dap-inline.log` passes the targeted function-breakpoint integration after its cleanup change. The measurement runner now checks each alternating pair and discards pairs crossing load 4, while verifying frozen build hashes.


## Performance decisions

All runs used core 0, nine alternating pairs and identical bytecode for each A/B, with frozen build hashes and
per-pair load <=4. See the complete six-benchmark table in [bounds experiment](BOUNDS_CHECK_ELIMINATION.md) and
independent tree/RSS tables in [GC profile](GC_PROFILE.md). No runtime change passed. Experimental source was
restored from the respective repository HEAD only after checking the exact owned diff paths; rejected patches
were saved locally. The HashLink fork is clean at `9b3ea1c1`, matching the tracked submodule pointer. No rejected
fork commit or pointer bump was created. Unrelated `.claude/` and `hlprofile.dump` were preserved.

## Completion audit

| Plan requirement | Final evidence / disposition |
|---|---|
| Validate baseline; make divisors opaque; mutation must fail | Baseline ledger and final suites; array-backed reference divisors plus opaque 5/3 counterexample; stock 42 and mutation 7 |
| Read-only post-inline census, six benchmarks, top five weighted functions | `IR_OPPORTUNITY_CENSUS.md`, deterministic/no-mutation unit, six unchanged totals and allocation explanations |
| Only implement writes if material | No-go: nbody hot loops have no array writes; fasta hot writes are Bytes.set |
| Explicit immutable IR flags, all modes, cast dependency, alias/resize/exception fixtures | Experimental implementation and validation completed, then discarded under the failed 3% gate; proof analysis, fixture and cast documentation retained |
| Profile allocation/mark/sweep and cache/LLC misses before GC changes | `GC_PROFILE.md`, inline-frame phase split and raw perf reports |
| Independent GC choices, stress x20 including low trigger and thread/cursor checks | Three independent experiments tested; 480 stress executions; all rejected under the 5% gate; existing pointer-free skip/TLAB runs not duplicated |
| Core 0, median nine alternating pairs, identical bytecode, low load, perf/disassembly | Bounds six-benchmark and GC tree tables; raw pairs/load/build hashes; GDB scaled-load comparison and instruction/cycle counters |
| Manifest inline setting and debugger behavior | Per-compiler cache identity unit, CLI documentation and live DAP function-breakpoint test |
| Batch bootstrap and results table | Final bootstrap commit `ecd680c3`, identical self-rebuild and fixed point; README unchanged because all runtime experiments were rejected |
| Commit hygiene | Separate logical commits with required trailer; formatter run; fork clean at tracked pointer; no pushes, stashes or unrelated work discarded |

The complete requested plan is finished through its conditional gates. Rejection is the specified outcome when
an experiment does not qualify; the reports preserve the measurements rather than retaining unproven runtime code.
