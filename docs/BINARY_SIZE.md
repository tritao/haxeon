# Binary size investigation

This report is in progress. Measurements below are a baseline; the editor is measured on HashLink and the UI Showcase on HashLink, Wasm32, and Wasm GC.

## Method

Enable `HAXEON_IR_CENSUS=1` and save compiler standard error separately from standard output. `scripts/report-binary-size.py MODULE CENSUS_LOG` combines the existing per-function census with byte counts from the HashLink serializer or the actual WebAssembly sections. It checks that every module byte is accounted for and, for Wasm, that the ordered encoded function body lengths match the census. Section totals include their framing and vector lengths. Function body totals exclude Wasm length prefixes. HashLink function totals include headers and register types but exclude line and variable debug information. Debug section payload sizes are listed separately from their enclosing total, so should not be summed twice. HashLink reflection-member records are split from their containing type headers; member names remain in the string pool. The tool decodes the trailing debug sections to rank snapshot content and source-span mapping bytes by file. For known Wasm root, patch and slot metadata, the tool also ranks serialized records and groups their sizes by adapter name and whether the name appears in the defined-function census; section and record breakdowns overlap and must not be summed together.

The report verifies each Wasm data segment against its census entry and separates string, reflection, static-data, closure-descriptor and runtime-state segments, with framing counted separately.

The earlier corrected editor snapshot had a task-local addition of `drawing(id)` at the MachineKit `Gantry.hx:1050` call, described in [the previous census](BYTECODE_OPPORTUNITIES.md#editor-capture-status). It is not the unchanged editor. The user selected a new frozen baseline instead of reproducing that snapshot; see below. The prior task work directory and the measured modules at their documented sizes were not found in the searched scratch locations. The later outer revision `0d3ca41a8` already contains `drawing(id)` at this call, but that fact does not establish that its remaining inputs match the earlier task-local snapshot or its published input digest. The earlier capture recipe copied the then-current MachineKit source tree into `haxeon-bytecode-opt-work/machinekit-source-corrected`, used an `editor-comparison.sources.txt` manifest, and hashed each absolute path together with its file hash. The remaining app and package sources were symlinks to the then-current outer checkout rather than a frozen copy. Both the prior work directory and its worktree are absent; the path-dependent aggregate digest does not identify the individual input contents.

Captured artifact SHA-256 values: HashLink `47fb976ea788e131a23b61d91aad3720425267a286c293e1924ce0cb27ac53b2`, Wasm32 `ea4e6a18d4b8aed73fe4cd41026044edbb084321a8ba7d3468368b41be2b574f`, and Wasm GC `2c076f48544fdd1663f4c2b165aee1ef461466cd531c4d7f4409b16d72c5dc42`. Paths embedded in HashLink debug information are part of the artifact.

## Showcase baseline, HashLink

The desktop `ShowcaseDesktop` entry from `packages/ui/tools/showcase.sh` produces a 12,577,769-byte module with 6,529 functions. Unlike the web entries, it includes desktop bindings; these sizes are not an apples-to-apples target comparison. Encoded functions, including headers and register types but excluding debug records, account for 1,452,091 bytes. Per-function line and assignment data accounts for 1,079,638; debug file paths 20,100; the string pool 250,168; type headers and non-member records 50,094; reflection member and binding records 27,220; constants and scalar pools 26,896; globals 5,881; natives 4,312; and the header 30. The three trailing debug sections occupy 9,661,339 bytes including framing: function identities 796,780 payload bytes, opcode source spans 5,932,407, and embedded source snapshots 2,932,130. The largest source snapshots are `nativekit.ffi.NativeKitTypes.hx` (416,928 content bytes), `nativekit.ffi.NativeKit.hx` (292,309), `NativeKitUI.hx` (266,110), and `nativekit.ffi.NativeKitGpu.hx` (198,678); the first four together account for 1,174,025 of the 2,932,130 snapshot payload bytes. The largest per-file opcode-span mapping payloads are `NativeKitTypes.hx` (270,145 bytes), `NativeKit.hx` (224,513), `Theme.hx` (215,556), `TextEditorLayout.hx` (210,957), and `RenderNode.hx` (188,606). Those file totals exclude span-section file tables and group headers. Thus debug information dominates this Showcase module. The requested editor breakdown remains necessary before extrapolating to its 85% non-code share.

The largest function encodings are `Theme.refreshStyles` (25,510 bytes), `Theme.palette` (17,866), `ShowcaseKit.makeTheme` (16,641), `InspectorPanel.buildContent` (15,071), and `TextOffsetMap.isExtend` (13,419). These exclude debug data. The largest individual line-and-assignment records belong to `TextOffsetMap.isExtend` (11,806 bytes), `Theme.refreshStyles` (11,029), `Theme.palette` (8,329), `InspectorPanel.buildContent` (8,107), and `ShowcaseKit.makeTheme` (7,750). The largest string is a 910-byte embedded HTML document; the string table is already a shared pool, so length ranking is not a measurement of repeated references. The largest encoded object types are `UiContext` (685 bytes), `BuildContext` (626), `TextEditorState` (549), `Showcase` (509) and `UiExplorer` (480). The most frequent `LoadString` indices name `nativekit` (681 instructions), the empty string, `>13` and `borrowed` (255 each), and `nk_last_error` (254); these are instruction references to interned entries, not duplicate pool copies.

## Showcase baseline, Wasm32

At compiler base `44ce670a`, default inlining and the imported-memory contract used by the UI tests, the module is 30,017,051 bytes and has 23,805 defined functions. This capture uses the `ShowcaseWeb` entry and the source/FFI inputs in `packages/ui/tools/showcase-wasm.sh`. The original capture combined stdout and stderr: buffered compiler status text interrupted one census line. The saved analysis log joins that interrupted line after removing the intervening status messages; the report then verified every recorded body length against the module code section. Later captures use separate streams. The accounting is:

| Serialized category | Bytes |
|---|---:|
| Code section | 13,232,916 |
| GC root metadata | 6,743,635 |
| Hot-reload patch metadata | 5,115,031 |
| Hot-reload slot metadata | 2,281,028 |
| Name custom section | 2,078,451 |
| Data | 477,491 |
| Table elements | 55,087 |
| Function signatures | 23,995 |
| Imports | 4,471 |
| Types | 3,014 |
| Globals | 1,130 |
| Exports | 724 |
| Memory contract metadata | 53 |
| Header, table, exception tag, start | 25 |
| **Total** | **30,017,051** |

The largest bodies are `haxeon.ui.theme.Theme.refreshStyles` (110,806 bytes), `inspector.InspectorPanel.buildContent` (84,054), and `__exception_matches`, `__haxeon_array_type_test` and `__std_is_of_type` (72,781 each). Equal sizes alone do not establish that their bodies are interchangeable. The data section contains 447,656 bytes of string segments, 16,427 reflection bytes, 10,698 static-data bytes, 2,142 closure-descriptor bytes, 562 runtime-state bytes, and six bytes of section framing. Encoded segment totals include their own headers.

Of the defined functions, 19,957 are `__haxeon_closure_adapter_*` functions (6,447,795 encoded body bytes), and 95 are `__haxeon_closure_cast_*` dispatchers (2,185,576 bytes). `WasmLinearClosureAdapters.generate` currently constructs a source/target signature pair for every same-arity combination, and the generated functions use `Keep`; each cast dispatcher refers to its source adapters. These numbers establish a candidate for investigation, not proof that a particular pair is unreachable: Dynamic values, reflection, and closure adaptation must remain correct.

Parsing the three metadata payloads against the emitted-function census attributes 3,303,274 bytes of root records, 2,985,222 bytes of patch records, and 2,035,614 bytes of slot records to the 19,957 emitted adapters. This is 8,324,110 payload bytes in addition to their bodies and names. The root and patch payloads also contain 12,719 names absent from the emitted-function census, occupying 2,174,419 and 1,648,667 bytes respectively. A name absent from this census is not by itself proof of dead metadata: generated names, imports, and the needs of hot reload and the runtime-neutral contract require examination. The root format is explicitly part of the runtime-neutral contract, and the implementation uses the same root analysis when emitting collector operations.

## Showcase baseline, Wasm GC and function-count comparison

Using the same source set, imported-memory contract and legacy exception mode, `ShowcaseWebGcEntry` produces 5,493,746 bytes and 4,238 defined functions. Code accounts for 3,274,339 bytes; patch metadata 1,308,563; patch slots 308,973; names 274,419; data 186,166; types 86,480; globals 32,607; function signatures 8,481; table elements 8,450; imports 4,462; exports 724; and the remaining headers and small sections 82. These figures include each section's framing. The data section comprises 159,041 bytes of encoded string segments, 16,420 reflection bytes, 10,699 static-data bytes and six framing bytes; segment totals include their own encoding overhead. The Wasm32/GC function ratio here is 5.62, not exactly the historical 5.7: the base revision and two target entries differ from that earlier capture.

The GC patch payload contains 8,352 names absent from the emitted-function census, occupying 875,390 bytes; as above, this is a name comparison, not a reachability proof.

Its largest bodies are `Theme.refreshStyles` (87,239 bytes), `InspectorPanel.buildContent` (60,604), `__std_string` (54,558), `__haxeon_value_type_name` (53,455) and `__init$part0` (33,743).

Wasm GC emits 194 closure adapters (23,009 body bytes) and eight cast dispatchers (4,243 bytes), compared with Wasm32's 19,957 adapters and 95 dispatchers. The adapter excess alone is 19,763 functions, slightly more than the total difference of 19,567; other function groups therefore partly offset it. The principal cause is visible in the generators: the Wasm32 generator collects closure creations and cast targets from **every** IR function before backend reachability, then marks all resulting pair adapters and dispatchers `Keep`. The Wasm GC generator collects from reachable functions. Both conservatively pair source and target signatures by arity and account for adapted closures that may be cast again. This explains the observed disparity more directly than a claim of absent general dead-code elimination; Wasm32 already computes function reachability for its ordinary lowering. A safe change needs to account for the helper calls introduced during lowering and for closures arriving through Dynamic and reflection. In particular, linear lowering turns a function-valued `SafeCast` into a call to the generated cast helper only after IR reachability. Merely changing the helpers from `Keep` to ordinary reachability would therefore discard implicit callees. Generated adapters also cast their captured source closure and can contain nested function-valued conversions; both need to be represented in any replacement reachability plan.

Repeat Wasm32 and Wasm GC Showcase captures using the original Haxe interpreter invocation were byte-identical after adding data attribution. Running the Haxe-built compiler module via the checkout VM instead produced the same 4,238 functions and section sizes except for five additional code bytes, distributed across five generated functions. This is an observed compiler-invocation difference; comparisons here use the same invocation rather than attributing it to the measured change.

## Reachable Wasm32 closure adapters

The linear backend plans closure source signatures and cast targets from reachable functions, then expands generated adapters' function-valued casts until no new target appears. Cast-helper calls introduced by lowering are included in the final reachability calculation; generated adapters and dispatchers no longer use `Keep`. The varargs adapter dependencies are generated as needed. Reachability uses indexed helper lookups, and Wasm validation shares its unchanged function-signature vector across functions instead of rebuilding it for each one. A missing planned function-cast helper is a compile error instead of silently omitting the conversion. Tests cover unreachable casts and the existing dynamic, reflection, varargs and nested-callback behavior.

At rebased baseline `93230bda`, using the same checkout-built HashLink-hosted compiler for both captures, Showcase Wasm32 fell from **30,017,042 to 11,867,682 bytes** and from **23,805 to 6,864 functions**. Closure adapters fell from 19,957 (6,447,798 body bytes) to 3,032 (774,201 bytes); cast dispatchers rose from 95 to 102 as nested conversions were added, and their bodies fell from 2,185,576 to 318,984 bytes. All bytes, including section framing, are attributed below:

| Category | Before | After |
|---|---:|---:|
| code | 13,232,951 | 5,668,783 |
| custom: haxeon.gc.roots | 6,743,591 | 2,774,465 |
| custom: haxeon.memory.contract | 53 | 53 |
| custom: haxeon.patch | 5,115,031 | 1,863,664 |
| custom: haxeon.patch.slots | 2,281,028 | 555,015 |
| custom: name | 2,078,451 | 497,377 |
| data | 477,491 | 478,246 |
| exception tags | 5 | 5 |
| exports | 724 | 724 |
| function signatures | 23,995 | 7,052 |
| function tables | 8 | 7 |
| globals | 1,130 | 1,130 |
| header | 8 | 8 |
| imports | 4,471 | 4,471 |
| start | 4 | 4 |
| table elements | 55,087 | 13,673 |
| types | 3,014 | 3,005 |

On the same compiler invocation, Showcase HashLink is byte-identical at 12,577,769 bytes and 6,529 functions, and Showcase Wasm GC is byte-identical at 5,493,751 bytes and 4,238 functions. Consequently every category is unchanged on those targets. The HashLink editor is byte-identical at 103,205,406 bytes and 32,378 functions, so every editor category is also unchanged. These editor inputs are checked against the frozen per-file manifest.

The IR census is unchanged before and after: Showcase HashLink has 5,411 allocation sites (212 in loops), both Showcase Wasm targets have 7,703 (302 in loops), and the editor has 51,470 (6,512 in loops). These static site counts do not measure runtime allocation totals.

The existing UI state and pointer allocation fixtures passed before and after on all three targets with inlining both off and on. On both Wasm targets, their measured loops allocate zero objects at sizes 8 and 1,024; the HashLink fixtures enforce their own allocation checks. These fixtures do not measure full Showcase or editor interaction totals.

## Fresh editor baseline and Wasm capture limit

The comparison input is now a frozen copy of outer revision `0d3ca41a8`, including its recorded native submodule revisions, with this worktree supplying Haxeon sources. The 3,479 source, standard-library and FFI input files have a path-and-content aggregate SHA-256 of `d89688bc62d12df9e82d9995d9dfef03412b85e0c6a5962c23ed3c8666d1ea6c`; the per-file manifest is in the task work directory. This replaces the unavailable older corrected snapshot. Two independent HashLink captures produced the same module SHA-256 `eab2b7cdbb9e458919a3cc67f124ec96563a17956d75496787f8838839603b16`.

The editor HashLink module is 103,205,406 bytes with 32,378 functions. Its exact categories are: function encodings 14,640,885; function line and assignment debug 9,676,077; debug sections 75,518,194; strings 2,258,158; types 371,501; reflection members 268,053; constants 278,867; scalar constants 23,888; debug paths 108,397; globals 48,608; natives 12,738; header 40. Debug section payloads are 4,616,616 identity, 53,463,215 source-span and 17,438,341 snapshot bytes. The largest encoded function is `machinekit.motion.HgReferenceData.section` at 113,967 bytes; the largest type is `app.EditorScene` at 2,922 bytes.

The editor is a desktop HashLink application; its native MachineKit FFI uses a 64-bit layout. Wasm editor builds are out of scope. Compare this frozen editor on HashLink and the UI Showcase on all three targets.

## HashLink line-table opportunity

The checkout VM decodes the standard HashLink line-table repeat and forward-delta records, while `HlWriter.writeDebugLocations` currently emits an absolute three-byte line for every opcode. Applying a read-only model of repeat runs (up to 15 equal file/line entries) and forward deltas of 1–31 to the checkout `hldump --debug` output predicts a reduction from 992,682 to 217,173 encoded line/file bytes for the desktop Showcase, a 775,509-byte saving. The remaining 86,956 bytes of per-function debug data are assignment records and are excluded from this estimate. The largest modeled savings are in `TextOffsetMap.isExtend` (10,182 bytes), `Theme.refreshStyles` (8,891), and `Theme.palette` (7,385). The model covers 314,938 decoded opcode locations; it has not yet been implemented or verified against the debugger, profiler, stack traces, and hot reload.

## Remaining work

Complete the HashLink editor and three-target Showcase before/after measurements and allocation checks. The HashLink line table and development metadata changes remain to be measured.
