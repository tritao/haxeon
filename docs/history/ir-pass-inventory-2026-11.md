# IR pass inventory: November 2026 gate history

## Outer gate control evidence (2026-11-10)

On outer `haxeon-a1-outer` commit `c78fa7163`, the app suite built with a1 fails in
`CosmeticThreadTests` with `Uncaught exception: appearance edit rebuilds the child's material`.
The unmodified `origin/main` compiler `fcfd253bd1c8ea4b50921bc08cec0a885ad94171` cannot compile
that outer project or the isolated cosmetic test: `app/CncProgramPlayer.hx:744:96: E1009: Type mismatch
for argument 1 to "robotkit.execution.ProcessEventValue.Analog"`.

As a diagnostic, the same origin compiler with only the abstract-to-Float widening fix from `d4d734cb`
applied compiled the isolated cosmetic test and produced the identical exception, as did a1. This is not an
unmodified control. A supplemental runner omitting that one test then reached a second identical failure under
both compilers: `CAD plate workflow tests failed: CAD collision bounds must have positive half extents`.
The lead accepted this compiler plus widening fix as the control and these two identical failures as the
outer-app baseline. The remaining Tier 2 and output/measurement gates still require their own results.
Publishing `d4d734cb` also restores compilation of `CncProgramPlayer.hx:744` against published Haxeon.

The Tier 2 retention gate passed eight scenarios and failed `panel-flows` with
`Headless editor profile failed: Inspection camera ignored its view label`. Running that scenario with the
lead-approved diagnostic control produced the same failure. The lead accepted this as a pre-existing
outer-app failure; the other eight retention scenarios passed.

### Pre-rebase batch output and allocation comparison (2026-11-10)

The approved control is `fcfd253b` with only `d4d734cb`'s abstract widening applied. The editor modules
have SHA-256 `3267a541ba70284940408447dc228175b0b0607a005c81a648037a4b20304b24` (control) and
`0113022f30f18e5368b1663b3fc82faa940a68e364db885dd687189b745b8790` (a1).
All 36,447 normalized functions and the descriptor and function sidecars match. The four byte-difference
clusters are the generated `haxeon.build.CodeIdentityTable` fingerprint entries, references to its changed
source hash in legacy/debug spans, and the source-snapshot section ordered by that changed hash. The Wasm GC
Web guest hashes are `99f3f8bec26ad703a767eced85e3a7b93fa8c8b00f258d8def4de276c046b50b` and
`e10337474a3cd251f3cb1913f6566b1774aa831ae5546549411fefa6dcf6be78`; all sections except the data
section are byte-identical, and its 87,606 changed bytes are exclusively the generated compiler-identity table.
The Web build's generated FFI list omits `machinekit-pendant.hxi`; the comparison generated it from the pinned
C header using the wasm32 importer in the disposable gate directory. A control guest was terminated by
`earlyoom` after memory pressure crossed its threshold; a locked retry completed both byte-comparison builds.
For the separate timing/memory pair, `earlyoom` again terminated the control at 8,967 MiB RSS. With
`HL_GC_MARK_THRESHOLD=0.08`, the control completed in 489.24 s at 9,035,512 KiB peak RSS, but `earlyoom`
terminated a1 after 355.44 s at 6,610 MiB RSS; other builds were running and `earlyoom` also terminated
unrelated processes. A later pair completed with `HL_GC_MARK_THRESHOLD=0.04` for both: control/a1 wall time
was `787.75/684.22` s, peak RSS `8597848/8619712` KiB, typing-lowering `12851.27/10807.53` ms, and body
typing `843.43/643.92` ms. Both hashes matched the earlier comparison. Other builds were running.

HashLink's normal allocation counter charges 2,048-byte thread-local runs when reserved, producing varying medians
even for repeated runs of the identical control module. With `HL_GC_PROFILE=1`, which disables those runs, the
exact action medians match for all 14 tab and interaction actions; selection's available allocation components
also match. The standard selection capture does not report a total, so a temporary instrumented copy measured
selection input plus frame with the same per-allocation mode: all 59 measured cycles matched exactly, with a
577,192-byte median for both. Other builds were running.

Three planned editor timing pairs yielded two cold pairs and one mismatched pair because only the control reused
its resident module. Cold control/a1 typing-lowering milliseconds were `4746.16/3859.40` and `3911.11/3929.18`;
body typing was `187.06/130.66` and `132.78/129.40`. A preliminary cold pair was `4243.92/4290.62` total
and `141.26/136.99` bodies. One-shot control/a1 typing-lowering was `4757.61/4743.32` ms, body typing was
`165.98/167.40` ms, and peak RSS was `4969660/5003732` KiB. The mismatched reuse run is not a comparable
timing result. Other builds were running.

### Rebased batch comparison (2026-11-10)

After rebasing onto `fcfd253b`, the editor control/a1 SHA-256 hashes are
`8890fb8915cd56619a86bfbcd4ddf058febdea6a8bcb095c5005a80f8e7609f5` and
`4275fb9d96e66b04e1241d6701042b0d2e5675c51ff49617809cfd081de078b6`. All 36,421 normalized
functions and function/descriptor sidecars match. The four byte-difference clusters are the same compiler-identity
fingerprint table, its legacy debug hash, its debug-span hash, and the reordered source snapshots containing that
table. One-shot control/a1 typing-lowering was `5435.89/5095.02` ms, body typing `171.97/166.21` ms, wall time
`115.40/104.38` s and peak RSS `4981672/4997688` KiB. Other builds were running, including self-hosting.
With `HL_GC_PROFILE=1`, all 14 tab and interaction action medians matched; the instrumented selection probe also
matched all 59 measured cycles exactly at a `577192` byte median for both compilers. Other builds were running.

The rebased Web guest control/a1 SHA-256 hashes are
`40fabd46f3d62d500785db7bc0f8122267347210e0ebf7f7182268f60e5aa9ee` and
`24a1a8560f16ce5e1cced8a4a70aa59e50326ca092ab1648d323de662e6b2457`. All sections except the data
section match; its 87,742 changed bytes lie within the generated compiler identity table. The locked pair with
`HL_GC_MARK_THRESHOLD=0.04` took `735.12/724.76` s wall time and `8604268/8614840` KiB peak RSS;
typing-lowering was `11601.02/11759.46` ms and body typing `664.96/682.61` ms. Other builds were running.
These single-pair typing times are higher for a1, so they do not by themselves establish the no-regression gate.
The rebased app suite again reached `Uncaught exception: appearance edit rebuilds the child's material`,
the accepted identical control failure above. A supplemental run omitting that test reached the same
`CAD plate workflow tests failed: CAD collision bounds must have positive half extents` baseline after its other
scenarios passed. Rebased retention passed eight scenarios; `panel-flows` again
reported `Headless editor profile failed: Inspection camera ignored its view label`, also the accepted control failure.
Rebased performance budgets passed each scenario on its first capture; all three headless captures passed.
Other builds were running during those locked checks.

An instrumented Haxe-built compiler, stopped immediately after the Web frontend's typing/lowering phase,
ran three alternating-order pairs under both locks with the same Web arguments and GC threshold as the full pair.
Control/a1 typing-lowering milliseconds were `13106.99/13396.28`, `10933.27/14538.10`, and
`14723.94/13024.29`; body typing was `769.24/793.56`, `638.07/867.51`, and `736.69/765.95`.
Other builds were active and varied between samples. The samples do not establish that typing is not slower.
An earlier instrumented self-hosted control probe failed with `haxeon/ui/widgets/settings/SettingsPanel.hx:154:19:
E1003: Empty array literal requires an expected element type`; that probe used a different FFI argument order.

A separate instrumented Haxe-built frontend measured process CPU as well as wall time at the same boundaries.
Three alternating-order control/a1 pairs measured typing-lowering CPU milliseconds of `38030/34810`,
`39280/35050`, and `35110/41350`, and body-typing CPU of `2330/2180`, `2270/2100`, and `2050/2720`.
The corresponding typing-lowering wall times were `13164.30/12008.73`, `13498.74/12126.20`, and
`12086.29/14080.02` ms; body wall times were `758.50/708.06`, `816.30/700.17`, and `692.61/934.25` ms.
For this three-pair diagnostic, the control/a1 medians were `38030/35050` ms CPU and `13164.30/12126.20`
ms wall for typing-lowering, and `2270/2180` ms CPU and `758.50/708.06` ms wall for bodies. All samples
are retained here, including the slower third a1 pair. Other builds ran during the locked pairs. The earlier
wall-only probe and full Web pair above remain mixed, so a small wall-time change cannot be ruled out.

Three additional locked alternating-order pairs compiled the committed batch compiler sources with the control and
a1 compilers. Control/a1 typing-lowering milliseconds were `12834.08/18304.42`, `35861.66/17188.32`, and
`22313.87/17836.46`; body typing was `78.97/91.57`, `124.79/131.62`, and `162.84/132.00`. Peak RSS KiB was
`1684356/1686760`, `1695548/1687708`, and `1694400/1696508`. Other builds were running, including multiple
flat-structs decoder tests during the first a1 sample. The control/a1 medians were `22313.87/17836.46` ms for
typing-lowering and `124.79/131.62` ms for bodies. The spread is too large to establish a small body-time change.
All six compiler modules from these same-source runs were byte-identical, with SHA-256
`d6478a774ad1871f76c3ccb7f8f7621fc96f9c8cd7795ab0e8ca207b9b543937`.
