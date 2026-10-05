# Text editor performance (2026-09-23)

## Method

The baseline used UIKit from `e67f1714`, immediately before the retained-layout
change. The current build used the same HashLink runtime and native UIKit library.
The synthetic document contained distinct, numbered 81-byte ASCII lines. Both versions used
IBM Plex Sans at an 800-pixel layout width. Measurements ran headlessly on Linux;
they include native layout and UI frame submission, but not GPU presentation.

The core workload loaded each document, inserted and deleted one character near
the middle five times, then moved the caret to
20 positions. The UI workload alternated Control+End and Control+Home in an
800×600 multiline `TextField`, then inserted and deleted a character at the
start eight times and inserted one newline. Each reported result is the median
of three runs.

## Results

| Lines | Baseline core edit | Current core edit | Current UI caret jump | Current UI insert + frame | Current UI delete + frame | Current UI newline + frame |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 29 ms | 4.3 ms | 0.22 ms | 5.9 ms | 6.0 ms | 7.5 ms |
| 5,000 | 149 ms | 13 ms | 0.69 ms | 19.5 ms | 20.1 ms | 21.2 ms |
| 10,000 | 309 ms | 24 ms | 1.27 ms | 36.5 ms | 38.5 ms | 38.7 ms |

The previous full-document text node failed native UI submission at 800 lines in
this workload. The first paragraph-backed version exhausted native layout
resources at 5,000 lines. Grouping 64 paragraphs per retained layout removed
that limit for the measured 10,000-line case. The current layout paints only
chunks intersecting the visible range.

Initial load remains linear: about 0.13 s, 0.63 s, and 1.26 s for 1,000,
5,000, and 10,000 lines. Constructing the whole-document Unicode offset map
alone took about 0.47 s at 10,000 lines. In a 10,000-line middle edit, document
byte assembly took about 7 ms and updating the offset map about 13 ms; the
rest of the roughly 24 ms core edit included layout and state work.

Repeated full UI caret jumps initially took about 279 ms at 10,000 lines
(input and frame combined). Passing the cached code-point length into text
semantics reduced that to about 1.27 ms. The text node now spans document height
so its local clip includes scrolled chunks; its parent clips to the viewport.

With ordinal 64-paragraph chunks, one newline near the start of distinct text
reshaped most of the document and took about 295 ms at 10,000 lines. The
incremental paragraph edit path keeps unaffected chunks stable and reduced
that operation to about 39 ms through the full UI workload.

## Next bottleneck

Typing at the start of 10,000 lines still exceeds a 16 ms frame budget. The
whole-document offset arrays and text bytes are shifted or copied for each
edit. A segmented document and offset index is the next performance change to
evaluate. These measurements do not establish a need for tile rendering.

The workload is synthetic ASCII text with one font. It does not measure GPU
rasterization, long wrapped lines, syntax highlighting, or IME composition.

## Segmented document follow-up (2026-09-24)

The same full UI workload was rerun after moving editable text and its Unicode
offset indexes into EditorKit segments. Each cell is the median of three runs.

| Lines | Previous insert + frame | Segmented insert + frame | Segmented delete + frame | Segmented newline + frame | Segmented caret jump |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 5.9 ms | 3.8 ms | 3.7 ms | 5.4 ms | 0.21 ms |
| 5,000 | 19.4 ms | 5.2 ms | 5.2 ms | 6.7 ms | 0.70 ms |
| 10,000 | 36.6 ms | 7.2 ms | 7.3 ms | 9.3 ms | 1.30 ms |

For the core workload, median middle insertion/deletion at 10,000 lines took
5.7 ms each, compared with roughly 24 ms for a core edit before segmentation.
The core newline insertion at the start took 8.1 ms, with the paragraph count
advancing from 10,001 to 10,002 in each run.

The new offset arrays are local to roughly 2 KiB newline-aligned segments.
An edit rebuilds affected segments and an index of segment prefix lengths;
it does not shift offsets for the whole document. Initial UI load stayed near
1.27 s at 10,000 lines. `TextField.value` and `onChange(String)` still assemble
a complete string for each edit, and a paragraph without newlines can still
form one large segment. GPU presentation and IME behavior remain unmeasured.

The measurements above predate the shared-document UIKit API. A field backed by
`TextField.withDocument` now updates retained paragraph layouts from document
slices and can publish `EditTransaction`s without assembling the full string.
The compatibility `onChange(String)` callback and consumers that request the
semantic value still materialize it.

A separate headless paired run compared string-backed and shared-document
`TextArea`s with 10,000 distinct 70–74-byte lines, an 800×600 frame, and IBM
Plex Sans. Each case alternated eight inserts and backspaces, submitting a frame
after each edit; the first two samples were discarded. Across three process
runs, insert-plus-submit medians were 4.24 ms for the string-backed field and
4.19 ms for the shared document. That 0.05 ms gap is within run-to-run noise,
so this workload shows no meaningful speedup. The shared model removes the
required full-string copy for clients that use transactions, while paragraph
shaping and frame submission still dominate this measurement. Long-paragraph
shaping remains linear in paragraph length. These timings exclude GPU
presentation.

## Viewport-local custom content (2026-09-24)

UIKit custom content now receives a conservative visible rectangle in node-local
coordinates, and its retained paint list is clipped to that rectangle. The
multiline text node uses the 600-pixel viewport height; the editor painter
translates the document by the scroll offset inside its own canvas. Pointer
hit testing and IME caret placement convert between viewport and document
coordinates at the widget boundary.

In three more headless runs of the same 10,000-line workload, alternating
Control+End and Control+Home kept the text node at 600 px with no layout
translation. Each end produced a small paint list (6–7 commands); median
paint-list construction took about 0.01 ms. Median caret jump plus frame
submission was 1.77 ms, and insertion plus frame submission was 8.85 ms.
These are CPU timings without GPU presentation or a visual pixel check.

## Headless visual and edge-case check (2026-09-24)

An Xvfb capture exposed an older bug: the intrinsic paint provider was present
on the text node, but runtime type detection through the `LayoutContent`
interface failed, so its display list was never attached. `LayoutContent` now
reports its paint capability explicitly. The text-field capture changed from
zero non-background pixels in the text bounds to 457; the multiline story also
renders text. A temporary 10,000-line multiline story visibly rendered the
last numbered lines, including `009999`, in a 120-pixel editor viewport.

A headless EditorKit check compared segmented and whole-string indexes after
80 mixed Unicode edits. Document text, paragraph ranges, and sampled code-point,
UTF-8, and UTF-16 conversions matched. The UIKit framework and layout-session
smoke checks passed. A 5,000-line, 155 KB Unicode UI workload had median
insertion plus frame time of 3.49 ms across three runs.

One very long wrapped paragraph is the next measured bottleneck. Median
insertion plus frame time was 5.3 ms at 5.3 KB, 12.9 ms at 13.3 KB, 25.4 ms
at 26.5 KB, and 50.5 ms at 53 KB. Each edit reshapes the entire paragraph.
The Xvfb captures verify renderer output in a virtual display, but they do
not exercise an operating-system IME session or compare every rendered pixel
with a golden image.

## Long-paragraph document segments (2026-09-24)

EditorKit now splits storage segments at code-point boundaries inside long
paragraphs, while preferring a nearby newline. Paragraph range lookup joins
the ranges from those segments. Repeating the same headless UI workload gave
about 10 ms insert plus frame at 26.5 KB and 19 ms at 53 KB, down from about
25 ms and 50 ms in the earlier run. The native shaper still receives and
reshapes the complete logical paragraph, so that cost continues to grow with
paragraph length. Splitting native shaping and layout while preserving
wrapping, ligatures, bidirectional text, and caret geometry remains open.
