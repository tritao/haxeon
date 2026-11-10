# Allocation census for bump-allocation Stage 3

The next measured target is 16-byte integer boxes, rather than arrays. Merkletrees creates one box per node;
Stage 1 only expands `ONew` object allocation and leaves these boxes on the native call path. The census also
shows substantial boxing in the compiler and lru, so their behavior and performance belong in the acceptance gate.

## Method

A scratch VM starts the existing exact per-type census immediately before running bytecode, and dumps before exit.
An allocation callback separately counts requested sizes and allocated bytes by runtime kind. The census includes
program initialization and execution, but excludes VM/module/JIT initialization before the bytecode entry point.
Call stacks are sampled with the census's jittered one-MiB byte interval. The size callback uses atomic counters.
No production source changes were needed for this instrumentation.

`HL_JIT_ALLOC_INLINE=1`, bounded retention and the 64 MiB cap were set. Census and callbacks deliberately force
ordinary allocator paths so every allocation is counted, including ones normally handled inline. Consequently,
these are allocation counts, not timings or direct measurements of fast-path hit rates. Separate uninstrumented
Stage 1 profiles below establish that boxing remains a runtime cost.

All six benchmark census outputs matched their uninstrumented outputs. Inputs were binarytrees 18, merkletrees 16,
nbody 5000000, fasta 2500000, spectral-norm 2000, and lru 100 / 1000000. The compiler was the stock-Haxe-built
`HaxeonCompiler`, compiling its own 461 source files to HashLink with the source list from the self-hosting script.
Its compilation completed successfully; instrumented compiler phase times are not performance evidence.

## Exact counts

| Workload | Total allocations | Integer boxes | Box count share | Array GC blocks |
|---|---:|---:|---:|---:|
| binarytrees | 68,332,307 | 0 | 0% | 2 |
| merkletrees | 29,971,907 | 14,985,902 | 50.00% | 2 |
| nbody | 31 | 0 | 0% | 5 |
| fasta | 1,666,706 | 0 | 0% | 18 |
| spectral-norm | 409 | 0 | 0% | 398 |
| lru | 97,359 | 97,098 | 99.73% | 2 |
| compiler | 157,033,514 | 15,372,371 | 9.79% | 32,256,676 |

Array counts above are GC blocks (header, separate storage and growth), not array objects. The
[array-specific follow-up](ARRAY_ALLOCATION_PROFILE.md) separates these and measures CPU headroom.

Every counted `i32` allocation requested 16 bytes. Merkletrees additionally allocated 14,985,902 40-byte Nodes;
boxes account for about 28.57% of its allocated bytes, versus half its allocation count. This is allocation volume,
not live heap size. Binarytrees is almost entirely 24-byte Nodes, already addressed by Stage 1.

Fasta predominantly allocates byte buffers and Strings (833,343 and 833,342 respectively). Nbody allocates almost
nothing in its hot computation. Spectral-norm's arrays are relatively few and include varying sizes; its high array
percentage is not evidence of a large allocation bottleneck. The compiler's largest count categories are arrays
(20.54%), Strings (18.70%) and byte buffers (17.71%). Their variable sizes, native emit sites and initialization
semantics would need separate designs and measurements.

## Runtime evidence and decision

Four `perf record` runs of uninstrumented merkletrees with Stage 1 active captured 1977 samples attributed to the VM
process, including 708 stacks through `hl_alloc_dynamic` (35.81%) and 189 through ordinary object allocation.
These are inclusive sampled stacks, not independent costs to sum. They support testing a cheaper integer-box path;
they do not predict a 35.81% runtime saving.

Proceed with a separately switched, Linux x86-64 integer-box prototype that shares Stage 1's TLS, policy, clearing
and slow-call preservation machinery. Keep nullable/null semantics, type headers and all padding initialization.
Do not generalize to pointer-bearing boxes or arrays based solely on these counts. Acceptance requires at least
3% on merkletrees, no regression in all six benchmarks, and acceptable compiler time/memory and full validation.

## Evidence and scope

Scratch collector source/build scripts, exact JSON counts, requested-size CSVs, sampled stacks, output comparisons,
four uninstrumented profiles and the compiler result are under `out/allocation-census/`. `manifest.json` records
bytecode and compiler-output hashes. This census used the accepted Stage 1 fork revision `46705542`; the main
repository baseline was `9333bb65`. Profiling runs are not load-qualified acceptance timings.

This step does not validate a new runtime feature. AArch64, Windows, 32-bit and GC_DEBUG/memcheck were not profiled.
The compiler workload is one fresh compilation, not a long-lived worker memory-retention test.

## Prototype outcome

The integer-box prototype cleared the merkletrees gain gate (19.63%) but was dropped because repeated LRU
comparisons regressed against the accepted runtime. See
[JIT_BOXED_ALLOCATION.md](JIT_BOXED_ALLOCATION.md) for that rejection.

The follow-up isolates cold JIT helpers from ordinary runtime text, removes the LRU regression, and measures
merkletrees at 0.259076 -> 0.207330 s (19.97% faster), with all six benchmarks and full correctness validation
complete. The implementation is opt-in; final compiler and startup/JIT timings remain pending. See
[JIT_BOXED_ALLOCATION_LAYOUT.md](JIT_BOXED_ALLOCATION_LAYOUT.md) for the controlled diagnosis and exact coverage.


# Editor action allocation census: flat structs and enum ports

This census measures the final flat-structs code at **`bb4072f842269f6166ecceadb547c9f75d0fbbeb`**.
It is separate from the compiler/bump-allocation census above. It covers one warmed occurrence of each of the
15 budgeted editor actions, with exact allocated objects and requested bytes. It measures allocation volume,
not retained heap size or user-action frequency.

## Frozen source and method

- Frozen outer application: `2de94628ca99a05b9ce93cb8b2858b8f8b6202bd`, with the mechanical local Flags/native-enum
  API ports. Authoritative local port commits are `cf8452cbf`, `fc8733155`, `5c95c2ba7`, `e98450f4a`,
  `4c2b0d4f8` and `887857eb3` on `haxeon-enum-ports` (based on outer `18afaf203`); that branch is not pushed.
- Both control and candidate use the same frozen app. Control is published Haxeon `fcfd253b`; candidate is
  `bb4072f8`. The table below compares their exact totals, not allocator-refill KiB.
- The checkout-built HashLink fork is `3ea38fcfa9e94f6febd5feac60ad02085c73ff7c`. No runtime or native pin changes
  are part of this census.
- The existing action-window harness starts at the **second** matching input after warmup and stops after the
  submitted frame, before timeline serialization. Scenarios run three cycles. Setup and other actions are excluded.
- `hl.Gc.censusStart(1)` samples every byte. Its initial zero sampling budget gives the first allocation one extra
  weighted byte. A unique calibration class is warmed before the window, then exactly one calibration object is
  allocated immediately after reset/start. Every capture asserts one marker object, marker stack weight = marker
  requested bytes + 1, and, after removing the marker, **sum of stack bytes = exact per-type bytes**.
- Per-type counts and requested bytes are exact. Duplicate printed type names from different runtime type pointers
  are summed. Stack `samples` are byte weights, **not object counts**; this report never derives per-site object
  counts from them. A site is allocating function + allocated type; source-line variants in the same function/type
  are combined only after asserting that their causes agree.
- The headless harness's existing build-probe/metrics allocations remain in the action window. Only the explicit
  census calibration marker is subtracted. Diagnostic records are identified below; scalar boxes used by those
  diagnostics remain in B. This is the same instrumented action workload as the existing census comparisons.
- These exact-count captures execute prebuilt modules and report no timings. Timing/RSS pairs in `VALUE_TYPES.md`
  use both the shared measurement and heavy-build locks. New large outputs are on DATA1. Each raw capture is
  deleted immediately after its exact totals and stacks have been extracted.

Provenance SHA-256:

- candidate census module: `28ab2b68a6e5c7506156de0812c4d8e20f3453c1cdd8daad29501ff7888c3440`.
- published control census module: `7c0d2cf5cdef8a0f4c4bcf29413956883265cbe7545fda30027e988408c39bcf`.
- HashLink executable: `dca7f556a80f9159f4580eb5726a800277423cd48b146ca9565f849fa8db6472`.
- outer API-port patch without census harness: `af69399bea416945ae889ba05346d19774184ee23c8a8b95cb4e763177daa895`.
- outer patch including census harness: `4c5c83e3ce190c60dbd764569a2bed46418df06aef260419a8b88c6142ffef0b`.
- calibrated harness patch: `4cb30e91845b56a29f654994e5e37f36143633770aa880a0d660899f8eab71bb`.
- frozen changed-source/config/fixture manifest: `a48b8133ecc579fa8424440c85e76b69af46feac908ddb2a4fd9d824e85c8cec`.
- source-audited classification rules: `ab73034723470a524dd8d301877b5d3b577bdab147d2818ea910216097e375cd`.

The census module was built before the commit was named; all 116 changed code/config/fixture hashes were checked
against the committed source before capture. Measurement-only harness changes stay in the detached outer checkout.
Raw-window calibration and exact total checks pass for all 15 captures. Control uses the existing uncalibrated
module's exact per-type counters, so its first stack-weight byte cannot affect control totals.

## Exact totals for every action

| Scenario / action | Control objects | Control bytes | Final objects | Final bytes | Objects Δ | Bytes Δ |
|---|---:|---:|---:|---:|---:|---:|
| tab-matrix / hierarchy->sensors | 1,677 | 117,240 | 1,676 | 117,208 | -1 | -32 |
| tab-matrix / sensors->hierarchy | 1,149 | 79,656 | 1,149 | 79,656 | +0 | +0 |
| tab-matrix / console->telemetry | 1,178 | 78,584 | 1,176 | 78,520 | -2 | -64 |
| tab-matrix / telemetry->console | 1,713 | 93,208 | 1,712 | 93,176 | -1 | -32 |
| interaction / scroll-inspector | 227 | 23,072 | 227 | 23,072 | +0 | +0 |
| interaction / hover-enter | 33 | 1,296 | 33 | 1,296 | +0 | +0 |
| interaction / hover-inside | 33 | 1,296 | 33 | 1,296 | +0 | +0 |
| interaction / idle | 18 | 848 | 18 | 848 | +0 | +0 |
| interaction / idle-focused | 18 | 848 | 18 | 848 | +0 | +0 |
| interaction / hover-other | 188 | 9,744 | 187 | 9,712 | -1 | -32 |
| interaction / hover-field | 324 | 17,328 | 323 | 17,296 | -1 | -32 |
| interaction / hover-away | 259 | 12,576 | 257 | 12,512 | -2 | -64 |
| interaction / type-char | 418 | 16,384 | 418 | 16,384 | +0 | +0 |
| interaction / type-backspace | 432 | 16,992 | 432 | 16,992 | +0 | +0 |
| selection-stress / selection | 8,621 | 580,816 | 8,593 | 579,512 | -28 | -1,304 |
| **One occurrence of all 15** | **16,288** | **1,049,888** | **16,252** | **1,048,328** | **-36** | **-1,560** |

No action allocates more objects or bytes. This sum gives each action equal weight and is not a forecast of a
user session. The +0.2/+2.0 KiB refill-counter movements in hierarchy→sensors/console→telemetry correspond to
**32/64 fewer exact bytes**, not extra allocated program storage. Selection saves 28 boxes and 1,304 bytes.
See `VALUE_TYPES.md` for all alternating timing/RSS/browser pairs and module sizes.

## Cause definitions and removal queues

Every site has exactly one cause. Causes are not rounded together. Scalar/nullable scalar boxes and boxed enum
carriers are B even inside native or diagnostic calls. Map-owned backing/iterator allocations are M; ordinary
children, walking, text and string buffers are A. A mutable `LayoutStyle`, explicit `Style*Value` declaration class,
widget, `RenderNode`, layout object or structural View adapter is V, not an implicit compiler value box.
`ResolvedLayoutItem.decode` and native output buffers/record copies are N. Reactive edges/dependency records are T;
retained style/view/cache/command/history entries are R. O has an explicit model/diagnostic reason, never an
unreviewed-site fallback.

| Code | Cause | Primary next queue / limit |
|---|---|---|
| B | value boxing (struct/enum/scalar/Null) | a2 for scalar/nullable carriers; `TextEditIntent` needs deferred E3/E7; recursive `DockNode` needs fewer UI copies, not unsafe inline layout; remaining struct carriers need a value-ABI follow-up |
| M | map storage (including IntMap/StringMap/ObjectMap boxing/backing/iterators) | a2 typed standard collections; map entries/backing are still real storage, not all removable bytes |
| C | closures/environments (including captured cells) | ADR 0002 stages 3/5 stable components and callbacks; native callback/harness closures are separate follow-ups |
| A | arrays/strings/temporary collections | Stage 2 node store and stages 3/5 for rebuild scratch/children; text encoding/edit buffers require their own storage work |
| V | view rebuild/reconcile/patch machinery | Stage 2 persistent node store, stages 3/5 component model/widgets; stage-5 machinery is scheduled for deletion |
| R | retained caches/bindings | Stages 3/5 ownership/bindings; undo history and text indexes remain necessary retained state |
| T | reactive tracking | Stages 3/5 preserve readers instead of recreating edges with rebuilt widgets; already-tracked reads remain allocation-free |
| N | native bridge copies | Stage 2 avoids full layout mirror/transaction copies; query/callback value records need a separate native-value port |
| O | other, explicitly named model/diagnostic records | Other: production frame/style metrics, harness probes, application presentation/semantic/variant snapshots, text-edit records |

Queues identify the source of avoidable work, not a promise that an entire cause must become zero. In particular,
recursive enums remain boxed, retained history is useful storage, and map metadata has a real cost even after a2.

## Bytes by cause for every action

All sites contribute to this table, including those below the displayed 90% cutoff. Every row is checked against
the exact action byte total.

| Action | B | M | C | A | V | R | T | N | O | Total bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| hierarchy->sensors | 2,360 | 800 | 5,664 | 19,040 | 41,912 | 80 | 0 | 46,752 | 600 | 117,208 |
| sensors->hierarchy | 1,928 | 800 | 5,336 | 18,048 | 38,416 | 80 | 0 | 14,448 | 600 | 79,656 |
| console->telemetry | 2,096 | 800 | 5,760 | 18,960 | 42,480 | 80 | 0 | 7,744 | 600 | 78,520 |
| telemetry->console | 2,944 | 800 | 5,480 | 18,120 | 39,504 | 80 | 0 | 25,648 | 600 | 93,176 |
| scroll-inspector | 352 | 0 | 112 | 1,280 | 904 | 32 | 0 | 20,032 | 360 | 23,072 |
| hover-enter | 80 | 0 | 80 | 504 | 160 | 0 | 0 | 208 | 264 | 1,296 |
| hover-inside | 80 | 0 | 80 | 504 | 160 | 0 | 0 | 208 | 264 | 1,296 |
| idle | 0 | 0 | 80 | 504 | 0 | 0 | 0 | 0 | 264 | 848 |
| idle-focused | 0 | 0 | 80 | 504 | 0 | 0 | 0 | 0 | 264 | 848 |
| hover-other | 400 | 0 | 672 | 2,488 | 5,024 | 0 | 0 | 816 | 312 | 9,712 |
| hover-field | 992 | 0 | 672 | 7,296 | 6,800 | 408 | 0 | 816 | 312 | 17,296 |
| hover-away | 1,008 | 0 | 768 | 2,720 | 6,888 | 0 | 0 | 816 | 312 | 12,512 |
| type-char | 888 | 0 | 1,920 | 5,376 | 4,288 | 184 | 0 | 3,384 | 344 | 16,384 |
| type-backspace | 912 | 0 | 1,920 | 5,504 | 4,568 | 184 | 0 | 3,560 | 344 | 16,992 |
| selection | 1,488 | 3,504 | 66,808 | 154,464 | 320,160 | 296 | 10,144 | 21,608 | 1,040 | 579,512 |
| **Sum, one of each action** | **15,528** | **6,704** | **95,432** | **255,312** | **511,264** | **1,424** | **10,144** | **146,040** | **6,480** | **1,048,328** |

### Cause summary across all actions

| Cause | Requested bytes | Share of total |
|---|---:|---:|
| V — view rebuild/reconcile/patch machinery | 511,264 | 48.769% |
| A — arrays/strings/temporary collections | 255,312 | 24.354% |
| N — native bridge copies | 146,040 | 13.931% |
| C — closures/environments | 95,432 | 9.103% |
| B — value boxing | 15,528 | 1.481% |
| T — reactive tracking | 10,144 | 0.968% |
| M — map storage | 6,704 | 0.639% |
| O — other | 6,480 | 0.618% |
| R — retained caches/bindings | 1,424 | 0.136% |

The largest volume is reconstructed UI/layout/style objects, then arrays/strings and native layout copies. The
node store and component stages therefore address more measured bytes than scalar boxing alone. a2 still has
clear scalar/map sites; the table keeps those separate instead of assigning their storage to the larger UI cause.

## Ranked allocation sites through 90% of each action

Each table is sorted by requested bytes and includes the first site that reaches at least 90% cumulative bytes.
The remaining bytes are shown explicitly and remain classified in the cause tables. Percentages are display-only;
all bytes and cause sums use integers. Allocating functions retain their generated names so distinct closures and
adapters are not merged. These are site bytes, not estimated object counts.

### tab-matrix: hierarchy->sensors

Exact total: **1,676 objects / 117,208 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 35,616 | 35,616 | 30.387% | N | Stage 2 |
| 2 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.core.RenderNode` | 5,040 | 40,656 | 34.687% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 4,440 | 45,096 | 38.475% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 4,128 | 49,224 | 41.997% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 3,784 | 53,008 | 45.226% | V | Stage 2 + stages 3/5 |
| 6 | `haxeon.ui.LayoutTransaction.appendNode` | `<abstract>` | 3,584 | 56,592 | 48.283% | N | Stage 2 |
| 7 | `haxeon.ui.LayoutNode.add` | `array` | 2,160 | 58,752 | 50.126% | A | Stage 2 + stages 3/5 |
| 8 | `haxeon.ui.core.RenderNode.add` | `array` | 2,160 | 60,912 | 51.969% | A | Stage 2 + stages 3/5 |
| 9 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.LayoutStyle` | 2,064 | 62,976 | 53.730% | V | Stage 2 + stages 3/5 |
| 10 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.LayoutStyle` | 2,064 | 65,040 | 55.491% | V | Stage 2 + stages 3/5 |
| 11 | `haxeon.ui.widgets.layout.SplitView.paneStyle` | `haxeon.ui.LayoutStyle` | 2,064 | 67,104 | 57.252% | V | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.core.RenderNode` | 1,680 | 68,784 | 58.685% | V | Stage 2 + stages 3/5 |
| 13 | `NativeKitUI.nkui_layout_session_submit_slice` | `<abstract>` | 1,232 | 70,016 | 59.737% | N | Stage 2 |
| 14 | `$generic:nkui_layout_measure_result.new[]<>` | `<abstract>` | 1,176 | 71,192 | 60.740% | N | Other: FFI query values |
| 15 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 1,104 | 72,296 | 61.682% | N | Stage 2 |
| 16 | `haxeon.ui.docking.DockNodeTools.normalize` | `array` | 1,080 | 73,376 | 62.603% | A | Stage 2 + stages 3/5 |
| 17 | `haxeon.ui.widgets.layout.SplitView.defaultStyle` | `haxeon.ui.LayoutStyle` | 1,032 | 74,408 | 63.484% | V | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.widgets.layout.SplitView.new` | `haxeon.ui.LayoutStyle` | 1,032 | 75,440 | 64.364% | V | Stage 2 + stages 3/5 |
| 19 | `haxeon.ui.core.HitTest.pathTo` | `array` | 960 | 76,400 | 65.183% | A | Stage 2 + stages 3/5 |
| 20 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 896 | 77,296 | 65.948% | V | Stage 2 + stages 3/5 |
| 21 | `$lambda:haxeon.ui.LayoutSession.refreshMeasureCallback:refreshMeasureCallback#nkui_layout_measure_callbackCallback(0)~3CB3D6E0@590B886C#0` | `haxeon.ui.LayoutMeasureConstraints` | 840 | 78,136 | 66.664% | N | Other: FFI query values |
| 22 | `haxeon.ui.LayoutSession.measureNode` | `haxeon.ui.LayoutMeasureResult` | 840 | 78,976 | 67.381% | N | Other: FFI query values |
| 23 | `haxeon.ui.LayoutTransaction.appendNode` | `bytes` | 816 | 79,792 | 68.077% | N | Stage 2 |
| 24 | `haxeon.ui.core.StateStore.endFrame` | `array` | 816 | 80,608 | 68.773% | A | Stage 2 + stages 3/5 |
| 25 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `<abstract>` | 800 | 81,408 | 69.456% | M | a2 |
| 26 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 768 | 82,176 | 70.111% | A | Stage 2 + stages 3/5 |
| 27 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 720 | 82,896 | 70.726% | A | Stage 2 + stages 3/5 |
| 28 | `NativeKitUI.nkui_layout_session_submit_slice` | `realtime_bytes` | 704 | 83,600 | 71.326% | N | Stage 2 |
| 29 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 688 | 84,288 | 71.913% | V | Stage 2 + stages 3/5 |
| 30 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.layout.SizedBox.new` | `haxeon.ui.LayoutStyle` | 688 | 84,976 | 72.500% | V | Stage 2 + stages 3/5 |
| 31 | `haxeon.ui.widgets.layout.Stack.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 85,664 | 73.087% | V | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.widgets.layout.SplitView.installDividerHandlers` | `(void (haxeon.ui.core.UiEvent))` | 672 | 86,336 | 73.661% | C | Stages 3/5 |
| 33 | `haxeon.ui.docking.DockNodeTools.normalize` | `enum<haxeon.ui.docking.DockNode>` | 624 | 86,960 | 74.193% | B | Other: dock-tree copies |
| 34 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 576 | 87,536 | 74.684% | V | Stage 2 + stages 3/5 |
| 35 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 560 | 88,096 | 75.162% | V | Stage 2 + stages 3/5 |
| 36 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.core.RenderNode` | 560 | 88,656 | 75.640% | V | Stage 2 + stages 3/5 |
| 37 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.core.RenderNode` | 560 | 89,216 | 76.118% | V | Stage 2 + stages 3/5 |
| 38 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.core.RenderNode` | 560 | 89,776 | 76.595% | V | Stage 2 + stages 3/5 |
| 39 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 560 | 90,336 | 77.073% | V | Stage 2 + stages 3/5 |
| 40 | `haxeon.ui.docking.DockNodeTools.clone` | `enum<haxeon.ui.docking.DockNode>` | 480 | 90,816 | 77.483% | B | Other: dock-tree copies |
| 41 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `bytes` | 472 | 91,288 | 77.885% | A | Stage 2 + stages 3/5 |
| 42 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 464 | 91,752 | 78.281% | A | Stage 2 + stages 3/5 |
| 43 | `haxeon.ui.widgets.docking.DockPanelCache.retain` | `array` | 448 | 92,200 | 78.664% | A | Stage 2 + stages 3/5 |
| 44 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `array` | 432 | 92,632 | 79.032% | A | Stage 2 + stages 3/5 |
| 45 | `haxeon.ui.docking.DockNodeTools.clone` | `array` | 432 | 93,064 | 79.401% | A | Stage 2 + stages 3/5 |
| 46 | `robotkit.world.RobotWorld.robotIds` | `array` | 432 | 93,496 | 79.769% | A | Stage 2 + stages 3/5 |
| 47 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `bytes` | 416 | 93,912 | 80.124% | A | Stage 2 + stages 3/5 |
| 48 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.semantics.Semantics` | 408 | 94,320 | 80.472% | V | Stage 2 + stages 3/5 |
| 49 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitView` | 408 | 94,728 | 80.820% | V | Stage 2 + stages 3/5 |
| 50 | `NativeKitUI.nkui_layout_session_submit_slice` | `i32` | 384 | 95,112 | 81.148% | B | a2 |
| 51 | `haxeon.ui.style.StyleResolver.keyHash` | `bytes` | 384 | 95,496 | 81.476% | A | Stage 2 + stages 3/5 |
| 52 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `String` | 384 | 95,880 | 81.803% | A | Stage 2 + stages 3/5 |
| 53 | `app.ReferenceEditorApp.fillStyle` | `haxeon.ui.LayoutStyle` | 344 | 96,224 | 82.097% | V | Stage 2 + stages 3/5 |
| 54 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 344 | 96,568 | 82.390% | V | Stage 2 + stages 3/5 |
| 55 | `haxeon.ui.widgets.docking.DockWorkspace.defaultStyle` | `haxeon.ui.LayoutStyle` | 344 | 96,912 | 82.684% | V | Stage 2 + stages 3/5 |
| 56 | `haxeon.ui.widgets.layout.AppShell.defaultBodyStyle` | `haxeon.ui.LayoutStyle` | 344 | 97,256 | 82.977% | V | Stage 2 + stages 3/5 |
| 57 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `array` | 336 | 97,592 | 83.264% | A | Stage 2 + stages 3/5 |
| 58 | `haxeon.ui.core.EventDispatcher.dispatchDirect` | `haxeon.ui.core.UiEvent` | 320 | 97,912 | 83.537% | V | Stage 2 + stages 3/5 |
| 59 | `haxeon.ui.core.EventDispatcher.pointerUp` | `haxeon.ui.core.UiEvent` | 320 | 98,232 | 83.810% | V | Stage 2 + stages 3/5 |
| 60 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 312 | 98,544 | 84.076% | N | Other: FFI query values |
| 61 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitViewOptions` | 312 | 98,856 | 84.342% | V | Stage 2 + stages 3/5 |
| 62 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `array` | 288 | 99,144 | 84.588% | A | Stage 2 + stages 3/5 |
| 63 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `array` | 288 | 99,432 | 84.834% | A | Stage 2 + stages 3/5 |
| 64 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `array` | 288 | 99,720 | 85.080% | A | Stage 2 + stages 3/5 |
| 65 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 288 | 100,008 | 85.325% | A | Stage 2 + stages 3/5 |
| 66 | `haxeon.ui.widgets.docking.DockWorkspace.build` | `bytes` | 288 | 100,296 | 85.571% | A | Stage 2 + stages 3/5 |
| 67 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 280 | 100,576 | 85.810% | V | Stage 2 + stages 3/5 |
| 68 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `haxeon.ui.core.RenderNode` | 280 | 100,856 | 86.049% | V | Stage 2 + stages 3/5 |
| 69 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 101,136 | 86.288% | V | Stage 2 + stages 3/5 |
| 70 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 272 | 101,408 | 86.520% | A | Stage 2 + stages 3/5 |
| 71 | `app.ReferenceEditorApp.view` | `haxeon.ui.widgets.layout.StackChild` | 272 | 101,680 | 86.752% | V | Stage 2 + stages 3/5 |
| 72 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 272 | 101,952 | 86.984% | V | Stage 2 + stages 3/5 |
| 73 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 102,216 | 87.209% | O | Other |
| 74 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `bytes` | 264 | 102,480 | 87.434% | A | Stage 2 + stages 3/5 |
| 75 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `bytes` | 264 | 102,744 | 87.660% | A | Stage 2 + stages 3/5 |
| 76 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `haxeon.ui.widgets.docking.DockPaneView` | 256 | 103,000 | 87.878% | V | Stage 2 + stages 3/5 |
| 77 | `haxeon.ui.docking.DockNodeTools.remove` | `enum<haxeon.ui.docking.DockNode>` | 240 | 103,240 | 88.083% | B | Other: dock-tree copies |
| 78 | `haxeon.ui.widgets.docking.DockWorkspace.buildNode` | `$lambda-env:haxeon.ui.widgets.docking.DockWorkspace.buildNode:buildNode#return/paneView(6)@3BC502D4#1` | 240 | 103,480 | 88.287% | C | Stages 3/5 |
| 79 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.beginFrame` | `array` | 224 | 103,704 | 88.479% | A | Stage 2 + stages 3/5 |
| 80 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `String` | 216 | 103,920 | 88.663% | A | Stage 2 + stages 3/5 |
| 81 | `app.ApplicationSimulation.captureOwnerSnapshot` | `array` | 216 | 104,136 | 88.847% | A | Stage 2 + stages 3/5 |
| 82 | `haxeon.ui.docking.DockNodeTools.remove` | `array` | 216 | 104,352 | 89.031% | A | Stage 2 + stages 3/5 |
| 83 | `$lambda:tests.HeadlessEditorProfile.submit:submit#buildProbe=@305D61CA#0` | `bytes` | 208 | 104,560 | 89.209% | A | Stage 2 + stages 3/5 |
| 84 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `(haxeon.ui.core.RenderNode ())` | 192 | 104,752 | 89.373% | C | Stages 3/5 |
| 85 | `app.ReferenceEditorApp.view` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 192 | 104,944 | 89.537% | V | Stage 2 + stages 3/5 |
| 86 | `haxeon.ui.core.BuildContext.claimRetainedTree` | `(void (haxeon.ui.core.RenderNode))` | 192 | 105,136 | 89.700% | C | Stages 3/5 |
| 87 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 176 | 105,312 | 89.851% | V | Stage 2 + stages 3/5 |
| 88 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.widgets.Icon` | 176 | 105,488 | 90.001% | V | Stage 2 + stages 3/5 |

Displayed sites: 105,488 bytes. Classified remainder below the cutoff: **11,720 bytes**.

### tab-matrix: sensors->hierarchy

Exact total: **1,149 objects / 79,656 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 12,936 | 12,936 | 16.240% | N | Stage 2 |
| 2 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.core.RenderNode` | 5,040 | 17,976 | 22.567% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 3,960 | 21,936 | 27.538% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 3,784 | 25,720 | 32.289% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 3,440 | 29,160 | 36.607% | V | Stage 2 + stages 3/5 |
| 6 | `haxeon.ui.LayoutNode.add` | `array` | 2,088 | 31,248 | 39.229% | A | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.core.RenderNode.add` | `array` | 2,088 | 33,336 | 41.850% | A | Stage 2 + stages 3/5 |
| 8 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.LayoutStyle` | 2,064 | 35,400 | 44.441% | V | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.LayoutStyle` | 2,064 | 37,464 | 47.032% | V | Stage 2 + stages 3/5 |
| 10 | `haxeon.ui.widgets.layout.SplitView.paneStyle` | `haxeon.ui.LayoutStyle` | 2,064 | 39,528 | 49.623% | V | Stage 2 + stages 3/5 |
| 11 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.core.RenderNode` | 1,680 | 41,208 | 51.732% | V | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.docking.DockNodeTools.normalize` | `array` | 1,080 | 42,288 | 53.088% | A | Stage 2 + stages 3/5 |
| 13 | `haxeon.ui.widgets.layout.SplitView.defaultStyle` | `haxeon.ui.LayoutStyle` | 1,032 | 43,320 | 54.384% | V | Stage 2 + stages 3/5 |
| 14 | `haxeon.ui.widgets.layout.SplitView.new` | `haxeon.ui.LayoutStyle` | 1,032 | 44,352 | 55.679% | V | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.core.HitTest.pathTo` | `array` | 960 | 45,312 | 56.885% | A | Stage 2 + stages 3/5 |
| 16 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 832 | 46,144 | 57.929% | V | Stage 2 + stages 3/5 |
| 17 | `haxeon.ui.core.StateStore.endFrame` | `array` | 816 | 46,960 | 58.954% | A | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `<abstract>` | 800 | 47,760 | 59.958% | M | a2 |
| 19 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 696 | 48,456 | 60.832% | A | Stage 2 + stages 3/5 |
| 20 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.layout.SizedBox.new` | `haxeon.ui.LayoutStyle` | 688 | 49,144 | 61.695% | V | Stage 2 + stages 3/5 |
| 21 | `haxeon.ui.widgets.layout.Stack.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 49,832 | 62.559% | V | Stage 2 + stages 3/5 |
| 22 | `haxeon.ui.widgets.layout.SplitView.installDividerHandlers` | `(void (haxeon.ui.core.UiEvent))` | 672 | 50,504 | 63.403% | C | Stages 3/5 |
| 23 | `haxeon.ui.docking.DockNodeTools.normalize` | `enum<haxeon.ui.docking.DockNode>` | 624 | 51,128 | 64.186% | B | Other: dock-tree copies |
| 24 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 576 | 51,704 | 64.909% | A | Stage 2 + stages 3/5 |
| 25 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.core.RenderNode` | 560 | 52,264 | 65.612% | V | Stage 2 + stages 3/5 |
| 26 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.core.RenderNode` | 560 | 52,824 | 66.315% | V | Stage 2 + stages 3/5 |
| 27 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.core.RenderNode` | 560 | 53,384 | 67.018% | V | Stage 2 + stages 3/5 |
| 28 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 528 | 53,912 | 67.681% | V | Stage 2 + stages 3/5 |
| 29 | `haxeon.ui.docking.DockNodeTools.clone` | `enum<haxeon.ui.docking.DockNode>` | 480 | 54,392 | 68.284% | B | Other: dock-tree copies |
| 30 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `bytes` | 472 | 54,864 | 68.876% | A | Stage 2 + stages 3/5 |
| 31 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 464 | 55,328 | 69.459% | A | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.widgets.docking.DockPanelCache.retain` | `array` | 448 | 55,776 | 70.021% | A | Stage 2 + stages 3/5 |
| 33 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `array` | 432 | 56,208 | 70.563% | A | Stage 2 + stages 3/5 |
| 34 | `haxeon.ui.docking.DockNodeTools.clone` | `array` | 432 | 56,640 | 71.106% | A | Stage 2 + stages 3/5 |
| 35 | `robotkit.world.RobotWorld.robotIds` | `array` | 432 | 57,072 | 71.648% | A | Stage 2 + stages 3/5 |
| 36 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `bytes` | 416 | 57,488 | 72.170% | A | Stage 2 + stages 3/5 |
| 37 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.semantics.Semantics` | 408 | 57,896 | 72.683% | V | Stage 2 + stages 3/5 |
| 38 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitView` | 408 | 58,304 | 73.195% | V | Stage 2 + stages 3/5 |
| 39 | `haxeon.ui.LayoutTransaction.appendNode` | `<abstract>` | 392 | 58,696 | 73.687% | N | Stage 2 |
| 40 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `String` | 384 | 59,080 | 74.169% | A | Stage 2 + stages 3/5 |
| 41 | `haxeon.ui.style.StyleResolver.keyHash` | `bytes` | 352 | 59,432 | 74.611% | A | Stage 2 + stages 3/5 |
| 42 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 344 | 59,776 | 75.043% | V | Stage 2 + stages 3/5 |
| 43 | `app.ReferenceEditorApp.fillStyle` | `haxeon.ui.LayoutStyle` | 344 | 60,120 | 75.475% | V | Stage 2 + stages 3/5 |
| 44 | `haxeon.ui.widgets.docking.DockWorkspace.defaultStyle` | `haxeon.ui.LayoutStyle` | 344 | 60,464 | 75.906% | V | Stage 2 + stages 3/5 |
| 45 | `haxeon.ui.widgets.layout.AppShell.defaultBodyStyle` | `haxeon.ui.LayoutStyle` | 344 | 60,808 | 76.338% | V | Stage 2 + stages 3/5 |
| 46 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `array` | 336 | 61,144 | 76.760% | A | Stage 2 + stages 3/5 |
| 47 | `haxeon.ui.core.EventDispatcher.dispatchDirect` | `haxeon.ui.core.UiEvent` | 320 | 61,464 | 77.162% | V | Stage 2 + stages 3/5 |
| 48 | `haxeon.ui.core.EventDispatcher.pointerUp` | `haxeon.ui.core.UiEvent` | 320 | 61,784 | 77.564% | V | Stage 2 + stages 3/5 |
| 49 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 312 | 62,096 | 77.955% | N | Other: FFI query values |
| 50 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitViewOptions` | 312 | 62,408 | 78.347% | V | Stage 2 + stages 3/5 |
| 51 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `array` | 288 | 62,696 | 78.708% | A | Stage 2 + stages 3/5 |
| 52 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `array` | 288 | 62,984 | 79.070% | A | Stage 2 + stages 3/5 |
| 53 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `array` | 288 | 63,272 | 79.432% | A | Stage 2 + stages 3/5 |
| 54 | `haxeon.ui.widgets.docking.DockWorkspace.build` | `bytes` | 288 | 63,560 | 79.793% | A | Stage 2 + stages 3/5 |
| 55 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 280 | 63,840 | 80.145% | V | Stage 2 + stages 3/5 |
| 56 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `haxeon.ui.core.RenderNode` | 280 | 64,120 | 80.496% | V | Stage 2 + stages 3/5 |
| 57 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 64,400 | 80.848% | V | Stage 2 + stages 3/5 |
| 58 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 280 | 64,680 | 81.199% | V | Stage 2 + stages 3/5 |
| 59 | `app.ReferenceEditorApp.view` | `haxeon.ui.widgets.layout.StackChild` | 272 | 64,952 | 81.541% | V | Stage 2 + stages 3/5 |
| 60 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 65,216 | 81.872% | O | Other |
| 61 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `bytes` | 264 | 65,480 | 82.203% | A | Stage 2 + stages 3/5 |
| 62 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `bytes` | 264 | 65,744 | 82.535% | A | Stage 2 + stages 3/5 |
| 63 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `haxeon.ui.widgets.docking.DockPaneView` | 256 | 66,000 | 82.856% | V | Stage 2 + stages 3/5 |
| 64 | `haxeon.ui.docking.DockNodeTools.remove` | `enum<haxeon.ui.docking.DockNode>` | 240 | 66,240 | 83.158% | B | Other: dock-tree copies |
| 65 | `haxeon.ui.widgets.docking.DockWorkspace.buildNode` | `$lambda-env:haxeon.ui.widgets.docking.DockWorkspace.buildNode:buildNode#return/paneView(6)@3BC502D4#1` | 240 | 66,480 | 83.459% | C | Stages 3/5 |
| 66 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.beginFrame` | `array` | 224 | 66,704 | 83.740% | A | Stage 2 + stages 3/5 |
| 67 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `String` | 216 | 66,920 | 84.011% | A | Stage 2 + stages 3/5 |
| 68 | `app.ApplicationSimulation.captureOwnerSnapshot` | `array` | 216 | 67,136 | 84.282% | A | Stage 2 + stages 3/5 |
| 69 | `haxeon.ui.docking.DockNodeTools.remove` | `array` | 216 | 67,352 | 84.554% | A | Stage 2 + stages 3/5 |
| 70 | `$lambda:tests.HeadlessEditorProfile.submit:submit#buildProbe=@305D61CA#0` | `bytes` | 208 | 67,560 | 84.815% | A | Stage 2 + stages 3/5 |
| 71 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `(haxeon.ui.core.RenderNode ())` | 192 | 67,752 | 85.056% | C | Stages 3/5 |
| 72 | `app.ReferenceEditorApp.view` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 192 | 67,944 | 85.297% | V | Stage 2 + stages 3/5 |
| 73 | `haxeon.ui.core.BuildContext.claimRetainedTree` | `(void (haxeon.ui.core.RenderNode))` | 192 | 68,136 | 85.538% | C | Stages 3/5 |
| 74 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `$lambda-env:$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0:build#onPaint(0)@6785BEF6#0` | 168 | 68,304 | 85.749% | C | Stages 3/5 |
| 75 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.style.StyleTarget` | 168 | 68,472 | 85.960% | V | Stage 2 + stages 3/5 |
| 76 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 168 | 68,640 | 86.171% | N | Other: FFI query values |
| 77 | `haxeon.ui.core.EventDispatcher.dispatchOutsidePointerDown` | `haxeon.ui.core.UiEvent` | 160 | 68,800 | 86.371% | V | Stage 2 + stages 3/5 |
| 78 | `haxeon.ui.core.EventDispatcher.pointerDown` | `haxeon.ui.core.UiEvent` | 160 | 68,960 | 86.572% | V | Stage 2 + stages 3/5 |
| 79 | `haxeon.ui.core.RetainedView.build` | `bytes` | 152 | 69,112 | 86.763% | A | Stage 2 + stages 3/5 |
| 80 | `$lambda:haxeon.ui.widgets.layout.AppShell.build:build#return/withScope(1)@69FFC9EA#0` | `array` | 144 | 69,256 | 86.944% | A | Stage 2 + stages 3/5 |
| 81 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `array` | 144 | 69,400 | 87.125% | A | Stage 2 + stages 3/5 |
| 82 | `app.ReferenceEditorApp.view` | `array` | 144 | 69,544 | 87.305% | A | Stage 2 + stages 3/5 |
| 83 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 144 | 69,688 | 87.486% | B | a2 |
| 84 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 144 | 69,832 | 87.667% | A | Stage 2 + stages 3/5 |
| 85 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `String` | 144 | 69,976 | 87.848% | A | Stage 2 + stages 3/5 |
| 86 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.new` | `array` | 144 | 70,120 | 88.029% | A | Stage 2 + stages 3/5 |
| 87 | `haxeon.ui.widgets.layout.Stack.new` | `array` | 144 | 70,264 | 88.209% | A | Stage 2 + stages 3/5 |
| 88 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 136 | 70,400 | 88.380% | A | Stage 2 + stages 3/5 |
| 89 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 136 | 70,536 | 88.551% | V | Stage 2 + stages 3/5 |
| 90 | `$lambda:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | `(haxeon.ui.core.RenderNode ())` | 128 | 70,664 | 88.711% | C | Stages 3/5 |
| 91 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `(haxeon.ui.core.RenderNode ())` | 128 | 70,792 | 88.872% | C | Stages 3/5 |
| 92 | `app.ReferenceEditorApp.view` | `haxeon.ui.widgets.docking.DockWorkspace` | 128 | 70,920 | 89.033% | V | Stage 2 + stages 3/5 |
| 93 | `haxeon.ui.widgets.docking.DockWorkspace.build` | `array` | 128 | 71,048 | 89.194% | A | Stage 2 + stages 3/5 |
| 94 | `haxeon.ui.widgets.docking.DockWorkspace.buildNode` | `(virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))> ())` | 128 | 71,176 | 89.354% | C | Stages 3/5 |
| 95 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 128 | 71,304 | 89.515% | V | Stage 2 + stages 3/5 |
| 96 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.style.StyleTarget` | 112 | 71,416 | 89.656% | V | Stage 2 + stages 3/5 |
| 97 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.style.StyleTarget` | 112 | 71,528 | 89.796% | V | Stage 2 + stages 3/5 |
| 98 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.style.StyleTarget` | 112 | 71,640 | 89.937% | V | Stage 2 + stages 3/5 |
| 99 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 71,752 | 90.077% | N | Other: FFI query values |

Displayed sites: 71,752 bytes. Classified remainder below the cutoff: **7,904 bytes**.

### tab-matrix: console->telemetry

Exact total: **1,176 objects / 78,520 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 6,384 | 6,384 | 8.130% | N | Stage 2 |
| 2 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.core.RenderNode` | 5,040 | 11,424 | 14.549% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 4,440 | 15,864 | 20.204% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 4,128 | 19,992 | 25.461% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 3,440 | 23,432 | 29.842% | V | Stage 2 + stages 3/5 |
| 6 | `haxeon.ui.LayoutNode.add` | `array` | 2,160 | 25,592 | 32.593% | A | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.core.RenderNode.add` | `array` | 2,160 | 27,752 | 35.344% | A | Stage 2 + stages 3/5 |
| 8 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.LayoutStyle` | 2,064 | 29,816 | 37.972% | V | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.LayoutStyle` | 2,064 | 31,880 | 40.601% | V | Stage 2 + stages 3/5 |
| 10 | `haxeon.ui.widgets.layout.SplitView.paneStyle` | `haxeon.ui.LayoutStyle` | 2,064 | 33,944 | 43.230% | V | Stage 2 + stages 3/5 |
| 11 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.core.RenderNode` | 1,680 | 35,624 | 45.369% | V | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.docking.DockNodeTools.normalize` | `array` | 1,080 | 36,704 | 46.745% | A | Stage 2 + stages 3/5 |
| 13 | `haxeon.ui.widgets.layout.SplitView.defaultStyle` | `haxeon.ui.LayoutStyle` | 1,032 | 37,736 | 48.059% | V | Stage 2 + stages 3/5 |
| 14 | `haxeon.ui.widgets.layout.SplitView.new` | `haxeon.ui.LayoutStyle` | 1,032 | 38,768 | 49.373% | V | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.core.HitTest.pathTo` | `array` | 960 | 39,728 | 50.596% | A | Stage 2 + stages 3/5 |
| 16 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 896 | 40,624 | 51.737% | V | Stage 2 + stages 3/5 |
| 17 | `haxeon.ui.core.StateStore.endFrame` | `array` | 816 | 41,440 | 52.776% | A | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `<abstract>` | 800 | 42,240 | 53.795% | M | a2 |
| 19 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 768 | 43,008 | 54.773% | A | Stage 2 + stages 3/5 |
| 20 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 720 | 43,728 | 55.690% | A | Stage 2 + stages 3/5 |
| 21 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 688 | 44,416 | 56.566% | V | Stage 2 + stages 3/5 |
| 22 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.layout.SizedBox.new` | `haxeon.ui.LayoutStyle` | 688 | 45,104 | 57.443% | V | Stage 2 + stages 3/5 |
| 23 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 688 | 45,792 | 58.319% | V | Stage 2 + stages 3/5 |
| 24 | `haxeon.ui.widgets.layout.Stack.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 46,480 | 59.195% | V | Stage 2 + stages 3/5 |
| 25 | `haxeon.ui.widgets.layout.SplitView.installDividerHandlers` | `(void (haxeon.ui.core.UiEvent))` | 672 | 47,152 | 60.051% | C | Stages 3/5 |
| 26 | `haxeon.ui.docking.DockNodeTools.normalize` | `enum<haxeon.ui.docking.DockNode>` | 624 | 47,776 | 60.846% | B | Other: dock-tree copies |
| 27 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 608 | 48,384 | 61.620% | A | Stage 2 + stages 3/5 |
| 28 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 576 | 48,960 | 62.354% | V | Stage 2 + stages 3/5 |
| 29 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 560 | 49,520 | 63.067% | V | Stage 2 + stages 3/5 |
| 30 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 560 | 50,080 | 63.780% | V | Stage 2 + stages 3/5 |
| 31 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.core.RenderNode` | 560 | 50,640 | 64.493% | V | Stage 2 + stages 3/5 |
| 32 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.core.RenderNode` | 560 | 51,200 | 65.206% | V | Stage 2 + stages 3/5 |
| 33 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.core.RenderNode` | 560 | 51,760 | 65.920% | V | Stage 2 + stages 3/5 |
| 34 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 560 | 52,320 | 66.633% | V | Stage 2 + stages 3/5 |
| 35 | `haxeon.ui.docking.DockNodeTools.clone` | `enum<haxeon.ui.docking.DockNode>` | 480 | 52,800 | 67.244% | B | Other: dock-tree copies |
| 36 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `bytes` | 472 | 53,272 | 67.845% | A | Stage 2 + stages 3/5 |
| 37 | `haxeon.ui.widgets.docking.DockPanelCache.retain` | `array` | 448 | 53,720 | 68.416% | A | Stage 2 + stages 3/5 |
| 38 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `array` | 432 | 54,152 | 68.966% | A | Stage 2 + stages 3/5 |
| 39 | `haxeon.ui.docking.DockNodeTools.clone` | `array` | 432 | 54,584 | 69.516% | A | Stage 2 + stages 3/5 |
| 40 | `robotkit.world.RobotWorld.robotIds` | `array` | 432 | 55,016 | 70.066% | A | Stage 2 + stages 3/5 |
| 41 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `bytes` | 416 | 55,432 | 70.596% | A | Stage 2 + stages 3/5 |
| 42 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.semantics.Semantics` | 408 | 55,840 | 71.116% | V | Stage 2 + stages 3/5 |
| 43 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitView` | 408 | 56,248 | 71.635% | V | Stage 2 + stages 3/5 |
| 44 | `haxeon.ui.style.StyleResolver.keyHash` | `bytes` | 384 | 56,632 | 72.124% | A | Stage 2 + stages 3/5 |
| 45 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `String` | 384 | 57,016 | 72.613% | A | Stage 2 + stages 3/5 |
| 46 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 352 | 57,368 | 73.062% | V | Stage 2 + stages 3/5 |
| 47 | `app.ReferenceEditorApp.fillStyle` | `haxeon.ui.LayoutStyle` | 344 | 57,712 | 73.500% | V | Stage 2 + stages 3/5 |
| 48 | `haxeon.ui.widgets.docking.DockWorkspace.defaultStyle` | `haxeon.ui.LayoutStyle` | 344 | 58,056 | 73.938% | V | Stage 2 + stages 3/5 |
| 49 | `haxeon.ui.widgets.layout.AppShell.defaultBodyStyle` | `haxeon.ui.LayoutStyle` | 344 | 58,400 | 74.376% | V | Stage 2 + stages 3/5 |
| 50 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `array` | 336 | 58,736 | 74.804% | A | Stage 2 + stages 3/5 |
| 51 | `haxeon.ui.core.EventDispatcher.dispatchDirect` | `haxeon.ui.core.UiEvent` | 320 | 59,056 | 75.211% | V | Stage 2 + stages 3/5 |
| 52 | `haxeon.ui.core.EventDispatcher.pointerUp` | `haxeon.ui.core.UiEvent` | 320 | 59,376 | 75.619% | V | Stage 2 + stages 3/5 |
| 53 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 312 | 59,688 | 76.016% | N | Other: FFI query values |
| 54 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitViewOptions` | 312 | 60,000 | 76.414% | V | Stage 2 + stages 3/5 |
| 55 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `array` | 288 | 60,288 | 76.780% | A | Stage 2 + stages 3/5 |
| 56 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `array` | 288 | 60,576 | 77.147% | A | Stage 2 + stages 3/5 |
| 57 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `array` | 288 | 60,864 | 77.514% | A | Stage 2 + stages 3/5 |
| 58 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 288 | 61,152 | 77.881% | A | Stage 2 + stages 3/5 |
| 59 | `haxeon.ui.widgets.docking.DockWorkspace.build` | `bytes` | 288 | 61,440 | 78.248% | A | Stage 2 + stages 3/5 |
| 60 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `haxeon.ui.core.RenderNode` | 280 | 61,720 | 78.604% | V | Stage 2 + stages 3/5 |
| 61 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 62,000 | 78.961% | V | Stage 2 + stages 3/5 |
| 62 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 272 | 62,272 | 79.307% | A | Stage 2 + stages 3/5 |
| 63 | `app.ReferenceEditorApp.view` | `haxeon.ui.widgets.layout.StackChild` | 272 | 62,544 | 79.654% | V | Stage 2 + stages 3/5 |
| 64 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 272 | 62,816 | 80.000% | V | Stage 2 + stages 3/5 |
| 65 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 63,080 | 80.336% | O | Other |
| 66 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `bytes` | 264 | 63,344 | 80.672% | A | Stage 2 + stages 3/5 |
| 67 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `bytes` | 264 | 63,608 | 81.009% | A | Stage 2 + stages 3/5 |
| 68 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `haxeon.ui.widgets.docking.DockPaneView` | 256 | 63,864 | 81.335% | V | Stage 2 + stages 3/5 |
| 69 | `haxeon.ui.docking.DockNodeTools.remove` | `enum<haxeon.ui.docking.DockNode>` | 240 | 64,104 | 81.640% | B | Other: dock-tree copies |
| 70 | `haxeon.ui.widgets.docking.DockWorkspace.buildNode` | `$lambda-env:haxeon.ui.widgets.docking.DockWorkspace.buildNode:buildNode#return/paneView(6)@3BC502D4#1` | 240 | 64,344 | 81.946% | C | Stages 3/5 |
| 71 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.beginFrame` | `array` | 224 | 64,568 | 82.231% | A | Stage 2 + stages 3/5 |
| 72 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `String` | 216 | 64,784 | 82.506% | A | Stage 2 + stages 3/5 |
| 73 | `app.ApplicationSimulation.captureOwnerSnapshot` | `array` | 216 | 65,000 | 82.781% | A | Stage 2 + stages 3/5 |
| 74 | `haxeon.ui.docking.DockNodeTools.remove` | `array` | 216 | 65,216 | 83.057% | A | Stage 2 + stages 3/5 |
| 75 | `$lambda:tests.HeadlessEditorProfile.submit:submit#buildProbe=@305D61CA#0` | `bytes` | 208 | 65,424 | 83.321% | A | Stage 2 + stages 3/5 |
| 76 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.TextStyleOverride` | 192 | 65,616 | 83.566% | V | Stage 2 + stages 3/5 |
| 77 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `(haxeon.ui.core.RenderNode ())` | 192 | 65,808 | 83.810% | C | Stages 3/5 |
| 78 | `app.ReferenceEditorApp.view` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 192 | 66,000 | 84.055% | V | Stage 2 + stages 3/5 |
| 79 | `haxeon.ui.core.BuildContext.claimRetainedTree` | `(void (haxeon.ui.core.RenderNode))` | 192 | 66,192 | 84.300% | C | Stages 3/5 |
| 80 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.widgets.Icon` | 176 | 66,368 | 84.524% | V | Stage 2 + stages 3/5 |
| 81 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `$lambda-env:$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0:build#onPaint(0)@6785BEF6#0` | 168 | 66,536 | 84.738% | C | Stages 3/5 |
| 82 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.style.StyleTarget` | 168 | 66,704 | 84.952% | V | Stage 2 + stages 3/5 |
| 83 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 168 | 66,872 | 85.166% | N | Other: FFI query values |
| 84 | `haxeon.ui.LayoutTransaction.appendNode` | `<abstract>` | 168 | 67,040 | 85.380% | N | Stage 2 |
| 85 | `haxeon.ui.core.EventDispatcher.dispatchOutsidePointerDown` | `haxeon.ui.core.UiEvent` | 160 | 67,200 | 85.583% | V | Stage 2 + stages 3/5 |
| 86 | `haxeon.ui.core.EventDispatcher.pointerDown` | `haxeon.ui.core.UiEvent` | 160 | 67,360 | 85.787% | V | Stage 2 + stages 3/5 |
| 87 | `haxeon.ui.core.RetainedView.build` | `bytes` | 152 | 67,512 | 85.981% | A | Stage 2 + stages 3/5 |
| 88 | `$lambda:haxeon.ui.widgets.layout.AppShell.build:build#return/withScope(1)@69FFC9EA#0` | `array` | 144 | 67,656 | 86.164% | A | Stage 2 + stages 3/5 |
| 89 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `array` | 144 | 67,800 | 86.347% | A | Stage 2 + stages 3/5 |
| 90 | `app.ReferenceEditorApp.view` | `array` | 144 | 67,944 | 86.531% | A | Stage 2 + stages 3/5 |
| 91 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 144 | 68,088 | 86.714% | B | a2 |
| 92 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `String` | 144 | 68,232 | 86.898% | A | Stage 2 + stages 3/5 |
| 93 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.new` | `array` | 144 | 68,376 | 87.081% | A | Stage 2 + stages 3/5 |
| 94 | `haxeon.ui.widgets.layout.Stack.new` | `array` | 144 | 68,520 | 87.264% | A | Stage 2 + stages 3/5 |
| 95 | `$lambda:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | `(haxeon.ui.core.RenderNode ())` | 128 | 68,648 | 87.427% | C | Stages 3/5 |
| 96 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `(haxeon.ui.core.RenderNode ())` | 128 | 68,776 | 87.590% | C | Stages 3/5 |
| 97 | `app.ReferenceEditorApp.view` | `haxeon.ui.widgets.docking.DockWorkspace` | 128 | 68,904 | 87.753% | V | Stage 2 + stages 3/5 |
| 98 | `haxeon.ui.widgets.controls.Button.buildButton` | `$lambda-env:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | 128 | 69,032 | 87.916% | C | Stages 3/5 |
| 99 | `haxeon.ui.widgets.controls.Button.buildButton` | `(haxeon.ui.core.RenderNode ())` | 128 | 69,160 | 88.079% | C | Stages 3/5 |
| 100 | `haxeon.ui.widgets.docking.DockWorkspace.build` | `array` | 128 | 69,288 | 88.242% | A | Stage 2 + stages 3/5 |
| 101 | `haxeon.ui.widgets.docking.DockWorkspace.buildNode` | `(virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))> ())` | 128 | 69,416 | 88.406% | C | Stages 3/5 |
| 102 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 128 | 69,544 | 88.569% | V | Stage 2 + stages 3/5 |
| 103 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.style.StyleTarget` | 112 | 69,656 | 88.711% | V | Stage 2 + stages 3/5 |
| 104 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.style.StyleTarget` | 112 | 69,768 | 88.854% | V | Stage 2 + stages 3/5 |
| 105 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.style.StyleTarget` | 112 | 69,880 | 88.996% | V | Stage 2 + stages 3/5 |
| 106 | `$scalar-arguments:haxeon.ui.LayoutNode.set_textStyle` | `haxeon.ui.LayoutTextStyles` | 112 | 69,992 | 89.139% | V | Stage 2 + stages 3/5 |
| 107 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 70,104 | 89.282% | N | Other: FFI query values |
| 108 | `haxeon.ui.core.InteractionStateStore.set` | `i32` | 112 | 70,216 | 89.424% | B | a2 |
| 109 | `haxeon.ui.docking.DockNodeTools.activatePath` | `enum<haxeon.ui.docking.DockNode>` | 112 | 70,328 | 89.567% | B | Other: dock-tree copies |
| 110 | `$lambda:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | `$lambda-env:haxeon.ui.widgets.KeyedView.build:build#return/withScope(1)@2BC7466A#0` | 96 | 70,424 | 89.689% | C | Stages 3/5 |
| 111 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `$lambda-env:$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0:build#onPaint(0)@3C40BFBF#0` | 96 | 70,520 | 89.812% | C | Stages 3/5 |
| 112 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `bytes` | 96 | 70,616 | 89.934% | A | Stage 2 + stages 3/5 |
| 113 | `$lambda:haxeon.ui.widgets.layout.AppShell.build:build#return/withScope(1)@69FFC9EA#0` | `haxeon.ui.widgets.KeyedView` | 96 | 70,712 | 90.056% | V | Stage 2 + stages 3/5 |

Displayed sites: 70,712 bytes. Classified remainder below the cutoff: **7,808 bytes**.

### tab-matrix: telemetry->console

Exact total: **1,712 objects / 93,176 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 7,392 | 7,392 | 7.933% | N | Stage 2 |
| 2 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.core.RenderNode` | 5,040 | 12,432 | 13.342% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 4,080 | 16,512 | 17.721% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 3,784 | 20,296 | 21.782% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 3,440 | 23,736 | 25.474% | V | Stage 2 + stages 3/5 |
| 6 | `NativeKitUI.nkui_layout_session_submit_slice` | `<abstract>` | 3,304 | 27,040 | 29.020% | N | Stage 2 |
| 7 | `$generic:nkui_layout_measure_result.new[]<>` | `<abstract>` | 3,248 | 30,288 | 32.506% | N | Other: FFI query values |
| 8 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 2,880 | 33,168 | 35.597% | N | Stage 2 |
| 9 | `$lambda:haxeon.ui.LayoutSession.refreshMeasureCallback:refreshMeasureCallback#nkui_layout_measure_callbackCallback(0)~3CB3D6E0@590B886C#0` | `haxeon.ui.LayoutMeasureConstraints` | 2,320 | 35,488 | 38.087% | N | Other: FFI query values |
| 10 | `haxeon.ui.LayoutSession.measureNode` | `haxeon.ui.LayoutMeasureResult` | 2,240 | 37,728 | 40.491% | N | Other: FFI query values |
| 11 | `haxeon.ui.LayoutNode.add` | `array` | 2,088 | 39,816 | 42.732% | A | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.core.RenderNode.add` | `array` | 2,088 | 41,904 | 44.973% | A | Stage 2 + stages 3/5 |
| 13 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.LayoutStyle` | 2,064 | 43,968 | 47.188% | V | Stage 2 + stages 3/5 |
| 14 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.LayoutStyle` | 2,064 | 46,032 | 49.403% | V | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.widgets.layout.SplitView.paneStyle` | `haxeon.ui.LayoutStyle` | 2,064 | 48,096 | 51.618% | V | Stage 2 + stages 3/5 |
| 16 | `NativeKitUI.nkui_layout_session_submit_slice` | `realtime_bytes` | 1,888 | 49,984 | 53.645% | N | Stage 2 |
| 17 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.core.RenderNode` | 1,680 | 51,664 | 55.448% | V | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.LayoutSession.refreshMeasureCallback` | `<abstract>` | 1,152 | 52,816 | 56.684% | N | Other: FFI query values |
| 19 | `haxeon.ui.docking.DockNodeTools.normalize` | `array` | 1,080 | 53,896 | 57.843% | A | Stage 2 + stages 3/5 |
| 20 | `haxeon.ui.widgets.layout.SplitView.defaultStyle` | `haxeon.ui.LayoutStyle` | 1,032 | 54,928 | 58.951% | V | Stage 2 + stages 3/5 |
| 21 | `haxeon.ui.widgets.layout.SplitView.new` | `haxeon.ui.LayoutStyle` | 1,032 | 55,960 | 60.058% | V | Stage 2 + stages 3/5 |
| 22 | `NativeKitUI.nkui_layout_session_submit_slice` | `i32` | 976 | 56,936 | 61.106% | B | a2 |
| 23 | `haxeon.ui.core.HitTest.pathTo` | `array` | 960 | 57,896 | 62.136% | A | Stage 2 + stages 3/5 |
| 24 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 832 | 58,728 | 63.029% | V | Stage 2 + stages 3/5 |
| 25 | `haxeon.ui.core.StateStore.endFrame` | `array` | 816 | 59,544 | 63.905% | A | Stage 2 + stages 3/5 |
| 26 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `<abstract>` | 800 | 60,344 | 64.763% | M | a2 |
| 27 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 696 | 61,040 | 65.510% | A | Stage 2 + stages 3/5 |
| 28 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.layout.SizedBox.new` | `haxeon.ui.LayoutStyle` | 688 | 61,728 | 66.249% | V | Stage 2 + stages 3/5 |
| 29 | `haxeon.ui.widgets.layout.Stack.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 62,416 | 66.987% | V | Stage 2 + stages 3/5 |
| 30 | `haxeon.ui.widgets.layout.SplitView.installDividerHandlers` | `(void (haxeon.ui.core.UiEvent))` | 672 | 63,088 | 67.708% | C | Stages 3/5 |
| 31 | `haxeon.ui.docking.DockNodeTools.normalize` | `enum<haxeon.ui.docking.DockNode>` | 624 | 63,712 | 68.378% | B | Other: dock-tree copies |
| 32 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 608 | 64,320 | 69.031% | A | Stage 2 + stages 3/5 |
| 33 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 576 | 64,896 | 69.649% | A | Stage 2 + stages 3/5 |
| 34 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.core.RenderNode` | 560 | 65,456 | 70.250% | V | Stage 2 + stages 3/5 |
| 35 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.core.RenderNode` | 560 | 66,016 | 70.851% | V | Stage 2 + stages 3/5 |
| 36 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.core.RenderNode` | 560 | 66,576 | 71.452% | V | Stage 2 + stages 3/5 |
| 37 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 528 | 67,104 | 72.019% | V | Stage 2 + stages 3/5 |
| 38 | `haxeon.ui.docking.DockNodeTools.clone` | `enum<haxeon.ui.docking.DockNode>` | 480 | 67,584 | 72.534% | B | Other: dock-tree copies |
| 39 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `bytes` | 472 | 68,056 | 73.040% | A | Stage 2 + stages 3/5 |
| 40 | `haxeon.ui.widgets.docking.DockPanelCache.retain` | `array` | 448 | 68,504 | 73.521% | A | Stage 2 + stages 3/5 |
| 41 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `array` | 432 | 68,936 | 73.985% | A | Stage 2 + stages 3/5 |
| 42 | `haxeon.ui.docking.DockNodeTools.clone` | `array` | 432 | 69,368 | 74.448% | A | Stage 2 + stages 3/5 |
| 43 | `robotkit.world.RobotWorld.robotIds` | `array` | 432 | 69,800 | 74.912% | A | Stage 2 + stages 3/5 |
| 44 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `bytes` | 416 | 70,216 | 75.358% | A | Stage 2 + stages 3/5 |
| 45 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.semantics.Semantics` | 408 | 70,624 | 75.796% | V | Stage 2 + stages 3/5 |
| 46 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitView` | 408 | 71,032 | 76.234% | V | Stage 2 + stages 3/5 |
| 47 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `String` | 384 | 71,416 | 76.646% | A | Stage 2 + stages 3/5 |
| 48 | `haxeon.ui.style.StyleResolver.keyHash` | `bytes` | 352 | 71,768 | 77.024% | A | Stage 2 + stages 3/5 |
| 49 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 344 | 72,112 | 77.393% | V | Stage 2 + stages 3/5 |
| 50 | `app.ReferenceEditorApp.fillStyle` | `haxeon.ui.LayoutStyle` | 344 | 72,456 | 77.763% | V | Stage 2 + stages 3/5 |
| 51 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 344 | 72,800 | 78.132% | V | Stage 2 + stages 3/5 |
| 52 | `haxeon.ui.widgets.docking.DockWorkspace.defaultStyle` | `haxeon.ui.LayoutStyle` | 344 | 73,144 | 78.501% | V | Stage 2 + stages 3/5 |
| 53 | `haxeon.ui.widgets.layout.AppShell.defaultBodyStyle` | `haxeon.ui.LayoutStyle` | 344 | 73,488 | 78.870% | V | Stage 2 + stages 3/5 |
| 54 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `array` | 336 | 73,824 | 79.231% | A | Stage 2 + stages 3/5 |
| 55 | `haxeon.ui.core.EventDispatcher.dispatchDirect` | `haxeon.ui.core.UiEvent` | 320 | 74,144 | 79.574% | V | Stage 2 + stages 3/5 |
| 56 | `haxeon.ui.core.EventDispatcher.pointerUp` | `haxeon.ui.core.UiEvent` | 320 | 74,464 | 79.918% | V | Stage 2 + stages 3/5 |
| 57 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 312 | 74,776 | 80.252% | N | Other: FFI query values |
| 58 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitViewOptions` | 312 | 75,088 | 80.587% | V | Stage 2 + stages 3/5 |
| 59 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `array` | 288 | 75,376 | 80.896% | A | Stage 2 + stages 3/5 |
| 60 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `array` | 288 | 75,664 | 81.205% | A | Stage 2 + stages 3/5 |
| 61 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `array` | 288 | 75,952 | 81.515% | A | Stage 2 + stages 3/5 |
| 62 | `haxeon.ui.widgets.docking.DockWorkspace.build` | `bytes` | 288 | 76,240 | 81.824% | A | Stage 2 + stages 3/5 |
| 63 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 280 | 76,520 | 82.124% | V | Stage 2 + stages 3/5 |
| 64 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 280 | 76,800 | 82.425% | V | Stage 2 + stages 3/5 |
| 65 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `haxeon.ui.core.RenderNode` | 280 | 77,080 | 82.725% | V | Stage 2 + stages 3/5 |
| 66 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 77,360 | 83.026% | V | Stage 2 + stages 3/5 |
| 67 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 280 | 77,640 | 83.326% | V | Stage 2 + stages 3/5 |
| 68 | `app.ReferenceEditorApp.view` | `haxeon.ui.widgets.layout.StackChild` | 272 | 77,912 | 83.618% | V | Stage 2 + stages 3/5 |
| 69 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 78,176 | 83.901% | O | Other |
| 70 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `bytes` | 264 | 78,440 | 84.185% | A | Stage 2 + stages 3/5 |
| 71 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `bytes` | 264 | 78,704 | 84.468% | A | Stage 2 + stages 3/5 |
| 72 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `haxeon.ui.widgets.docking.DockPaneView` | 256 | 78,960 | 84.743% | V | Stage 2 + stages 3/5 |
| 73 | `haxeon.ui.docking.DockNodeTools.remove` | `enum<haxeon.ui.docking.DockNode>` | 240 | 79,200 | 85.000% | B | Other: dock-tree copies |
| 74 | `haxeon.ui.widgets.docking.DockWorkspace.buildNode` | `$lambda-env:haxeon.ui.widgets.docking.DockWorkspace.buildNode:buildNode#return/paneView(6)@3BC502D4#1` | 240 | 79,440 | 85.258% | C | Stages 3/5 |
| 75 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.beginFrame` | `array` | 224 | 79,664 | 85.498% | A | Stage 2 + stages 3/5 |
| 76 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `String` | 216 | 79,880 | 85.730% | A | Stage 2 + stages 3/5 |
| 77 | `app.ApplicationSimulation.captureOwnerSnapshot` | `array` | 216 | 80,096 | 85.962% | A | Stage 2 + stages 3/5 |
| 78 | `haxeon.ui.docking.DockNodeTools.remove` | `array` | 216 | 80,312 | 86.194% | A | Stage 2 + stages 3/5 |
| 79 | `$lambda:tests.HeadlessEditorProfile.submit:submit#buildProbe=@305D61CA#0` | `bytes` | 208 | 80,520 | 86.417% | A | Stage 2 + stages 3/5 |
| 80 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `(haxeon.ui.core.RenderNode ())` | 192 | 80,712 | 86.623% | C | Stages 3/5 |
| 81 | `app.ReferenceEditorApp.view` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 192 | 80,904 | 86.829% | V | Stage 2 + stages 3/5 |
| 82 | `haxeon.ui.core.BuildContext.claimRetainedTree` | `(void (haxeon.ui.core.RenderNode))` | 192 | 81,096 | 87.035% | C | Stages 3/5 |
| 83 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 176 | 81,272 | 87.224% | V | Stage 2 + stages 3/5 |
| 84 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `$lambda-env:$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0:build#onPaint(0)@6785BEF6#0` | 168 | 81,440 | 87.404% | C | Stages 3/5 |
| 85 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.style.StyleTarget` | 168 | 81,608 | 87.585% | V | Stage 2 + stages 3/5 |
| 86 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 168 | 81,776 | 87.765% | N | Other: FFI query values |
| 87 | `haxeon.ui.core.EventDispatcher.dispatchOutsidePointerDown` | `haxeon.ui.core.UiEvent` | 160 | 81,936 | 87.937% | V | Stage 2 + stages 3/5 |
| 88 | `haxeon.ui.core.EventDispatcher.pointerDown` | `haxeon.ui.core.UiEvent` | 160 | 82,096 | 88.109% | V | Stage 2 + stages 3/5 |
| 89 | `haxeon.ui.LayoutSession.refreshMeasureCallback` | `bytes` | 152 | 82,248 | 88.272% | N | Other: FFI query values |
| 90 | `haxeon.ui.core.RetainedView.build` | `bytes` | 152 | 82,400 | 88.435% | A | Stage 2 + stages 3/5 |
| 91 | `$lambda:haxeon.ui.widgets.layout.AppShell.build:build#return/withScope(1)@69FFC9EA#0` | `array` | 144 | 82,544 | 88.589% | A | Stage 2 + stages 3/5 |
| 92 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `array` | 144 | 82,688 | 88.744% | A | Stage 2 + stages 3/5 |
| 93 | `app.ReferenceEditorApp.view` | `array` | 144 | 82,832 | 88.898% | A | Stage 2 + stages 3/5 |
| 94 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 144 | 82,976 | 89.053% | B | a2 |
| 95 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 144 | 83,120 | 89.208% | A | Stage 2 + stages 3/5 |
| 96 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `String` | 144 | 83,264 | 89.362% | A | Stage 2 + stages 3/5 |
| 97 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.new` | `array` | 144 | 83,408 | 89.517% | A | Stage 2 + stages 3/5 |
| 98 | `haxeon.ui.widgets.layout.Stack.new` | `array` | 144 | 83,552 | 89.671% | A | Stage 2 + stages 3/5 |
| 99 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 136 | 83,688 | 89.817% | A | Stage 2 + stages 3/5 |
| 100 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 136 | 83,824 | 89.963% | V | Stage 2 + stages 3/5 |
| 101 | `$lambda:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | `(haxeon.ui.core.RenderNode ())` | 128 | 83,952 | 90.100% | C | Stages 3/5 |

Displayed sites: 83,952 bytes. Classified remainder below the cutoff: **9,224 bytes**.

### interaction: scroll-inspector

Exact total: **227 objects / 23,072 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 18,816 | 18,816 | 81.553% | N | Stage 2 |
| 2 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 536 | 19,352 | 83.877% | A | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 344 | 19,696 | 85.368% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 19,976 | 86.581% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 20,240 | 87.725% | O | Other |
| 6 | `haxeon.ui.LayoutSession.submit` | `bytes` | 224 | 20,464 | 88.696% | N | Other: FFI query values |
| 7 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 20,680 | 89.632% | A | Stage 2 + stages 3/5 |
| 8 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 208 | 20,888 | 90.534% | N | Other: FFI query values |

Displayed sites: 20,888 bytes. Classified remainder below the cutoff: **2,184 bytes**.

### interaction: hover-enter

Exact total: **33 objects / 1,296 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 264 | 20.370% | O | Other |
| 2 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 480 | 37.037% | A | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.EventDispatcher.pointerMove` | `haxeon.ui.core.UiEvent` | 160 | 640 | 49.383% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 104 | 744 | 57.407% | N | Other: FFI query values |
| 5 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 816 | 62.963% | A | Stage 2 + stages 3/5 |
| 6 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 888 | 68.519% | A | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 960 | 74.074% | A | Stage 2 + stages 3/5 |
| 8 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 1,032 | 79.630% | A | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 56 | 1,088 | 83.951% | N | Other: FFI query values |
| 10 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 48 | 1,136 | 87.654% | B | a2 |
| 11 | `app.ReferenceEditorApp.submit` | `(virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))> ())` | 32 | 1,168 | 90.123% | C | Stages 3/5 |

Displayed sites: 1,168 bytes. Classified remainder below the cutoff: **128 bytes**.

### interaction: hover-inside

Exact total: **33 objects / 1,296 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 264 | 20.370% | O | Other |
| 2 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 480 | 37.037% | A | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.EventDispatcher.pointerMove` | `haxeon.ui.core.UiEvent` | 160 | 640 | 49.383% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 104 | 744 | 57.407% | N | Other: FFI query values |
| 5 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 816 | 62.963% | A | Stage 2 + stages 3/5 |
| 6 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 888 | 68.519% | A | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 960 | 74.074% | A | Stage 2 + stages 3/5 |
| 8 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 1,032 | 79.630% | A | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 56 | 1,088 | 83.951% | N | Other: FFI query values |
| 10 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 48 | 1,136 | 87.654% | B | a2 |
| 11 | `app.ReferenceEditorApp.submit` | `(virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))> ())` | 32 | 1,168 | 90.123% | C | Stages 3/5 |

Displayed sites: 1,168 bytes. Classified remainder below the cutoff: **128 bytes**.

### interaction: idle

Exact total: **18 objects / 848 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 264 | 31.132% | O | Other |
| 2 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 480 | 56.604% | A | Stage 2 + stages 3/5 |
| 3 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 552 | 65.094% | A | Stage 2 + stages 3/5 |
| 4 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 624 | 73.585% | A | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 696 | 82.075% | A | Stage 2 + stages 3/5 |
| 6 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 768 | 90.566% | A | Stage 2 + stages 3/5 |

Displayed sites: 768 bytes. Classified remainder below the cutoff: **80 bytes**.

### interaction: idle-focused

Exact total: **18 objects / 848 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 264 | 31.132% | O | Other |
| 2 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 480 | 56.604% | A | Stage 2 + stages 3/5 |
| 3 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 552 | 65.094% | A | Stage 2 + stages 3/5 |
| 4 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 624 | 73.585% | A | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 696 | 82.075% | A | Stage 2 + stages 3/5 |
| 6 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 768 | 90.566% | A | Stage 2 + stages 3/5 |

Displayed sites: 768 bytes. Classified remainder below the cutoff: **80 bytes**.

### interaction: hover-other

Exact total: **187 objects / 9,712 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 688 | 688 | 7.084% | V | Stage 2 + stages 3/5 |
| 2 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 688 | 1,376 | 14.168% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 600 | 1,976 | 20.346% | V | Stage 2 + stages 3/5 |
| 4 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 560 | 2,536 | 26.112% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 560 | 3,096 | 31.878% | V | Stage 2 + stages 3/5 |
| 6 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 344 | 3,440 | 35.420% | V | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 288 | 3,728 | 38.386% | A | Stage 2 + stages 3/5 |
| 8 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 288 | 4,016 | 41.351% | A | Stage 2 + stages 3/5 |
| 9 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 280 | 4,296 | 44.234% | V | Stage 2 + stages 3/5 |
| 10 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 272 | 4,568 | 47.035% | A | Stage 2 + stages 3/5 |
| 11 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 272 | 4,840 | 49.835% | V | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 5,104 | 52.554% | O | Other |
| 13 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 232 | 5,336 | 54.942% | A | Stage 2 + stages 3/5 |
| 14 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 5,552 | 57.166% | A | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 208 | 5,760 | 59.308% | N | Other: FFI query values |
| 16 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 176 | 5,936 | 61.120% | V | Stage 2 + stages 3/5 |
| 17 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.widgets.Icon` | 176 | 6,112 | 62.932% | V | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.core.EventDispatcher.pointerMove` | `haxeon.ui.core.UiEvent` | 160 | 6,272 | 64.580% | V | Stage 2 + stages 3/5 |
| 19 | `haxeon.ui.LayoutNode.add` | `array` | 144 | 6,416 | 66.063% | A | Stage 2 + stages 3/5 |
| 20 | `haxeon.ui.core.RenderNode.add` | `array` | 144 | 6,560 | 67.545% | A | Stage 2 + stages 3/5 |
| 21 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 144 | 6,704 | 69.028% | A | Stage 2 + stages 3/5 |
| 22 | `haxeon.ui.core.InteractionStateStore.set` | `i32` | 128 | 6,832 | 70.346% | B | a2 |
| 23 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 128 | 6,960 | 71.664% | V | Stage 2 + stages 3/5 |
| 24 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 112 | 7,072 | 72.817% | N | Other: FFI query values |
| 25 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 7,184 | 73.970% | N | Other: FFI query values |
| 26 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `$lambda-env:$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0:build#onPaint(0)@3C40BFBF#0` | 96 | 7,280 | 74.959% | C | Stages 3/5 |
| 27 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `bytes` | 96 | 7,376 | 75.947% | A | Stage 2 + stages 3/5 |
| 28 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.TextStyleOverride` | 96 | 7,472 | 76.936% | V | Stage 2 + stages 3/5 |
| 29 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 96 | 7,568 | 77.924% | N | Stage 2 |
| 30 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 96 | 7,664 | 78.913% | B | a2 |
| 31 | `haxeon.ui.core.InteractionStateStore.changes` | `$anon:{after:abstract:haxeon.ui.style.StyleState<>,before:abstract:haxeon.ui.style.StyleState<>,id:Int}` | 96 | 7,760 | 79.901% | V | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 96 | 7,856 | 80.890% | V | Stage 2 + stages 3/5 |
| 33 | `haxeon.ui.widgets.controls.Button.buildButton` | `(haxeon.ui.core.RenderNode ())` | 96 | 7,952 | 81.878% | C | Stages 3/5 |
| 34 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 8,024 | 82.619% | A | Stage 2 + stages 3/5 |
| 35 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 8,096 | 83.361% | A | Stage 2 + stages 3/5 |
| 36 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 8,168 | 84.102% | A | Stage 2 + stages 3/5 |
| 37 | `haxeon.ui.core.BuildContext.applyPatches` | `array` | 72 | 8,240 | 84.843% | A | Stage 2 + stages 3/5 |
| 38 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `array` | 72 | 8,312 | 85.585% | A | Stage 2 + stages 3/5 |
| 39 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 8,384 | 86.326% | A | Stage 2 + stages 3/5 |
| 40 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `(void (haxeon.ui.Canvas,haxeon.ui.ResolvedLayoutItem))` | 64 | 8,448 | 86.985% | C | Stages 3/5 |
| 41 | `haxeon.ui.LayoutSession.hitTestInto` | `f64` | 64 | 8,512 | 87.644% | B | a2 |
| 42 | `haxeon.ui.LayoutSession.hitTestInto` | `realtime_bytes` | 64 | 8,576 | 88.303% | N | Other: FFI query values |
| 43 | `haxeon.ui.core.InteractionStateStore.changes` | `array` | 64 | 8,640 | 88.962% | A | Stage 2 + stages 3/5 |
| 44 | `haxeon.ui.core.RenderNode.onActivate` | `(void (haxeon.ui.core.UiEvent))` | 64 | 8,704 | 89.621% | C | Stages 3/5 |
| 45 | `haxeon.ui.style.StyleResolver.keyHash` | `bytes` | 64 | 8,768 | 90.280% | A | Stage 2 + stages 3/5 |

Displayed sites: 8,768 bytes. Classified remainder below the cutoff: **944 bytes**.

### interaction: hover-field

Exact total: **323 objects / 17,296 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.style.ComputedStyle.setDeclaration` | `array` | 2,992 | 2,992 | 17.299% | A | Stage 2 + stages 3/5 |
| 2 | `haxeon.ui.core.InteractionStateStore.set` | `i32` | 736 | 3,728 | 21.554% | B | a2 |
| 3 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 720 | 4,448 | 25.717% | V | Stage 2 + stages 3/5 |
| 4 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 688 | 5,136 | 29.695% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 688 | 5,824 | 33.673% | V | Stage 2 + stages 3/5 |
| 6 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 560 | 6,384 | 36.910% | V | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 560 | 6,944 | 40.148% | V | Stage 2 + stages 3/5 |
| 8 | `haxeon.ui.core.InteractionStateStore.changes` | `$anon:{after:abstract:haxeon.ui.style.StyleState<>,before:abstract:haxeon.ui.style.StyleState<>,id:Int}` | 552 | 7,496 | 43.340% | V | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.style.StyleSelector.describe` | `array` | 432 | 7,928 | 45.837% | A | Stage 2 + stages 3/5 |
| 10 | `haxeon.ui.style.StyleSelector.describe` | `bytes` | 376 | 8,304 | 48.011% | A | Stage 2 + stages 3/5 |
| 11 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 344 | 8,648 | 50.000% | V | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 344 | 8,992 | 51.989% | V | Stage 2 + stages 3/5 |
| 13 | `haxeon.ui.core.EventDispatcher.updateHover` | `haxeon.ui.core.UiEvent` | 320 | 9,312 | 53.839% | V | Stage 2 + stages 3/5 |
| 14 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 304 | 9,616 | 55.597% | A | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 288 | 9,904 | 57.262% | A | Stage 2 + stages 3/5 |
| 16 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 288 | 10,192 | 58.927% | A | Stage 2 + stages 3/5 |
| 17 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 280 | 10,472 | 60.546% | V | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 10,752 | 62.165% | V | Stage 2 + stages 3/5 |
| 19 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 272 | 11,024 | 63.737% | V | Stage 2 + stages 3/5 |
| 20 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 11,288 | 65.264% | O | Other |
| 21 | `haxeon.ui.style.StyleResolver.applySheet` | `haxeon.ui.style.StyleSource` | 240 | 11,528 | 66.651% | R | Stages 3/5 |
| 22 | `haxeon.ui.style.ComputedStyle.new` | `array` | 216 | 11,744 | 67.900% | A | Stage 2 + stages 3/5 |
| 23 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 11,960 | 69.149% | A | Stage 2 + stages 3/5 |
| 24 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 208 | 12,168 | 70.352% | N | Other: FFI query values |
| 25 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 176 | 12,344 | 71.369% | V | Stage 2 + stages 3/5 |
| 26 | `haxeon.ui.core.InteractionStateStore.changes` | `array` | 176 | 12,520 | 72.387% | A | Stage 2 + stages 3/5 |
| 27 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.widgets.Icon` | 176 | 12,696 | 73.404% | V | Stage 2 + stages 3/5 |
| 28 | `haxeon.ui.style.StyleSelector.describe` | `String` | 168 | 12,864 | 74.376% | A | Stage 2 + stages 3/5 |
| 29 | `haxeon.ui.core.EventDispatcher.pointerMove` | `haxeon.ui.core.UiEvent` | 160 | 13,024 | 75.301% | V | Stage 2 + stages 3/5 |
| 30 | `haxeon.ui.LayoutNode.add` | `array` | 144 | 13,168 | 76.133% | A | Stage 2 + stages 3/5 |
| 31 | `haxeon.ui.core.RenderNode.add` | `array` | 144 | 13,312 | 76.966% | A | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 144 | 13,456 | 77.798% | A | Stage 2 + stages 3/5 |
| 33 | `haxeon.ui.style.StyleResolver.applySheet` | `array` | 144 | 13,600 | 78.631% | A | Stage 2 + stages 3/5 |
| 34 | `haxeon.ui.widgets.controls.Button.styleTarget` | `array` | 144 | 13,744 | 79.463% | A | Stage 2 + stages 3/5 |
| 35 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 136 | 13,880 | 80.250% | A | Stage 2 + stages 3/5 |
| 36 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 128 | 14,008 | 80.990% | V | Stage 2 + stages 3/5 |
| 37 | `$scalar-arguments:$optional-scalar:haxeon.ui.style.StyleResolver.resolve` | `haxeon.ui.style.StyleResolverCacheEntry` | 112 | 14,120 | 81.637% | R | Stages 3/5 |
| 38 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 112 | 14,232 | 82.285% | N | Other: FFI query values |
| 39 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 14,344 | 82.932% | N | Other: FFI query values |
| 40 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `$lambda-env:$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0:build#onPaint(0)@3C40BFBF#0` | 96 | 14,440 | 83.488% | C | Stages 3/5 |
| 41 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `bytes` | 96 | 14,536 | 84.043% | A | Stage 2 + stages 3/5 |
| 42 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.TextStyleOverride` | 96 | 14,632 | 84.598% | V | Stage 2 + stages 3/5 |
| 43 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 96 | 14,728 | 85.153% | N | Stage 2 |
| 44 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 96 | 14,824 | 85.708% | B | a2 |
| 45 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 96 | 14,920 | 86.263% | V | Stage 2 + stages 3/5 |
| 46 | `haxeon.ui.widgets.controls.Button.buildButton` | `(haxeon.ui.core.RenderNode ())` | 96 | 15,016 | 86.818% | C | Stages 3/5 |
| 47 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `array` | 88 | 15,104 | 87.327% | A | Stage 2 + stages 3/5 |
| 48 | `$scalar-arguments:$optional-scalar:haxeon.ui.style.StyleResolver.resolve` | `array` | 72 | 15,176 | 87.743% | A | Stage 2 + stages 3/5 |
| 49 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 15,248 | 88.159% | A | Stage 2 + stages 3/5 |
| 50 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 15,320 | 88.575% | A | Stage 2 + stages 3/5 |
| 51 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 15,392 | 88.992% | A | Stage 2 + stages 3/5 |
| 52 | `haxeon.ui.core.BuildContext.applyPatches` | `array` | 72 | 15,464 | 89.408% | A | Stage 2 + stages 3/5 |
| 53 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `array` | 72 | 15,536 | 89.824% | A | Stage 2 + stages 3/5 |
| 54 | `haxeon.ui.style.StyleTarget.shared` | `array` | 72 | 15,608 | 90.241% | A | Stage 2 + stages 3/5 |

Displayed sites: 15,608 bytes. Classified remainder below the cutoff: **1,688 bytes**.

### interaction: hover-away

Exact total: **257 objects / 12,512 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.core.InteractionStateStore.set` | `i32` | 736 | 736 | 5.882% | B | a2 |
| 2 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 720 | 1,456 | 11.637% | V | Stage 2 + stages 3/5 |
| 3 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 688 | 2,144 | 17.136% | V | Stage 2 + stages 3/5 |
| 4 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 688 | 2,832 | 22.634% | V | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 688 | 3,520 | 28.133% | V | Stage 2 + stages 3/5 |
| 6 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 560 | 4,080 | 32.609% | V | Stage 2 + stages 3/5 |
| 7 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 560 | 4,640 | 37.084% | V | Stage 2 + stages 3/5 |
| 8 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 560 | 5,200 | 41.560% | V | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.core.InteractionStateStore.changes` | `$anon:{after:abstract:haxeon.ui.style.StyleState<>,before:abstract:haxeon.ui.style.StyleState<>,id:Int}` | 552 | 5,752 | 45.972% | V | Stage 2 + stages 3/5 |
| 10 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 464 | 6,216 | 49.680% | A | Stage 2 + stages 3/5 |
| 11 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 352 | 6,568 | 52.494% | V | Stage 2 + stages 3/5 |
| 12 | `haxeon.ui.core.EventDispatcher.updateHover` | `haxeon.ui.core.UiEvent` | 320 | 6,888 | 55.051% | V | Stage 2 + stages 3/5 |
| 13 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 288 | 7,176 | 57.353% | A | Stage 2 + stages 3/5 |
| 14 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 288 | 7,464 | 59.655% | A | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 272 | 7,736 | 61.829% | V | Stage 2 + stages 3/5 |
| 16 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 8,000 | 63.939% | O | Other |
| 17 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 8,216 | 65.665% | A | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 208 | 8,424 | 67.327% | N | Other: FFI query values |
| 19 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.TextStyleOverride` | 192 | 8,616 | 68.862% | V | Stage 2 + stages 3/5 |
| 20 | `haxeon.ui.core.InteractionStateStore.changes` | `array` | 176 | 8,792 | 70.269% | A | Stage 2 + stages 3/5 |
| 21 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.widgets.Icon` | 176 | 8,968 | 71.675% | V | Stage 2 + stages 3/5 |
| 22 | `haxeon.ui.core.EventDispatcher.pointerMove` | `haxeon.ui.core.UiEvent` | 160 | 9,128 | 72.954% | V | Stage 2 + stages 3/5 |
| 23 | `haxeon.ui.LayoutNode.add` | `array` | 144 | 9,272 | 74.105% | A | Stage 2 + stages 3/5 |
| 24 | `haxeon.ui.core.RenderNode.add` | `array` | 144 | 9,416 | 75.256% | A | Stage 2 + stages 3/5 |
| 25 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 144 | 9,560 | 76.407% | A | Stage 2 + stages 3/5 |
| 26 | `$generic:haxeon.ui.core.RenderNode.swapBuilt[layout]<class:haxeon.ui.core.HandlerEntry<>>` | `array` | 136 | 9,696 | 77.494% | A | Stage 2 + stages 3/5 |
| 27 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 128 | 9,824 | 78.517% | V | Stage 2 + stages 3/5 |
| 28 | `haxeon.ui.widgets.controls.Button.buildButton` | `$lambda-env:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | 128 | 9,952 | 79.540% | C | Stages 3/5 |
| 29 | `haxeon.ui.widgets.controls.Button.buildButton` | `(haxeon.ui.core.RenderNode ())` | 128 | 10,080 | 80.563% | C | Stages 3/5 |
| 30 | `$scalar-arguments:haxeon.ui.LayoutNode.set_textStyle` | `haxeon.ui.LayoutTextStyles` | 112 | 10,192 | 81.458% | V | Stage 2 + stages 3/5 |
| 31 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 112 | 10,304 | 82.353% | N | Other: FFI query values |
| 32 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 10,416 | 83.248% | N | Other: FFI query values |
| 33 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `$lambda-env:$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0:build#onPaint(0)@3C40BFBF#0` | 96 | 10,512 | 84.015% | C | Stages 3/5 |
| 34 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `bytes` | 96 | 10,608 | 84.783% | A | Stage 2 + stages 3/5 |
| 35 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 96 | 10,704 | 85.550% | N | Stage 2 |
| 36 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 96 | 10,800 | 86.317% | B | a2 |
| 37 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `array` | 96 | 10,896 | 87.084% | A | Stage 2 + stages 3/5 |
| 38 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 96 | 10,992 | 87.852% | V | Stage 2 + stages 3/5 |
| 39 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 11,064 | 88.427% | A | Stage 2 + stages 3/5 |
| 40 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 11,136 | 89.003% | A | Stage 2 + stages 3/5 |
| 41 | `haxeon.ui.animation.AnimationScheduler.remove` | `array` | 72 | 11,208 | 89.578% | A | Stage 2 + stages 3/5 |
| 42 | `haxeon.ui.core.BuildContext.applyPatches` | `array` | 72 | 11,280 | 90.153% | A | Stage 2 + stages 3/5 |

Displayed sites: 11,280 bytes. Classified remainder below the cutoff: **1,232 bytes**.

### interaction: type-char

Exact total: **418 objects / 16,384 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.core.RenderNode` | 1,120 | 1,120 | 6.836% | V | Stage 2 + stages 3/5 |
| 2 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.LayoutStyle` | 1,032 | 2,152 | 13.135% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.HitTest.pathTo` | `array` | 712 | 2,864 | 17.480% | A | Stage 2 + stages 3/5 |
| 4 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `bytes` | 480 | 3,344 | 20.410% | N | Other: FFI query values |
| 5 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 480 | 3,824 | 23.340% | V | Stage 2 + stages 3/5 |
| 6 | `haxeon.editor.TextOffsetMap.new` | `array` | 456 | 4,280 | 26.123% | A | Other: text/storage |
| 7 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 416 | 4,696 | 28.662% | V | Stage 2 + stages 3/5 |
| 8 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (haxeon.ui.core.UiEvent))` | 352 | 5,048 | 30.811% | C | Stages 3/5 |
| 9 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 344 | 5,392 | 32.910% | V | Stage 2 + stages 3/5 |
| 10 | `$generic:nkui_text_position.new[]<>` | `<abstract>` | 336 | 5,728 | 34.961% | N | Other: FFI query values |
| 11 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `bytes` | 320 | 6,048 | 36.914% | A | Other: text/storage |
| 12 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 320 | 6,368 | 38.867% | A | Stage 2 + stages 3/5 |
| 13 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 304 | 6,672 | 40.723% | A | Stage 2 + stages 3/5 |
| 14 | `$generic:nkui_text_caret.new[]<>` | `<abstract>` | 280 | 6,952 | 42.432% | N | Other: FFI query values |
| 15 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 7,216 | 44.043% | O | Other |
| 16 | `haxeon.editor.TextDocumentBuffer.reindex` | `array` | 224 | 7,440 | 45.410% | A | Other: text/storage |
| 17 | `haxeon.ui.widgets.text.TextEditorLayout.setTextAfterEdit` | `array` | 216 | 7,656 | 46.729% | A | Stage 2 + stages 3/5 |
| 18 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 7,872 | 48.047% | A | Stage 2 + stages 3/5 |
| 19 | `NativeKitUI.nkui_text_layout_get_line_rects` | `bytes` | 192 | 8,064 | 49.219% | N | Other: FFI query values |
| 20 | `haxeon.editor.TextOffsetMap.countCodepoints` | `<abstract>` | 168 | 8,232 | 50.244% | A | Other: text/storage |
| 21 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 168 | 8,400 | 51.270% | N | Stage 2 |
| 22 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `i32` | 160 | 8,560 | 52.246% | B | a2 |
| 23 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `realtime_bytes` | 160 | 8,720 | 53.223% | N | Other: FFI query values |
| 24 | `haxeon.ui.core.EventDispatcher.text` | `haxeon.ui.core.UiEvent` | 160 | 8,880 | 54.199% | V | Stage 2 + stages 3/5 |
| 25 | `haxeon.editor.TextDocumentBuffer.get_text` | `bytes` | 152 | 9,032 | 55.127% | A | Other: text/storage |
| 26 | `$scalar-arguments:haxeon.ui.TextLayout.measure` | `bytes` | 144 | 9,176 | 56.006% | N | Other: FFI query values |
| 27 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `<abstract>` | 144 | 9,320 | 56.885% | A | Other: text/storage |
| 28 | `haxeon.ui.LayoutNode.add` | `array` | 144 | 9,464 | 57.764% | A | Stage 2 + stages 3/5 |
| 29 | `haxeon.ui.core.RenderNode.add` | `array` | 144 | 9,608 | 58.643% | A | Stage 2 + stages 3/5 |
| 30 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 144 | 9,752 | 59.521% | A | Stage 2 + stages 3/5 |
| 31 | `haxeon.ui.core.RenderNode.onResolved` | `array` | 144 | 9,896 | 60.400% | A | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.widgets.text.TextField.buildField` | `array` | 144 | 10,040 | 61.279% | A | Stage 2 + stages 3/5 |
| 33 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.semantics.Semantics` | 136 | 10,176 | 62.109% | V | Stage 2 + stages 3/5 |
| 34 | `NativeKitUI.nkui_text_layout_get_line_rects` | `i32` | 128 | 10,304 | 62.891% | B | a2 |
| 35 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `Nkui_text_layout_caretOutResult` | 120 | 10,424 | 63.623% | N | Other: FFI query values |
| 36 | `$generic:nkui_text_metrics.new[]<>` | `<abstract>` | 112 | 10,536 | 64.307% | N | Other: FFI query values |
| 37 | `NativeKitUI.nkui_text_layout_get_line_rects` | `<abstract>` | 112 | 10,648 | 64.990% | N | Other: FFI query values |
| 38 | `haxeon.editor.TextDocumentBuffer.replace` | `<abstract>` | 112 | 10,760 | 65.674% | A | Other: text/storage |
| 39 | `haxeon.editor.TextDocumentBuffer.split` | `<abstract>` | 112 | 10,872 | 66.357% | A | Other: text/storage |
| 40 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 10,984 | 67.041% | N | Other: FFI query values |
| 41 | `haxeon.ui.TextLayout.lineRangeAt` | `<abstract>` | 112 | 11,096 | 67.725% | N | Other: FFI query values |
| 42 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 104 | 11,200 | 68.359% | N | Other: FFI query values |
| 43 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 96 | 11,296 | 68.945% | N | Stage 2 |
| 44 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `String` | 96 | 11,392 | 69.531% | A | Other: text/storage |
| 45 | `haxeon.ui.TextLayout.lineRangeAt` | `bytes` | 96 | 11,488 | 70.117% | N | Other: FFI query values |
| 46 | `haxeon.ui.widgets.text.TextEditorState.recordHistory` | `haxeon.ui.editing.EditOperation` | 96 | 11,584 | 70.703% | R | Other: text/history |
| 47 | `haxeon.editor.TextDocumentBuffer.split` | `haxeon.editor.TextOffsetMap` | 88 | 11,672 | 71.240% | R | Other: text/history |
| 48 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 88 | 11,760 | 71.777% | V | Stage 2 + stages 3/5 |
| 49 | `haxeon.ui.widgets.text.TextEditorLayout.measureRows` | `bytes` | 80 | 11,840 | 72.266% | N | Other: FFI query values |
| 50 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#handleKey=@2FE73567#0` | 80 | 11,920 | 72.754% | C | Stages 3/5 |
| 51 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 11,992 | 73.193% | A | Stage 2 + stages 3/5 |
| 52 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 12,064 | 73.633% | A | Stage 2 + stages 3/5 |
| 53 | `haxeon.editor.TextDocumentBuffer.replace` | `String` | 72 | 12,136 | 74.072% | A | Other: text/storage |
| 54 | `haxeon.editor.TextDocumentBuffer.replace` | `array` | 72 | 12,208 | 74.512% | A | Other: text/storage |
| 55 | `haxeon.editor.TextDocumentBuffer.split` | `array` | 72 | 12,280 | 74.951% | A | Other: text/storage |
| 56 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 12,352 | 75.391% | A | Stage 2 + stages 3/5 |
| 57 | `haxeon.ui.core.BuildContext.applyPatches` | `array` | 72 | 12,424 | 75.830% | A | Stage 2 + stages 3/5 |
| 58 | `haxeon.ui.widgets.text.TextEditorLayout.measureRows` | `array` | 72 | 12,496 | 76.270% | A | Stage 2 + stages 3/5 |
| 59 | `haxeon.ui.widgets.text.TextEditorState.applyTransaction` | `haxeon.ui.widgets.text.EditTransaction` | 72 | 12,568 | 76.709% | V | Stage 2 + stages 3/5 |
| 60 | `haxeon.ui.widgets.text.TextEditorState.replace` | `haxeon.ui.widgets.text.EditTransaction` | 72 | 12,640 | 77.148% | V | Stage 2 + stages 3/5 |
| 61 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 12,712 | 77.588% | A | Stage 2 + stages 3/5 |
| 62 | `$scalar-arguments:haxeon.ui.TextLayout.measure` | `i32` | 64 | 12,776 | 77.979% | B | a2 |
| 63 | `NativeKitUI.nkui_text_layout_get_line_rects` | `f64` | 64 | 12,840 | 78.369% | B | a2 |
| 64 | `haxeon.ui.TextLayout.edit` | `bytes` | 64 | 12,904 | 78.760% | N | Other: FFI query values |
| 65 | `haxeon.ui.TextLayout.edit` | `i32` | 64 | 12,968 | 79.150% | B | a2 |
| 66 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `array` | 64 | 13,032 | 79.541% | A | Stage 2 + stages 3/5 |
| 67 | `haxeon.ui.widgets.text.TextEditorLayout.measureRows` | `haxeon.ui.widgets.text.TextEditorParagraphRow` | 64 | 13,096 | 79.932% | V | Stage 2 + stages 3/5 |
| 68 | `haxeon.ui.widgets.text.TextEditorState.recordHistory` | `(void ())` | 64 | 13,160 | 80.322% | C | Stages 3/5 |
| 69 | `haxeon.ui.widgets.text.TextEditorState.recordHistory` | `haxeon.ui.widgets.text.FieldHistoryEdit` | 64 | 13,224 | 80.713% | V | Stage 2 + stages 3/5 |
| 70 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#on(1)@4D1ACD20#0` | 64 | 13,288 | 81.104% | C | Stages 3/5 |
| 71 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#onResolved(0)@55649E74#1` | 64 | 13,352 | 81.494% | C | Stages 3/5 |
| 72 | `haxeon.ui.widgets.text.TextField.buildField` | `(bool ())` | 64 | 13,416 | 81.885% | C | Stages 3/5 |
| 73 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (bool))` | 64 | 13,480 | 82.275% | C | Stages 3/5 |
| 74 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (haxeon.ui.ResolvedLayoutItem))` | 64 | 13,544 | 82.666% | C | Stages 3/5 |
| 75 | `$scalar-arguments:haxeon.ui.LayoutNode.set_textStyle` | `haxeon.ui.LayoutTextStyles` | 56 | 13,600 | 83.008% | V | Stage 2 + stages 3/5 |
| 76 | `NativeKitUI.nkui_layout_session_submit_slice` | `<abstract>` | 56 | 13,656 | 83.350% | N | Stage 2 |
| 77 | `haxeon.editor.TextDocumentBuffer.replace` | `bytes` | 56 | 13,712 | 83.691% | A | Other: text/storage |
| 78 | `haxeon.editor.TextOffsetMap.new` | `<abstract>` | 56 | 13,768 | 84.033% | A | Other: text/storage |
| 79 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 56 | 13,824 | 84.375% | N | Other: FFI query values |
| 80 | `haxeon.ui.LayoutSession.submit` | `<abstract>` | 56 | 13,880 | 84.717% | N | Other: FFI query values |
| 81 | `haxeon.ui.LayoutTransaction.appendNode` | `<abstract>` | 56 | 13,936 | 85.059% | N | Stage 2 |
| 82 | `haxeon.ui.core.EventDispatcher.setRoot` | `array` | 56 | 13,992 | 85.400% | A | Stage 2 + stages 3/5 |
| 83 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#blur=@2A031C8D#0` | 56 | 14,048 | 85.742% | C | Stages 3/5 |
| 84 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.style.StyleTarget` | 56 | 14,104 | 86.084% | V | Stage 2 + stages 3/5 |
| 85 | `$scalar-arguments:haxeon.ui.TextLayout.measure` | `Nkui_text_layout_measureOutResult` | 48 | 14,152 | 86.377% | N | Other: FFI query values |
| 86 | `NativeKitUI.nkui_layout_session_submit_slice` | `i32` | 48 | 14,200 | 86.670% | B | a2 |
| 87 | `NativeKitUI.nkui_text_layout_get_line_rects` | `realtime_bytes` | 48 | 14,248 | 86.963% | N | Other: FFI query values |
| 88 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 48 | 14,296 | 87.256% | B | a2 |
| 89 | `haxeon.ui.LayoutSession.submit` | `i32` | 48 | 14,344 | 87.549% | B | a2 |
| 90 | `haxeon.ui.TextLayout.lineRangeAt` | `i32` | 48 | 14,392 | 87.842% | B | a2 |
| 91 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `haxeon.ui.debug.UiStyleInvalidationMetrics` | 48 | 14,440 | 88.135% | O | Other |
| 92 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 48 | 14,488 | 88.428% | V | Stage 2 + stages 3/5 |
| 93 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#on(1)@0BA15AC4#2` | 48 | 14,536 | 88.721% | C | Stages 3/5 |
| 94 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#on(1)@6A65C95D#1` | 48 | 14,584 | 89.014% | C | Stages 3/5 |
| 95 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#onPaint(0)@2662C487#3` | 48 | 14,632 | 89.307% | C | Stages 3/5 |
| 96 | `haxeon.ui.widgets.text.TextField.buildField` | `@haxeon.ui.ParagraphStyle` | 48 | 14,680 | 89.600% | B | Other: value ABI |
| 97 | `haxeon.ui.widgets.text.TextField.buildField` | `@haxeon.ui.TextStyle` | 48 | 14,728 | 89.893% | B | Other: value ABI |
| 98 | `haxeon.editor.TextDocumentBuffer.split` | `bytes` | 40 | 14,768 | 90.137% | A | Other: text/storage |

Displayed sites: 14,768 bytes. Classified remainder below the cutoff: **1,616 bytes**.

### interaction: type-backspace

Exact total: **432 objects / 16,992 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.core.RenderNode` | 1,120 | 1,120 | 6.591% | V | Stage 2 + stages 3/5 |
| 2 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.LayoutStyle` | 1,032 | 2,152 | 12.665% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.core.HitTest.pathTo` | `array` | 712 | 2,864 | 16.855% | A | Stage 2 + stages 3/5 |
| 4 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `bytes` | 480 | 3,344 | 19.680% | N | Other: FFI query values |
| 5 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 480 | 3,824 | 22.505% | V | Stage 2 + stages 3/5 |
| 6 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `bytes` | 464 | 4,288 | 25.235% | A | Other: text/storage |
| 7 | `haxeon.editor.TextOffsetMap.new` | `array` | 424 | 4,712 | 27.731% | A | Other: text/storage |
| 8 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 416 | 5,128 | 30.179% | V | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (haxeon.ui.core.UiEvent))` | 352 | 5,480 | 32.250% | C | Stages 3/5 |
| 10 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 344 | 5,824 | 34.275% | V | Stage 2 + stages 3/5 |
| 11 | `$generic:nkui_text_position.new[]<>` | `<abstract>` | 336 | 6,160 | 36.252% | N | Other: FFI query values |
| 12 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 320 | 6,480 | 38.136% | A | Stage 2 + stages 3/5 |
| 13 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 304 | 6,784 | 39.925% | A | Stage 2 + stages 3/5 |
| 14 | `$generic:nkui_text_caret.new[]<>` | `<abstract>` | 280 | 7,064 | 41.573% | N | Other: FFI query values |
| 15 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 280 | 7,344 | 43.220% | V | Stage 2 + stages 3/5 |
| 16 | `haxeon.ui.core.UiContext.submitInternal` | `haxeon.ui.debug.UiFrameMetrics` | 264 | 7,608 | 44.774% | O | Other |
| 17 | `haxeon.editor.TextDocumentBuffer.reindex` | `array` | 224 | 7,832 | 46.092% | A | Other: text/storage |
| 18 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `<abstract>` | 216 | 8,048 | 47.363% | A | Other: text/storage |
| 19 | `haxeon.ui.widgets.text.TextEditorLayout.setTextAfterEdit` | `array` | 216 | 8,264 | 48.635% | A | Stage 2 + stages 3/5 |
| 20 | `robotkit.world.RobotWorld.robotIds` | `array` | 216 | 8,480 | 49.906% | A | Stage 2 + stages 3/5 |
| 21 | `NativeKitUI.nkui_text_layout_get_line_rects` | `bytes` | 192 | 8,672 | 51.036% | N | Other: FFI query values |
| 22 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 168 | 8,840 | 52.024% | N | Stage 2 |
| 23 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `i32` | 160 | 9,000 | 52.966% | B | a2 |
| 24 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `realtime_bytes` | 160 | 9,160 | 53.908% | N | Other: FFI query values |
| 25 | `haxeon.ui.core.EventDispatcher.key` | `haxeon.ui.core.UiEvent` | 160 | 9,320 | 54.849% | V | Stage 2 + stages 3/5 |
| 26 | `haxeon.editor.TextDocumentBuffer.get_text` | `bytes` | 152 | 9,472 | 55.744% | A | Other: text/storage |
| 27 | `$scalar-arguments:haxeon.ui.TextLayout.measure` | `bytes` | 144 | 9,616 | 56.591% | N | Other: FFI query values |
| 28 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `String` | 144 | 9,760 | 57.439% | A | Other: text/storage |
| 29 | `haxeon.ui.LayoutNode.add` | `array` | 144 | 9,904 | 58.286% | A | Stage 2 + stages 3/5 |
| 30 | `haxeon.ui.core.RenderNode.add` | `array` | 144 | 10,048 | 59.134% | A | Stage 2 + stages 3/5 |
| 31 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 144 | 10,192 | 59.981% | A | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.core.RenderNode.onResolved` | `array` | 144 | 10,336 | 60.829% | A | Stage 2 + stages 3/5 |
| 33 | `haxeon.ui.widgets.text.TextField.buildField` | `array` | 144 | 10,480 | 61.676% | A | Stage 2 + stages 3/5 |
| 34 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.semantics.Semantics` | 136 | 10,616 | 62.476% | V | Stage 2 + stages 3/5 |
| 35 | `NativeKitUI.nkui_text_layout_get_line_rects` | `i32` | 128 | 10,744 | 63.230% | B | a2 |
| 36 | `$scalar-arguments:haxeon.ui.TextLayout.caretAt` | `Nkui_text_layout_caretOutResult` | 120 | 10,864 | 63.936% | N | Other: FFI query values |
| 37 | `$generic:nkui_text_metrics.new[]<>` | `<abstract>` | 112 | 10,976 | 64.595% | N | Other: FFI query values |
| 38 | `NativeKitUI.nkui_text_layout_get_line_rects` | `<abstract>` | 112 | 11,088 | 65.254% | N | Other: FFI query values |
| 39 | `haxeon.editor.TextDocumentBuffer.replace` | `<abstract>` | 112 | 11,200 | 65.913% | A | Other: text/storage |
| 40 | `haxeon.editor.TextDocumentBuffer.split` | `<abstract>` | 112 | 11,312 | 66.573% | A | Other: text/storage |
| 41 | `haxeon.ui.LayoutSession.submit` | `bytes` | 112 | 11,424 | 67.232% | N | Other: FFI query values |
| 42 | `haxeon.ui.TextLayout.lineRangeAt` | `<abstract>` | 112 | 11,536 | 67.891% | N | Other: FFI query values |
| 43 | `haxeon.ui.LayoutSession.hitTestInto` | `bytes` | 104 | 11,640 | 68.503% | N | Other: FFI query values |
| 44 | `NativeKitUI.nkui_layout_session_submit_slice` | `bytes` | 96 | 11,736 | 69.068% | N | Stage 2 |
| 45 | `haxeon.ui.TextLayout.lineRangeAt` | `bytes` | 96 | 11,832 | 69.633% | N | Other: FFI query values |
| 46 | `haxeon.ui.widgets.text.TextEditorState.recordHistory` | `haxeon.ui.editing.EditOperation` | 96 | 11,928 | 70.198% | R | Other: text/history |
| 47 | `haxeon.editor.TextDocumentBuffer.split` | `haxeon.editor.TextOffsetMap` | 88 | 12,016 | 70.716% | R | Other: text/history |
| 48 | `haxeon.ui.TextLayout.previousGrapheme` | `bytes` | 88 | 12,104 | 71.234% | N | Other: FFI query values |
| 49 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 88 | 12,192 | 71.751% | V | Stage 2 + stages 3/5 |
| 50 | `haxeon.ui.widgets.text.TextEditorLayout.measureRows` | `bytes` | 80 | 12,272 | 72.222% | N | Other: FFI query values |
| 51 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#handleKey=@2FE73567#0` | 80 | 12,352 | 72.693% | C | Stages 3/5 |
| 52 | `app.ApplicationSimulation.simulatedRobotIds` | `array` | 72 | 12,424 | 73.117% | A | Stage 2 + stages 3/5 |
| 53 | `app.ReferenceEditorApp.updateReadOnlyRobots` | `array` | 72 | 12,496 | 73.540% | A | Stage 2 + stages 3/5 |
| 54 | `haxeon.editor.TextDocumentBuffer.replace` | `String` | 72 | 12,568 | 73.964% | A | Other: text/storage |
| 55 | `haxeon.editor.TextDocumentBuffer.replace` | `array` | 72 | 12,640 | 74.388% | A | Other: text/storage |
| 56 | `haxeon.editor.TextDocumentBuffer.split` | `array` | 72 | 12,712 | 74.812% | A | Other: text/storage |
| 57 | `haxeon.ui.animation.AnimationScheduler.advance` | `array` | 72 | 12,784 | 75.235% | A | Stage 2 + stages 3/5 |
| 58 | `haxeon.ui.core.BuildContext.applyPatches` | `array` | 72 | 12,856 | 75.659% | A | Stage 2 + stages 3/5 |
| 59 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `array` | 72 | 12,928 | 76.083% | A | Stage 2 + stages 3/5 |
| 60 | `haxeon.ui.widgets.text.TextEditorLayout.measureRows` | `array` | 72 | 13,000 | 76.507% | A | Stage 2 + stages 3/5 |
| 61 | `haxeon.ui.widgets.text.TextEditorState.applyTransaction` | `haxeon.ui.widgets.text.EditTransaction` | 72 | 13,072 | 76.930% | V | Stage 2 + stages 3/5 |
| 62 | `haxeon.ui.widgets.text.TextEditorState.replace` | `haxeon.ui.widgets.text.EditTransaction` | 72 | 13,144 | 77.354% | V | Stage 2 + stages 3/5 |
| 63 | `tests.HeadlessEditorProfile.submit` | `array` | 72 | 13,216 | 77.778% | A | Stage 2 + stages 3/5 |
| 64 | `$scalar-arguments:haxeon.ui.TextLayout.measure` | `i32` | 64 | 13,280 | 78.154% | B | a2 |
| 65 | `NativeKitUI.nkui_text_layout_get_line_rects` | `f64` | 64 | 13,344 | 78.531% | B | a2 |
| 66 | `haxeon.ui.TextLayout.edit` | `bytes` | 64 | 13,408 | 78.908% | N | Other: FFI query values |
| 67 | `haxeon.ui.TextLayout.edit` | `i32` | 64 | 13,472 | 79.284% | B | a2 |
| 68 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `array` | 64 | 13,536 | 79.661% | A | Stage 2 + stages 3/5 |
| 69 | `haxeon.ui.widgets.text.TextEditorLayout.measureRows` | `haxeon.ui.widgets.text.TextEditorParagraphRow` | 64 | 13,600 | 80.038% | V | Stage 2 + stages 3/5 |
| 70 | `haxeon.ui.widgets.text.TextEditorState.recordHistory` | `(void ())` | 64 | 13,664 | 80.414% | C | Stages 3/5 |
| 71 | `haxeon.ui.widgets.text.TextEditorState.recordHistory` | `haxeon.ui.widgets.text.FieldHistoryEdit` | 64 | 13,728 | 80.791% | V | Stage 2 + stages 3/5 |
| 72 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#on(1)@4D1ACD20#0` | 64 | 13,792 | 81.168% | C | Stages 3/5 |
| 73 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#onResolved(0)@55649E74#1` | 64 | 13,856 | 81.544% | C | Stages 3/5 |
| 74 | `haxeon.ui.widgets.text.TextField.buildField` | `(bool ())` | 64 | 13,920 | 81.921% | C | Stages 3/5 |
| 75 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (bool))` | 64 | 13,984 | 82.298% | C | Stages 3/5 |
| 76 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (haxeon.ui.ResolvedLayoutItem))` | 64 | 14,048 | 82.674% | C | Stages 3/5 |
| 77 | `$scalar-arguments:haxeon.ui.LayoutNode.set_textStyle` | `haxeon.ui.LayoutTextStyles` | 56 | 14,104 | 83.004% | V | Stage 2 + stages 3/5 |
| 78 | `NativeKitUI.nkui_layout_session_submit_slice` | `<abstract>` | 56 | 14,160 | 83.333% | N | Stage 2 |
| 79 | `haxeon.editor.TextDocumentBuffer.replace` | `bytes` | 56 | 14,216 | 83.663% | A | Other: text/storage |
| 80 | `haxeon.editor.TextOffsetMap.new` | `<abstract>` | 56 | 14,272 | 83.992% | A | Other: text/storage |
| 81 | `haxeon.ui.LayoutSession.hitTestInto` | `<abstract>` | 56 | 14,328 | 84.322% | N | Other: FFI query values |
| 82 | `haxeon.ui.LayoutSession.submit` | `<abstract>` | 56 | 14,384 | 84.652% | N | Other: FFI query values |
| 83 | `haxeon.ui.LayoutTransaction.appendNode` | `<abstract>` | 56 | 14,440 | 84.981% | N | Stage 2 |
| 84 | `haxeon.ui.TextLayout.previousGrapheme` | `<abstract>` | 56 | 14,496 | 85.311% | N | Other: FFI query values |
| 85 | `haxeon.ui.core.EventDispatcher.setRoot` | `array` | 56 | 14,552 | 85.640% | A | Stage 2 + stages 3/5 |
| 86 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#blur=@2A031C8D#0` | 56 | 14,608 | 85.970% | C | Stages 3/5 |
| 87 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.style.StyleTarget` | 56 | 14,664 | 86.299% | V | Stage 2 + stages 3/5 |
| 88 | `$scalar-arguments:haxeon.ui.TextLayout.measure` | `Nkui_text_layout_measureOutResult` | 48 | 14,712 | 86.582% | N | Other: FFI query values |
| 89 | `NativeKitUI.nkui_layout_session_submit_slice` | `i32` | 48 | 14,760 | 86.864% | B | a2 |
| 90 | `NativeKitUI.nkui_text_layout_get_line_rects` | `realtime_bytes` | 48 | 14,808 | 87.147% | N | Other: FFI query values |
| 91 | `haxeon.editor.TextDocumentBuffer.sliceCodepoints` | `StringBuf` | 48 | 14,856 | 87.429% | A | Other: text/storage |
| 92 | `haxeon.ui.LayoutSession.hitTestInto` | `i32` | 48 | 14,904 | 87.712% | B | a2 |
| 93 | `haxeon.ui.LayoutSession.submit` | `i32` | 48 | 14,952 | 87.994% | B | a2 |
| 94 | `haxeon.ui.TextLayout.lineRangeAt` | `i32` | 48 | 15,000 | 88.277% | B | a2 |
| 95 | `haxeon.ui.TextLayout.previousGrapheme` | `i32` | 48 | 15,048 | 88.559% | B | a2 |
| 96 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `haxeon.ui.debug.UiStyleInvalidationMetrics` | 48 | 15,096 | 88.842% | O | Other |
| 97 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 48 | 15,144 | 89.124% | V | Stage 2 + stages 3/5 |
| 98 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#on(1)@0BA15AC4#2` | 48 | 15,192 | 89.407% | C | Stages 3/5 |
| 99 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#on(1)@6A65C95D#1` | 48 | 15,240 | 89.689% | C | Stages 3/5 |
| 100 | `haxeon.ui.widgets.text.TextField.buildField` | `$lambda-env:haxeon.ui.widgets.text.TextField.buildField:buildField#onPaint(0)@2662C487#3` | 48 | 15,288 | 89.972% | C | Stages 3/5 |
| 101 | `haxeon.ui.widgets.text.TextField.buildField` | `@haxeon.ui.ParagraphStyle` | 48 | 15,336 | 90.254% | B | Other: value ABI |

Displayed sites: 15,336 bytes. Classified remainder below the cutoff: **1,656 bytes**.

### selection-stress: selection

Exact total: **8,593 objects / 579,512 bytes**.

| Rank | Allocating function | Allocated type | Bytes | Cumulative bytes | Cumulative % | Cause | Removal queue |
|---:|---|---|---:|---:|---:|---|---|
| 1 | `haxeon.ui.style.ComputedStyle.toLayoutStyle` | `haxeon.ui.LayoutStyle` | 30,272 | 30,272 | 5.224% | V | Stage 2 + stages 3/5 |
| 2 | `haxeon.ui.core.RenderNode.new` | `haxeon.ui.LayoutNode` | 28,800 | 59,072 | 10.193% | V | Stage 2 + stages 3/5 |
| 3 | `haxeon.ui.LayoutStyle.copy` | `haxeon.ui.LayoutStyle` | 27,520 | 86,592 | 14.942% | V | Stage 2 + stages 3/5 |
| 4 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#walk(0)@51258B06#2` | `array` | 22,976 | 109,568 | 18.907% | A | Stage 2 + stages 3/5 |
| 5 | `haxeon.ui.ResolvedLayoutItem.decode` | `haxeon.ui.ResolvedLayoutItem` | 18,816 | 128,384 | 22.154% | N | Stage 2 |
| 6 | `haxeon.ui.core.RenderNode.addHandler` | `haxeon.ui.core.HandlerEntry` | 12,800 | 141,184 | 24.363% | V | Stage 2 + stages 3/5 |
| 7 | `haxeon.ui.core.RenderNode.addHandler` | `array` | 10,720 | 151,904 | 26.212% | A | Stage 2 + stages 3/5 |
| 8 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.Icon.new` | `haxeon.ui.LayoutStyle` | 10,664 | 162,568 | 28.053% | V | Stage 2 + stages 3/5 |
| 9 | `haxeon.ui.LayoutNode.add` | `array` | 10,408 | 172,976 | 29.849% | A | Stage 2 + stages 3/5 |
| 10 | `haxeon.ui.core.RenderNode.add` | `array` | 10,408 | 183,384 | 31.645% | A | Stage 2 + stages 3/5 |
| 11 | `haxeon.reactive.ReactiveDependencySet.trackField` | `haxeon.reactive.ReactiveEdge` | 9,936 | 193,320 | 33.359% | T | Stages 3/5 |
| 12 | `haxeon.ui.core.InteractionStateSnapshot.capture` | `array` | 8,952 | 202,272 | 34.904% | A | Stage 2 + stages 3/5 |
| 13 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `haxeon.ui.core.RenderNode` | 8,680 | 210,952 | 36.402% | V | Stage 2 + stages 3/5 |
| 14 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `haxeon.ui.LayoutStyle` | 8,256 | 219,208 | 37.826% | V | Stage 2 + stages 3/5 |
| 15 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `haxeon.ui.LayoutStyle` | 7,912 | 227,120 | 39.192% | V | Stage 2 + stages 3/5 |
| 16 | `$lambda:haxeon.ui.widgets.docking.DockPanelCacheEntry.new:new#capture@4787D009#0` | `array` | 7,600 | 234,720 | 40.503% | A | Stage 2 + stages 3/5 |
| 17 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `haxeon.ui.core.RenderNode` | 6,720 | 241,440 | 41.663% | V | Stage 2 + stages 3/5 |
| 18 | `haxeon.ui.core.RenderNode.onPaint` | `array` | 6,624 | 248,064 | 42.806% | A | Stage 2 + stages 3/5 |
| 19 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `haxeon.ui.core.RenderNode` | 6,440 | 254,504 | 43.917% | V | Stage 2 + stages 3/5 |
| 20 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.text.Text.new` | `haxeon.ui.LayoutStyle` | 6,192 | 260,696 | 44.985% | V | Stage 2 + stages 3/5 |
| 21 | `haxeon.ui.widgets.controls.Button.new` | `haxeon.ui.LayoutStyle` | 5,848 | 266,544 | 45.995% | V | Stage 2 + stages 3/5 |
| 22 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.RenderNode` | 5,600 | 272,144 | 46.961% | V | Stage 2 + stages 3/5 |
| 23 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.core.RenderNode` | 5,040 | 277,184 | 47.831% | V | Stage 2 + stages 3/5 |
| 24 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `haxeon.ui.core.RenderNode` | 4,480 | 281,664 | 48.604% | V | Stage 2 + stages 3/5 |
| 25 | `haxeon.ui.core.BuildContext.resolveTextRole` | `haxeon.ui.core.ResolvedTextStyle` | 4,224 | 285,888 | 49.333% | V | Stage 2 + stages 3/5 |
| 26 | `haxeon.ui.style.ComputedStyle.fork` | `haxeon.ui.style.ComputedStyle` | 4,224 | 290,112 | 50.061% | V | Stage 2 + stages 3/5 |
| 27 | `haxeon.ui.LayoutNode.new` | `haxeon.ui.LayoutStyle` | 3,784 | 293,896 | 50.714% | V | Stage 2 + stages 3/5 |
| 28 | `$lambda:haxeon.ui.widgets.controls.Tabs.buildControl:buildControl#panel=/withScope(1)@0F620F35#0` | `haxeon.ui.LayoutStyle` | 3,440 | 297,336 | 51.308% | V | Stage 2 + stages 3/5 |
| 29 | `haxeon.ui.widgets.text.Text.build` | `haxeon.ui.core.RenderNode` | 3,360 | 300,696 | 51.888% | V | Stage 2 + stages 3/5 |
| 30 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.layout.Spacer.new` | `haxeon.ui.LayoutStyle` | 3,096 | 303,792 | 52.422% | V | Stage 2 + stages 3/5 |
| 31 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `haxeon.ui.LayoutStyle` | 3,096 | 306,888 | 52.956% | V | Stage 2 + stages 3/5 |
| 32 | `haxeon.ui.core.RenderNode.onResolved` | `array` | 2,880 | 309,768 | 53.453% | A | Stage 2 + stages 3/5 |
| 33 | `haxeon.ui.widgets.controls.Button.buildButton` | `array` | 2,880 | 312,648 | 53.950% | A | Stage 2 + stages 3/5 |
| 34 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `bytes` | 2,816 | 315,464 | 54.436% | A | Stage 2 + stages 3/5 |
| 35 | `haxeon.ui.style.StyleResolver.keyHash` | `bytes` | 2,816 | 318,280 | 54.922% | A | Stage 2 + stages 3/5 |
| 36 | `$lambda:haxeon.ui.widgets.controls.Tabs.buildControl:buildControl#panel=/withScope(1)@0F620F35#0` | `haxeon.ui.core.RenderNode` | 2,800 | 321,080 | 55.405% | V | Stage 2 + stages 3/5 |
| 37 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `haxeon.ui.LayoutStyle` | 2,752 | 323,832 | 55.880% | V | Stage 2 + stages 3/5 |
| 38 | `haxeon.ui.core.BuildContext.selfUpdating` | `haxeon.ui.core.SelfUpdatingBuild` | 2,728 | 326,560 | 56.351% | V | Stage 2 + stages 3/5 |
| 39 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.semantics.Semantics` | 2,720 | 329,280 | 56.820% | V | Stage 2 + stages 3/5 |
| 40 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.RenderNode` | 2,520 | 331,800 | 57.255% | V | Stage 2 + stages 3/5 |
| 41 | `$lambda:haxeon.ui.widgets.layout.Spacer.build:build#return/withScope(1)@73D0EA11#0` | `haxeon.ui.core.RenderNode` | 2,520 | 334,320 | 57.690% | V | Stage 2 + stages 3/5 |
| 42 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `haxeon.ui.core.RenderNode` | 2,520 | 336,840 | 58.125% | V | Stage 2 + stages 3/5 |
| 43 | `haxeon.ui.core.KeyScope.child` | `bytes` | 2,464 | 339,304 | 58.550% | A | Stage 2 + stages 3/5 |
| 44 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `(void (haxeon.ui.core.UiEvent))` | 2,304 | 341,608 | 58.948% | C | Stages 3/5 |
| 45 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.core.RenderNode` | 2,240 | 343,848 | 59.334% | V | Stage 2 + stages 3/5 |
| 46 | `haxeon.ui.core.RenderNode.snapshotBuilt` | `array` | 2,232 | 346,080 | 59.719% | A | Stage 2 + stages 3/5 |
| 47 | `haxeon.ui.widgets.properties.PropertyEditor.isPristine` | `array` | 2,160 | 348,240 | 60.092% | A | Stage 2 + stages 3/5 |
| 48 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `haxeon.ui.widgets.controls.Button` | 2,080 | 350,320 | 60.451% | V | Stage 2 + stages 3/5 |
| 49 | `haxeon.ui.widgets.controls.Tabs.installTabDragHandlers` | `(void (haxeon.ui.core.UiEvent))` | 2,080 | 352,400 | 60.810% | C | Stages 3/5 |
| 50 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `haxeon.ui.LayoutStyle` | 2,064 | 354,464 | 61.166% | V | Stage 2 + stages 3/5 |
| 51 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `haxeon.ui.LayoutStyle` | 2,064 | 356,528 | 61.522% | V | Stage 2 + stages 3/5 |
| 52 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.LayoutStyle` | 2,064 | 358,592 | 61.878% | V | Stage 2 + stages 3/5 |
| 53 | `$lambda:haxeon.ui.widgets.text.MiddleEllipsisText.build:build#return/withScope(1)@6F81BB0B#0` | `haxeon.ui.LayoutStyle` | 2,064 | 360,656 | 62.234% | V | Stage 2 + stages 3/5 |
| 54 | `app.ReferenceEditorApp.fillStyle` | `haxeon.ui.LayoutStyle` | 2,064 | 362,720 | 62.591% | V | Stage 2 + stages 3/5 |
| 55 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.LayoutStyle` | 2,064 | 364,784 | 62.947% | V | Stage 2 + stages 3/5 |
| 56 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.LayoutStyle` | 2,064 | 366,848 | 63.303% | V | Stage 2 + stages 3/5 |
| 57 | `haxeon.ui.widgets.layout.SplitView.paneStyle` | `haxeon.ui.LayoutStyle` | 2,064 | 368,912 | 63.659% | V | Stage 2 + stages 3/5 |
| 58 | `haxeon.ui.core.StateStore.usedIdsSince` | `array` | 2,024 | 370,936 | 64.008% | A | Stage 2 + stages 3/5 |
| 59 | `haxeon.ui.core.RenderNode.snapshotBuilt` | `haxeon.ui.core.BuiltNode` | 1,984 | 372,920 | 64.351% | V | Stage 2 + stages 3/5 |
| 60 | `haxeon.ui.widgets.docking.DockPanelCacheEntry.new` | `array` | 1,896 | 374,816 | 64.678% | A | Stage 2 + stages 3/5 |
| 61 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `String` | 1,872 | 376,688 | 65.001% | A | Stage 2 + stages 3/5 |
| 62 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.widgets.Icon` | 1,848 | 378,536 | 65.320% | V | Stage 2 + stages 3/5 |
| 63 | `haxeon.ui.LayoutTransaction.appendNode` | `<abstract>` | 1,792 | 380,328 | 65.629% | N | Stage 2 |
| 64 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `array` | 1,728 | 382,056 | 65.927% | A | Stage 2 + stages 3/5 |
| 65 | `haxeon.ui.widgets.text.Text.build` | `array` | 1,728 | 383,784 | 66.225% | A | Stage 2 + stages 3/5 |
| 66 | `haxeon.ui.widgets.controls.Tabs.scrollStrip` | `haxeon.ui.LayoutStyle` | 1,720 | 385,504 | 66.522% | V | Stage 2 + stages 3/5 |
| 67 | `haxeon.ui.core.InteractionStateSnapshot.appendStateIds` | `array` | 1,696 | 387,200 | 66.815% | A | Stage 2 + stages 3/5 |
| 68 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `haxeon.ui.core.RenderNode` | 1,680 | 388,880 | 67.105% | V | Stage 2 + stages 3/5 |
| 69 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `haxeon.ui.core.RenderNode` | 1,680 | 390,560 | 67.395% | V | Stage 2 + stages 3/5 |
| 70 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `haxeon.ui.core.RenderNode` | 1,680 | 392,240 | 67.685% | V | Stage 2 + stages 3/5 |
| 71 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.core.RenderNode` | 1,680 | 393,920 | 67.974% | V | Stage 2 + stages 3/5 |
| 72 | `haxeon.ui.widgets.layout.SplitView.paneContent` | `haxeon.ui.core.RenderNode` | 1,680 | 395,600 | 68.264% | V | Stage 2 + stages 3/5 |
| 73 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.core.RenderNode` | 1,680 | 397,280 | 68.554% | V | Stage 2 + stages 3/5 |
| 74 | `haxeon.ui.style.StyleTarget.shared` | `array` | 1,656 | 398,936 | 68.840% | A | Stage 2 + stages 3/5 |
| 75 | `haxeon.ui.widgets.text.Text.build` | `haxeon.ui.semantics.Semantics` | 1,632 | 400,568 | 69.122% | V | Stage 2 + stages 3/5 |
| 76 | `haxeon.ui.widgets.text.Text.build` | `haxeon.ui.core.ResolvedTextStyle` | 1,584 | 402,152 | 69.395% | V | Stage 2 + stages 3/5 |
| 77 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `(void (haxeon.ui.core.UiEvent))` | 1,536 | 403,688 | 69.660% | C | Stages 3/5 |
| 78 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.widgets.overlays.Tooltip` | 1,536 | 405,224 | 69.925% | V | Stage 2 + stages 3/5 |
| 79 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `$lambda-env:$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0:build#onPaint(0)@3C40BFBF#0` | 1,488 | 406,712 | 70.182% | C | Stages 3/5 |
| 80 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `bytes` | 1,488 | 408,200 | 70.439% | A | Stage 2 + stages 3/5 |
| 81 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `bytes` | 1,440 | 409,640 | 70.687% | A | Stage 2 + stages 3/5 |
| 82 | `haxeon.ui.widgets.controls.Button.new` | `array` | 1,440 | 411,080 | 70.936% | A | Stage 2 + stages 3/5 |
| 83 | `haxeon.ui.widgets.controls.Button.styleTarget` | `array` | 1,440 | 412,520 | 71.184% | A | Stage 2 + stages 3/5 |
| 84 | `haxeon.ui.widgets.controls.Tabs.buildControl` | `haxeon.ui.core.RenderNode` | 1,400 | 413,920 | 71.426% | V | Stage 2 + stages 3/5 |
| 85 | `$lambda:haxeon.ui.widgets.controls.SearchField.build:build#return/withScope(1)@2EFCE4BB#0` | `haxeon.ui.LayoutStyle` | 1,376 | 415,296 | 71.663% | V | Stage 2 + stages 3/5 |
| 86 | `haxeon.ui.widgets.text.TextField.buildField` | `haxeon.ui.LayoutStyle` | 1,376 | 416,672 | 71.900% | V | Stage 2 + stages 3/5 |
| 87 | `app.editor.SceneTreeRow.buildRow` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 1,344 | 418,016 | 72.132% | V | Stage 2 + stages 3/5 |
| 88 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `String` | 1,296 | 419,312 | 72.356% | A | Stage 2 + stages 3/5 |
| 89 | `app.editor.SceneTreeRow.buildRow` | `array` | 1,296 | 420,608 | 72.580% | A | Stage 2 + stages 3/5 |
| 90 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `array` | 1,296 | 421,904 | 72.803% | A | Stage 2 + stages 3/5 |
| 91 | `$scalar-arguments:haxeon.ui.LayoutNode.set_textStyle` | `haxeon.ui.LayoutTextStyles` | 1,288 | 423,192 | 73.026% | V | Stage 2 + stages 3/5 |
| 92 | `app.editor.SceneTreeRow.buildRow` | `bytes` | 1,264 | 424,456 | 73.244% | A | Stage 2 + stages 3/5 |
| 93 | `$lambda:tests.HeadlessEditorProfile.submit:submit#buildProbe=@305D61CA#0` | `bytes` | 1,248 | 425,704 | 73.459% | A | Stage 2 + stages 3/5 |
| 94 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `array` | 1,152 | 426,856 | 73.658% | A | Stage 2 + stages 3/5 |
| 95 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `array` | 1,152 | 428,008 | 73.857% | A | Stage 2 + stages 3/5 |
| 96 | `haxeon.ui.widgets.text.Text.build` | `haxeon.ui.core.TextStyleOverride` | 1,152 | 429,160 | 74.055% | V | Stage 2 + stages 3/5 |
| 97 | `haxeon.ui.core.BuildContext.pruneKeyCaches` | `bytes` | 1,120 | 430,280 | 74.249% | A | Stage 2 + stages 3/5 |
| 98 | `haxeon.ui.core.StateStore.prunePaths` | `bytes` | 1,120 | 431,400 | 74.442% | A | Stage 2 + stages 3/5 |
| 99 | `haxeon.ui.widgets.controls.Button.styleTarget` | `haxeon.ui.style.StyleTarget` | 1,120 | 432,520 | 74.635% | V | Stage 2 + stages 3/5 |
| 100 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `haxeon.ui.semantics.Semantics` | 1,088 | 433,608 | 74.823% | V | Stage 2 + stages 3/5 |
| 101 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.widgets.text.Text` | 1,056 | 434,664 | 75.005% | V | Stage 2 + stages 3/5 |
| 102 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `(void (haxeon.ui.core.UiEvent))` | 1,056 | 435,720 | 75.187% | C | Stages 3/5 |
| 103 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `bytes` | 1,032 | 436,752 | 75.365% | A | Stage 2 + stages 3/5 |
| 104 | `haxeon.ui.widgets.layout.SplitView.defaultStyle` | `haxeon.ui.LayoutStyle` | 1,032 | 437,784 | 75.544% | V | Stage 2 + stages 3/5 |
| 105 | `haxeon.ui.widgets.layout.SplitView.new` | `haxeon.ui.LayoutStyle` | 1,032 | 438,816 | 75.722% | V | Stage 2 + stages 3/5 |
| 106 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `$lambda-env:$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0:build#onResolved(0)@6E866FD2#0` | 1,024 | 439,840 | 75.898% | C | Stages 3/5 |
| 107 | `haxeon.ui.widgets.KeyedView.new` | `haxeon.ui.core.Key` | 1,024 | 440,864 | 76.075% | V | Stage 2 + stages 3/5 |
| 108 | `app.editor.SceneTreeRow.buildRow` | `String` | 1,008 | 441,872 | 76.249% | A | Stage 2 + stages 3/5 |
| 109 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `(void (haxeon.ui.Canvas,haxeon.ui.ResolvedLayoutItem))` | 992 | 442,864 | 76.420% | C | Stages 3/5 |
| 110 | `haxeon.ui.widgets.collections.TreeView.new` | `<abstract>` | 992 | 443,856 | 76.591% | M | a2 |
| 111 | `haxeon.ui.widgets.controls.Button.buildButton` | `(haxeon.ui.core.RenderNode ())` | 992 | 444,848 | 76.763% | C | Stages 3/5 |
| 112 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `array` | 976 | 445,824 | 76.931% | A | Stage 2 + stages 3/5 |
| 113 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `(void (haxeon.ui.core.UiEvent))` | 960 | 446,784 | 77.097% | C | Stages 3/5 |
| 114 | `$lambda:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | `haxeon.ui.core.TextStyleOverride` | 864 | 447,648 | 77.246% | V | Stage 2 + stages 3/5 |
| 115 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `array` | 864 | 448,512 | 77.395% | A | Stage 2 + stages 3/5 |
| 116 | `haxeon.ui.core.StateStore.markUsed` | `array` | 856 | 449,368 | 77.542% | A | Stage 2 + stages 3/5 |
| 117 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `(void (haxeon.ui.core.UiEvent))` | 832 | 450,200 | 77.686% | C | Stages 3/5 |
| 118 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `haxeon.ui.semantics.Semantics` | 816 | 451,016 | 77.827% | V | Stage 2 + stages 3/5 |
| 119 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `haxeon.ui.semantics.Semantics` | 816 | 451,832 | 77.968% | V | Stage 2 + stages 3/5 |
| 120 | `$lambda:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | `(haxeon.ui.core.RenderNode ())` | 800 | 452,632 | 78.106% | C | Stages 3/5 |
| 121 | `$lambda:haxeon.ui.widgets.controls.SearchField.build:build#return/withScope(1)@2EFCE4BB#0` | `haxeon.ui.widgets.text.TextField` | 800 | 453,432 | 78.244% | V | Stage 2 + stages 3/5 |
| 122 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `(haxeon.ui.core.RenderNode ())` | 800 | 454,232 | 78.382% | C | Stages 3/5 |
| 123 | `haxeon.ui.widgets.docking.DockWorkspace.new` | `<abstract>` | 800 | 455,032 | 78.520% | M | a2 |
| 124 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `(void (haxeon.ui.core.UiEvent))` | 768 | 455,800 | 78.652% | C | Stages 3/5 |
| 125 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `haxeon.ui.widgets.collections.TreeViewRow` | 768 | 456,568 | 78.785% | V | Stage 2 + stages 3/5 |
| 126 | `app.editor.HierarchyPanel.build` | `haxeon.ui.widgets.collections.TreeView` | 768 | 457,336 | 78.917% | V | Stage 2 + stages 3/5 |
| 127 | `app.editor.HierarchyPanel.build` | `array` | 752 | 458,088 | 79.047% | A | Stage 2 + stages 3/5 |
| 128 | `$lambda:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | `String` | 744 | 458,832 | 79.176% | A | Stage 2 + stages 3/5 |
| 129 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `String` | 744 | 459,576 | 79.304% | A | Stage 2 + stages 3/5 |
| 130 | `haxeon.ui.widgets.controls.Tabs.buildControl` | `array` | 720 | 460,296 | 79.428% | A | Stage 2 + stages 3/5 |
| 131 | `haxeon.ui.widgets.text.TextField.buildField` | `(void (haxeon.ui.core.UiEvent))` | 704 | 461,000 | 79.550% | C | Stages 3/5 |
| 132 | `haxeon.ui.core.StateStore.endFrame` | `array` | 696 | 461,696 | 79.670% | A | Stage 2 + stages 3/5 |
| 133 | `$lambda:haxeon.ui.widgets.collections.TreeDisclosure.build:build#return/withScope(1)@7642AA77#0` | `haxeon.ui.LayoutStyle` | 688 | 462,384 | 79.789% | V | Stage 2 + stages 3/5 |
| 134 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `haxeon.ui.LayoutStyle` | 688 | 463,072 | 79.907% | V | Stage 2 + stages 3/5 |
| 135 | `$scalar-arguments:$optional-scalar:haxeon.ui.widgets.layout.SizedBox.new` | `haxeon.ui.LayoutStyle` | 688 | 463,760 | 80.026% | V | Stage 2 + stages 3/5 |
| 136 | `app.ReferenceEditorApp.actionRowStyle` | `haxeon.ui.LayoutStyle` | 688 | 464,448 | 80.145% | V | Stage 2 + stages 3/5 |
| 137 | `app.ReferenceEditorApp.statusBar` | `haxeon.ui.LayoutStyle` | 688 | 465,136 | 80.263% | V | Stage 2 + stages 3/5 |
| 138 | `app.editor.HierarchyPanel.build` | `haxeon.ui.LayoutStyle` | 688 | 465,824 | 80.382% | V | Stage 2 + stages 3/5 |
| 139 | `haxeon.ui.widgets.controls.SearchField.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 466,512 | 80.501% | V | Stage 2 + stages 3/5 |
| 140 | `haxeon.ui.widgets.controls.Tabs.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 467,200 | 80.620% | V | Stage 2 + stages 3/5 |
| 141 | `haxeon.ui.widgets.layout.Stack.defaultStyle` | `haxeon.ui.LayoutStyle` | 688 | 467,888 | 80.738% | V | Stage 2 + stages 3/5 |
| 142 | `$lambda:haxeon.ui.widgets.controls.Tabs.buildControl:buildControl#panel=/withScope(1)@0F620F35#0` | `haxeon.ui.semantics.Semantics` | 680 | 468,568 | 80.856% | V | Stage 2 + stages 3/5 |
| 143 | `haxeon.ui.widgets.controls.Tabs.buildControl` | `haxeon.ui.semantics.Semantics` | 680 | 469,248 | 80.973% | V | Stage 2 + stages 3/5 |
| 144 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `$lambda-env:$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0:buildPositioned#onResolved(0)@278674D8#0` | 672 | 469,920 | 81.089% | C | Stages 3/5 |
| 145 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `haxeon.ui.style.StyleTarget` | 672 | 470,592 | 81.205% | V | Stage 2 + stages 3/5 |
| 146 | `haxeon.ui.widgets.layout.SplitView.installDividerHandlers` | `(void (haxeon.ui.core.UiEvent))` | 672 | 471,264 | 81.321% | C | Stages 3/5 |
| 147 | `haxeon.ui.widgets.text.Text.build` | `haxeon.ui.style.StyleTarget` | 672 | 471,936 | 81.437% | V | Stage 2 + stages 3/5 |
| 148 | `haxeon.ui.core.KeyScope.prune` | `bytes` | 648 | 472,584 | 81.549% | A | Stage 2 + stages 3/5 |
| 149 | `$lambda:haxeon.ui.widgets.controls.Button.build:build#return/withScope(1)@0EBBA2C9#0` | `$lambda-env:haxeon.ui.widgets.controls.Button.buildScoped:buildScoped#return/selfUpdating(1)@2E3D53EF#0` | 640 | 473,224 | 81.659% | C | Stages 3/5 |
| 150 | `$lambda:haxeon.ui.widgets.controls.Button.build:build#return/withScope(1)@0EBBA2C9#0` | `(haxeon.ui.core.RenderNode ())` | 640 | 473,864 | 81.769% | C | Stages 3/5 |
| 151 | `haxeon.ui.core.RenderNode.onActivate` | `(void (haxeon.ui.core.UiEvent))` | 640 | 474,504 | 81.880% | C | Stages 3/5 |
| 152 | `haxeon.ui.widgets.commands.CommandButton.build` | `haxeon.ui.widgets.controls.Button` | 640 | 475,144 | 81.990% | V | Stage 2 + stages 3/5 |
| 153 | `haxeon.ui.widgets.controls.Button.buildButton` | `(void (haxeon.ui.core.UiEvent))` | 640 | 475,784 | 82.101% | C | Stages 3/5 |
| 154 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#on(1)@5FBCAB16#3` | 624 | 476,408 | 82.208% | C | Stages 3/5 |
| 155 | `$lambda:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | `$lambda-env:haxeon.ui.widgets.KeyedView.build:build#return/withScope(1)@2BC7466A#0` | 600 | 477,008 | 82.312% | C | Stages 3/5 |
| 156 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `$lambda-env:$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0:buildWithId#add(0)/withStyleParent(1)@3C60B63A#0` | 600 | 477,608 | 82.416% | C | Stages 3/5 |
| 157 | `$lambda:app.editor.SceneTreeRow.buildRow:buildRow#add(0)/withStyleParent(1)@3C60B63A#0` | `(haxeon.ui.core.RenderNode ())` | 576 | 478,184 | 82.515% | C | Stages 3/5 |
| 158 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `$lambda-env:$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0:build#onPaint(0)@16F2B4BE#0` | 576 | 478,760 | 82.614% | C | Stages 3/5 |
| 159 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `(void (haxeon.ui.core.UiEvent))` | 576 | 479,336 | 82.714% | C | Stages 3/5 |
| 160 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `$lambda-env:$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0:build#attach(2)@1EADD143#0` | 576 | 479,912 | 82.813% | C | Stages 3/5 |
| 161 | `$lambda:haxeon.ui.widgets.text.MiddleEllipsisText.build:build#return/withScope(1)@6F81BB0B#0` | `haxeon.ui.core.TextStyleOverride` | 576 | 480,488 | 82.913% | V | Stage 2 + stages 3/5 |
| 162 | `app.EditorSceneTree.visibilityMembers` | `array` | 576 | 481,064 | 83.012% | A | Stage 2 + stages 3/5 |
| 163 | `app.editor.SceneTreeRow.buildRow` | `(haxeon.ui.core.RenderNode ())` | 576 | 481,640 | 83.111% | C | Stages 3/5 |
| 164 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.core.TextStyleOverride` | 576 | 482,216 | 83.211% | V | Stage 2 + stages 3/5 |
| 165 | `haxeon.ui.core.TextStyleOverride.combine` | `haxeon.ui.core.TextStyleOverride` | 576 | 482,792 | 83.310% | V | Stage 2 + stages 3/5 |
| 166 | `haxeon.ui.widgets.collections.TreeView.buildBranch` | `haxeon.ui.widgets.collections.TreeBranch` | 576 | 483,368 | 83.409% | V | Stage 2 + stages 3/5 |
| 167 | `haxeon.ui.widgets.collections.TreeView.ensureTreeMetrics` | `<abstract>` | 576 | 483,944 | 83.509% | M | a2 |
| 168 | `haxeon.ui.widgets.commands.CommandButton.build` | `array` | 576 | 484,520 | 83.608% | A | Stage 2 + stages 3/5 |
| 169 | `haxeon.ui.widgets.controls.Button.buildButton` | `$lambda-env:haxeon.ui.widgets.controls.Button.buildButton:buildButton#labelNode=/withScope(1)@0B11ECC9#0` | 576 | 485,096 | 83.708% | C | Stages 3/5 |
| 170 | `$lambda:haxeon.ui.widgets.collections.TreeDisclosure.build:build#return/withScope(1)@7642AA77#0` | `haxeon.ui.core.RenderNode` | 560 | 485,656 | 83.804% | V | Stage 2 + stages 3/5 |
| 171 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `haxeon.ui.core.RenderNode` | 560 | 486,216 | 83.901% | V | Stage 2 + stages 3/5 |
| 172 | `$lambda:haxeon.ui.widgets.layout.Align.build:build#return/withScope(1)@2C0DFE62#0` | `haxeon.ui.core.RenderNode` | 560 | 486,776 | 83.998% | V | Stage 2 + stages 3/5 |
| 173 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `haxeon.ui.core.RenderNode` | 560 | 487,336 | 84.094% | V | Stage 2 + stages 3/5 |
| 174 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `haxeon.ui.core.RenderNode` | 560 | 487,896 | 84.191% | V | Stage 2 + stages 3/5 |
| 175 | `haxeon.ui.core.RenderNode.snapshotForCompare` | `haxeon.ui.core.RenderNode` | 560 | 488,456 | 84.287% | V | Stage 2 + stages 3/5 |
| 176 | `$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0` | `$lambda-env:$lambda:app.editor.VisibilityEye.build:build#return/withScope(1)@7C87F5EC#0:build#onPaint(0)@20563467#0` | 528 | 488,984 | 84.379% | C | Stages 3/5 |
| 177 | `$lambda:haxeon.ui.widgets.text.MiddleEllipsisText.build:build#return/withScope(1)@6F81BB0B#0` | `haxeon.ui.widgets.text.Text` | 528 | 489,512 | 84.470% | V | Stage 2 + stages 3/5 |
| 178 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.widgets.Icon` | 528 | 490,040 | 84.561% | V | Stage 2 + stages 3/5 |
| 179 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `bytes` | 528 | 490,568 | 84.652% | A | Stage 2 + stages 3/5 |
| 180 | `app.editor.HierarchyPanel.build` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 512 | 491,080 | 84.740% | V | Stage 2 + stages 3/5 |
| 181 | `haxeon.ui.widgets.controls.Button.buildButton` | `$lambda-env:haxeon.ui.widgets.Icon.build:build#return/withScope(1)@23F73046#0` | 504 | 491,584 | 84.827% | C | Stages 3/5 |
| 182 | `haxeon.ui.widgets.controls.Button.buildButton` | `haxeon.ui.core.Key` | 496 | 492,080 | 84.913% | V | Stage 2 + stages 3/5 |
| 183 | `$lambda:$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0:build#add(0)/withStyleParent(1)@3C60B63A#0` | `(haxeon.ui.core.RenderNode ())` | 480 | 492,560 | 84.996% | C | Stages 3/5 |
| 184 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `(haxeon.ui.core.RenderNode ())` | 480 | 493,040 | 85.078% | C | Stages 3/5 |
| 185 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `$lambda-env:$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0:buildPositioned#on(1)@4E5688CE#0` | 480 | 493,520 | 85.161% | C | Stages 3/5 |
| 186 | `haxeon.ui.widgets.controls.Tabs.scrollStrip` | `haxeon.ui.widgets.scroll.ScrollView` | 480 | 494,000 | 85.244% | V | Stage 2 + stages 3/5 |
| 187 | `haxeon.ui.widgets.docking.DockPanelCache.put` | `haxeon.ui.widgets.docking.DockPanelCacheEntry` | 480 | 494,480 | 85.327% | V | Stage 2 + stages 3/5 |
| 188 | `haxeon.ui.widgets.docking.DockWorkspace.tabLabelWidth` | `haxeon.ui.core.TextStyleOverride` | 480 | 494,960 | 85.410% | V | Stage 2 + stages 3/5 |
| 189 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `bytes` | 472 | 495,432 | 85.491% | A | Stage 2 + stages 3/5 |
| 190 | `$lambda:haxeon.ui.widgets.layout.Column.buildWithId:buildWithId#return/withScope(1)@448FABAD#0` | `haxeon.ui.style.StyleTarget` | 448 | 495,880 | 85.569% | V | Stage 2 + stages 3/5 |
| 191 | `$lambda:haxeon.ui.widgets.scroll.ScrollView.build:build#return/withScope(1)@75A1E414#0` | `haxeon.ui.style.StyleTarget` | 448 | 496,328 | 85.646% | V | Stage 2 + stages 3/5 |
| 192 | `haxeon.ui.core.BuildContext.buildUpdating` | `haxeon.ui.core.UpdatingDependencies` | 440 | 496,768 | 85.722% | V | Stage 2 + stages 3/5 |
| 193 | `$lambda:app.editor.SceneTreeRow.buildRow:buildRow#add(0)/withStyleParent(1)@3C60B63A#0` | `$lambda-env:haxeon.ui.widgets.KeyedView.build:build#return/withScope(1)@2BC7466A#0` | 432 | 497,200 | 85.796% | C | Stages 3/5 |
| 194 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `array` | 432 | 497,632 | 85.871% | A | Stage 2 + stages 3/5 |
| 195 | `app.EditorSceneTree.iconLabeledItem` | `app.editor.SceneTreeRow` | 432 | 498,064 | 85.945% | V | Stage 2 + stages 3/5 |
| 196 | `app.editor.SceneTreeRow.buildRow` | `$lambda-env:app.editor.SceneTreeRow.buildRow:buildRow#add(0)/withStyleParent(1)@3C60B63A#0` | 432 | 498,496 | 86.020% | C | Stages 3/5 |
| 197 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.widgets.KeyedView` | 432 | 498,928 | 86.095% | V | Stage 2 + stages 3/5 |
| 198 | `haxeon.ui.debug.UiStyleInvalidationMetrics.compare` | `array` | 432 | 499,360 | 86.169% | A | Stage 2 + stages 3/5 |
| 199 | `haxeon.ui.widgets.collections.TreeView.buildBranch` | `array` | 432 | 499,792 | 86.244% | A | Stage 2 + stages 3/5 |
| 200 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `array` | 432 | 500,224 | 86.318% | A | Stage 2 + stages 3/5 |
| 201 | `robotkit.world.RobotWorld.robotIds` | `array` | 432 | 500,656 | 86.393% | A | Stage 2 + stages 3/5 |
| 202 | `$lambda:$lambda:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#buttonNode=/withStyleParent(1)@3FD25D4C#0:buildStrip#return/withScope(1)@35459C49#0` | `(haxeon.ui.core.RenderNode ())` | 416 | 501,072 | 86.464% | C | Stages 3/5 |
| 203 | `$lambda:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#buttonNode=/withStyleParent(1)@3FD25D4C#0` | `(haxeon.ui.core.RenderNode ())` | 416 | 501,488 | 86.536% | C | Stages 3/5 |
| 204 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `bytes` | 416 | 501,904 | 86.608% | A | Stage 2 + stages 3/5 |
| 205 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#buttonNode=/withStyleParent(1)@3FD25D4C#0` | 416 | 502,320 | 86.680% | C | Stages 3/5 |
| 206 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `(haxeon.ui.core.RenderNode ())` | 416 | 502,736 | 86.752% | C | Stages 3/5 |
| 207 | `haxeon.ui.widgets.controls.Tabs.installTabDragHandlers` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.installTabDragHandlers:installTabDragHandlers#on(1)@3C23ABF9#1` | 416 | 503,152 | 86.823% | C | Stages 3/5 |
| 208 | `haxeon.ui.widgets.controls.Tabs.installTabDragHandlers` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.installTabDragHandlers:installTabDragHandlers#on(1)@3C23ABF9#2` | 416 | 503,568 | 86.895% | C | Stages 3/5 |
| 209 | `haxeon.ui.widgets.controls.Tabs.installTabDragHandlers` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.installTabDragHandlers:installTabDragHandlers#on(1)@3C23ABF9#3` | 416 | 503,984 | 86.967% | C | Stages 3/5 |
| 210 | `$lambda:haxeon.ui.widgets.layout.SplitView.build:build#return/withScope(1)@253B578A#0` | `haxeon.ui.semantics.Semantics` | 408 | 504,392 | 87.037% | V | Stage 2 + stages 3/5 |
| 211 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitView` | 408 | 504,800 | 87.108% | V | Stage 2 + stages 3/5 |
| 212 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `haxeon.ui.semantics.Semantics` | 408 | 505,208 | 87.178% | V | Stage 2 + stages 3/5 |
| 213 | `haxeon.ui.LayoutTransaction.appendNode` | `bytes` | 392 | 505,600 | 87.246% | N | Stage 2 |
| 214 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `(void ())` | 384 | 505,984 | 87.312% | C | Stages 3/5 |
| 215 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `virtual<build:(haxeon.ui.core.RenderNode (haxeon.ui.core.BuildContext))>` | 384 | 506,368 | 87.378% | V | Stage 2 + stages 3/5 |
| 216 | `$lambda:haxeon.ui.widgets.collections.TreeViewRow.build:build#return/withScope(1)@57A58339#0` | `(haxeon.ui.core.RenderNode ())` | 384 | 506,752 | 87.445% | C | Stages 3/5 |
| 217 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `$lambda-env:$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0:buildPositioned#delay=/resourceState(1)@688BFD41#0` | 384 | 507,136 | 87.511% | C | Stages 3/5 |
| 218 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `$lambda-env:$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0:buildPositioned#on(1)@226506D7#3` | 384 | 507,520 | 87.577% | C | Stages 3/5 |
| 219 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `(haxeon.ui.widgets.overlays.TooltipHoverDelay ())` | 384 | 507,904 | 87.643% | C | Stages 3/5 |
| 220 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `(void (haxeon.ui.ResolvedLayoutItem))` | 384 | 508,288 | 87.710% | C | Stages 3/5 |
| 221 | `app.ReferenceEditorApp.sceneAction` | `haxeon.ui.widgets.commands.CommandButton` | 384 | 508,672 | 87.776% | V | Stage 2 + stages 3/5 |
| 222 | `haxeon.ui.widgets.collections.TreeView.populateExpandedBranch` | `array` | 384 | 509,056 | 87.842% | A | Stage 2 + stages 3/5 |
| 223 | `haxeon.ui.widgets.docking.DockWorkspace.paneView` | `String` | 384 | 509,440 | 87.908% | A | Stage 2 + stages 3/5 |
| 224 | `haxeon.ui.widgets.overlays.Tooltip.build` | `(haxeon.ui.core.RenderNode ())` | 384 | 509,824 | 87.975% | C | Stages 3/5 |
| 225 | `haxeon.ui.widgets.scroll.ScrollView.addScrollbar` | `(f64 ())` | 384 | 510,208 | 88.041% | C | Stages 3/5 |
| 226 | `app.editor.SceneTreeReference.text` | `bytes` | 368 | 510,576 | 88.104% | A | Stage 2 + stages 3/5 |
| 227 | `$lambda:$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0:build#add(0)/withStyleParent(1)@3C60B63A#0` | `$lambda-env:haxeon.ui.widgets.KeyedView.build:build#return/withScope(1)@2BC7466A#0` | 360 | 510,936 | 88.167% | C | Stages 3/5 |
| 228 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `$lambda-env:$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0:build#add(0)/withStyleParent(1)@3C60B63A#0` | 360 | 511,296 | 88.229% | C | Stages 3/5 |
| 229 | `haxeon.ui.widgets.docking.DockWorkspace.buildTabs` | `haxeon.ui.widgets.controls.TabItem` | 360 | 511,656 | 88.291% | V | Stage 2 + stages 3/5 |
| 230 | `haxeon.ui.widgets.collections.TreeView.ensureTreeMetrics` | `array` | 352 | 512,008 | 88.352% | A | Stage 2 + stages 3/5 |
| 231 | `haxeon.ui.widgets.docking.DockPanelCache.retain` | `array` | 352 | 512,360 | 88.412% | A | Stage 2 + stages 3/5 |
| 232 | `haxeon.ui.widgets.docking.DockWorkspace.defaultStyle` | `haxeon.ui.LayoutStyle` | 344 | 512,704 | 88.472% | V | Stage 2 + stages 3/5 |
| 233 | `haxeon.ui.widgets.layout.AppShell.defaultBodyStyle` | `haxeon.ui.LayoutStyle` | 344 | 513,048 | 88.531% | V | Stage 2 + stages 3/5 |
| 234 | `haxeon.ui.widgets.layout.Column.new` | `haxeon.ui.LayoutStyle` | 344 | 513,392 | 88.590% | V | Stage 2 + stages 3/5 |
| 235 | `$lambda:haxeon.ui.widgets.collections.TreeView.build:build#return/withScope(1)@7F477B93#0` | `String` | 336 | 513,728 | 88.648% | A | Stage 2 + stages 3/5 |
| 236 | `$lambda:haxeon.ui.widgets.layout.Row.build:build#return/withScope(1)@2206A747#0` | `haxeon.ui.style.StyleTarget` | 336 | 514,064 | 88.706% | V | Stage 2 + stages 3/5 |
| 237 | `$lambda:tests.HeadlessEditorProfile.submit:submit#buildProbe=@305D61CA#0` | `dynobj` | 336 | 514,400 | 88.764% | O | Other |
| 238 | `app.editor.HierarchyPanel.build` | `haxeon.ui.widgets.KeyedView` | 336 | 514,736 | 88.822% | V | Stage 2 + stages 3/5 |
| 239 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.style.StyleTarget` | 336 | 515,072 | 88.880% | V | Stage 2 + stages 3/5 |
| 240 | `app.editor.SceneTreeRow.buildRow` | `haxeon.ui.widgets.text.MiddleEllipsisText` | 336 | 515,408 | 88.938% | V | Stage 2 + stages 3/5 |
| 241 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `array` | 336 | 515,744 | 88.996% | A | Stage 2 + stages 3/5 |
| 242 | `app.editor.HierarchyPanel.build` | `haxeon.ui.widgets.controls.Button` | 320 | 516,064 | 89.051% | V | Stage 2 + stages 3/5 |
| 243 | `haxeon.ui.core.RenderNode.onActivate` | `$lambda-env:haxeon.ui.core.RenderNode.onActivate:onActivate#on(1)@46BD8B1D#0` | 320 | 516,384 | 89.107% | C | Stages 3/5 |
| 244 | `haxeon.ui.widgets.controls.Button.buildButton` | `$lambda-env:haxeon.ui.widgets.controls.Button.buildButton:buildButton#activate=@18D79A81#0` | 320 | 516,704 | 89.162% | C | Stages 3/5 |
| 245 | `haxeon.ui.widgets.docking.DockWorkspaceInteraction.beginFrame` | `array` | 320 | 517,024 | 89.217% | A | Stage 2 + stages 3/5 |
| 246 | `$lambda:$lambda:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#buttonNode=/withStyleParent(1)@3FD25D4C#0:buildStrip#return/withScope(1)@35459C49#0` | `$lambda-env:haxeon.ui.widgets.controls.Button.build:build#return/withScope(1)@0EBBA2C9#0` | 312 | 517,336 | 89.271% | C | Stages 3/5 |
| 247 | `$lambda:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#buttonNode=/withStyleParent(1)@3FD25D4C#0` | `$lambda-env:$lambda:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#buttonNode=/withStyleParent(1)@3FD25D4C#0:buildStrip#return/withScope(1)@35459C49#0` | 312 | 517,648 | 89.325% | C | Stages 3/5 |
| 248 | `$lambda:haxeon.ui.widgets.docking.DockWorkspace.buildTabs:buildTabs#onTabHeaderBuilt=@466EAE0E#0` | `haxeon.ui.widgets.docking.DockTabDropTarget` | 312 | 517,960 | 89.379% | V | Stage 2 + stages 3/5 |
| 249 | `app.editor.SceneTreeReference.text` | `String` | 312 | 518,272 | 89.432% | A | Stage 2 + stages 3/5 |
| 250 | `haxeon.ui.widgets.controls.Tabs.buildStrip` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.buildStrip:buildStrip#onClickEvent=@514C48ED#0` | 312 | 518,584 | 89.486% | C | Stages 3/5 |
| 251 | `haxeon.ui.widgets.controls.Tabs.installTabDragHandlers` | `$lambda-env:haxeon.ui.widgets.controls.Tabs.installTabDragHandlers:installTabDragHandlers#on(1)@12EFE437#0` | 312 | 518,896 | 89.540% | C | Stages 3/5 |
| 252 | `haxeon.ui.widgets.docking.DockWorkspace.buildSplit` | `haxeon.ui.widgets.layout.SplitViewOptions` | 312 | 519,208 | 89.594% | V | Stage 2 + stages 3/5 |
| 253 | `$lambda:haxeon.ui.core.UiContext.submitInternal:submitInternal#picker=@2F5A6012#0` | `array` | 304 | 519,512 | 89.646% | A | Stage 2 + stages 3/5 |
| 254 | `$lambda:haxeon.ui.widgets.layout.Align.build:build#return/withScope(1)@2C0DFE62#0` | `array` | 288 | 519,800 | 89.696% | A | Stage 2 + stages 3/5 |
| 255 | `$lambda:haxeon.ui.widgets.layout.SizedBox.build:build#return/withScope(1)@3E846C9D#0` | `array` | 288 | 520,088 | 89.746% | A | Stage 2 + stages 3/5 |
| 256 | `$lambda:haxeon.ui.widgets.layout.Stack.build:build#return/withScope(1)@09BF2603#0` | `array` | 288 | 520,376 | 89.796% | A | Stage 2 + stages 3/5 |
| 257 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `$lambda-env:$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0:buildPositioned#on(1)@6B05D325#4` | 288 | 520,664 | 89.845% | C | Stages 3/5 |
| 258 | `$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0` | `$lambda-env:$lambda:haxeon.ui.widgets.overlays.Tooltip.buildPositioned:buildPositioned#return/withScope(1)@108FF867#0:buildPositioned#on(1)@6B05D325#5` | 288 | 520,952 | 89.895% | C | Stages 3/5 |
| 259 | `$lambda:haxeon.ui.widgets.text.MiddleEllipsisText.build:build#return/withScope(1)@6F81BB0B#0` | `$lambda-env:$lambda:haxeon.ui.widgets.text.MiddleEllipsisText.build:build#return/withScope(1)@6F81BB0B#0:build#onResolved(0)@7C07135F#0` | 288 | 521,240 | 89.945% | C | Stages 3/5 |
| 260 | `app.ReferenceEditorApp.sectionHeading` | `haxeon.ui.core.TextStyleOverride` | 288 | 521,528 | 89.994% | V | Stage 2 + stages 3/5 |
| 261 | `app.editor.SceneTreeRow.buildRow` | `app.editor.VisibilityEye` | 288 | 521,816 | 90.044% | V | Stage 2 + stages 3/5 |

Displayed sites: 521,816 bytes. Classified remainder below the cutoff: **57,696 bytes**.


## Concrete follow-ups revealed by the final windows

- The only finite payload enum allocated in a measured input window remains `TextEditIntent`: one 24-byte object
  for `type-char`. Its remaining checked virtual casts and descriptor paths are the deferred E3/E7 family recorded
  in `STRUCTS.md`; this census does not claim that widening was implemented.
- Recursive `DockNode` allocations remain in the four tab windows, in normalization, clone and remove paths.
  They are B representation bytes with **UI tree-copy** removal work. They are not a reason to bypass the permanent
  by-value recursion rule. The one-pass filtered-snapshot change is already in the source; further UI/persistence
  construction needs review after this bounded session.
- `@TextStyle` and `@ParagraphStyle` are real struct-carrier allocations in `TextField.buildField`; do not label
  the source-level mutable `LayoutStyle` objects as the same phenomenon. The stacks identify the call sites,
  not the complete IR escape cause; that ABI trace is a follow-up, not an invented a2 guarantee.
- Structural `virtual<build:...>` View adapters belong to V and are removed with nominal component/widget work.
  The allocation-free typed interface-dispatch tests do not imply these structural adapters already disappeared.
- Retained `EditOperation` and text-index objects are R. Their ownership is useful; reducing rebuilding or captured
  callback state is separate from deleting undo/index functionality.
- The small O total contains named diagnostic and application model records, not hidden map or scalar costs.
  Harness scalar boxes are B; harness record objects are O. Full exact totals intentionally include both.
- Wasm ObjectMap remains a linear identity-key lookup; a2 must replace it with a real identity-hashed map on all
  targets. This report does not treat its absence from a hot-window top table as a scalability pass.

## Comparable Wasm GC Showcase scenes

The committed opt-in guest counter counts physical `struct.new`/array objects. It provides object counts, not
requested object bytes or allocating-function/type stacks. The 120 measured frames follow 120 warmup frames.
All three alternating control/candidate pairs match for each scene; their timing data is in `VALUE_TYPES.md`.
These scenes exercise the same widget/layout/text mechanisms, but are not the editor's 15 input windows.

| Scene | Control objects / 120 frames | Final objects / 120 frames | Objects/frame | Byte/site attribution |
|---|---:|---:|---:|---|
| full | 4,320 | 4,320 | 36 | Not exposed by this counter |
| static | 4,320 | 4,320 | 36 | Not exposed by this counter |
| text-heavy | 4,320 | 4,320 | 36 | Not exposed by this counter |
| editing | 8,604 | 8,604 | 71.7 mean | Not exposed by this counter |

Do not infer a per-cause Wasm byte census from these counts. Wasm32's linear allocator separately matches at
3,840 calls / 132,480 requested bytes per 120 full-scene frames; those calls are not a Wasm GC object/site census.

## Reproduction and validation

The existing `app/tools/profile-editor.py --scenario <scenario> --cycles 3 --no-profile --skip-build --output-dir <capture>`
executes the frozen census module with `MATERIA_ACTION_CENSUS=<action>` and `MATERIA_ACTION_CENSUS_OUT=<capture>/window.json`.
The measurement-only harness patch, changed-source hashes, per-action analyzed types/stacks and source-audited site
manifest are retained under the session's `final-native-enums/census-preparation` records. Their hashes above fix the
inputs. Raw captures have been deleted after extraction. No production census hooks or budget-tool changes land.

Validation checks: 15/15 calibrated windows; exact object/type sums; exact stack/type byte equality after calibration;
no missing or multiply assigned causes; equal causes before merging function/type line variants; all cause totals sum
to exact action bytes; every displayed cutoff reaches 90%; every action ties or improves the exact control totals.
The published code batch passed 857 compiler tests, self-hosting, all ten UI scripts, 526 runtime parity fixtures
(14 documented skips), 60 positive/702 negative UI checks, the app suite, retention, budgets and memory gates.
The documentation-only census commit passes Tier 1: 857 compiler tests, zero failures, with eight workers.
It changes no compiler or runtime source.
