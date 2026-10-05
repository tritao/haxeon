# Haxeon editor

`haxeon.editor` owns editable UTF-8 documents and Unicode coordinate types.
It has no UI, GPU, platform, or SceneKit dependency. UI widgets consume this
model through `haxeon.ui`; the orbit camera lives in `nativekit.scene`.

`TextDocument` stores text in roughly 2 KiB UTF-8 segments. It prefers a nearby
newline, but also splits long paragraphs at code-point boundaries. Each
segment has its own `TextOffsetMap`; paragraph ranges that cross segment
boundaries are joined when queried. An edit rebuilds the affected segments and
the segment prefix index while leaving other segments' offset arrays in place.

The document exposes code-point range replacement and slicing, coordinate
conversion, and paragraph lookup. `text` is assembled lazily for clients that
need a complete string. UIKit's retained editor layout consumes paragraph
slices directly. The compatibility `TextField.value` and `onChange(String)`
APIs still assemble the complete value; shared-document fields can instead
report local `EditTransaction`s without that copy. `TextDocument.revision`
lets a field detect edits made by its owner between UI submissions. Long-
paragraph shaping remains linear in paragraph size; bounding document index
segments alone does not bound that layout work.

Use `TextField.withDocument` or `TextArea.withDocument` when the application
owns the document. The field applies native and keyboard edits to that same
`TextDocument`, and its optional `onEdit` callback receives the applied
transaction with the removed text attached for undo/history. Transaction
positions use Unicode code points. Reading `TextField.value`, requesting
accessibility's semantic value, or subscribing to `onChange(String)` still
materializes the full string on demand.

Run the headless Unicode coordinate and edit check with
`./scripts/haxeon run --project packages/editor/tests/haxeon.json` from the
Haxeon root. It checks Unicode edits in both many-paragraph documents and a
long paragraph that crosses multiple storage segments.
