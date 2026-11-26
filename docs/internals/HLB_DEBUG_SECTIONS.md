# HLB debug sections

Since HLB version 7 (the dense format is at 8, `HlCode.VERSION`, which live builds write) a module carries
a versioned debug-section stream after the constant table. A module of sections (HLB 9, which plain builds write) carries the
opcode source spans and source snapshots as sub-sections of each module's section instead, in the same encodings
([MODULE_SECTIONS.md](../design/MODULE_SECTIONS.md), section 1). The stream starts with an unsigned section count. Each section contains
an unsigned kind, version, flags, payload length, and exactly that many payload
bytes. Readers must reject malformed known sections and skip unknown kinds or
versions by payload length.

Flag bit 0 (`HlWriter.COMPRESSED`) marks a compressed payload: the decoded size as an
unsigned index, then one LZ4 block (lz4's block format, no frame) that decodes to
exactly that many bytes. Every reader decodes it before reading the payload: the VM
at load (`hl_code_read`), `HlModuleReader`, and `scripts/report-binary-size.py`. The
compiler compresses the function identities with LZ4 HC (level 9) and the
development sections with LZ4's fast mode, through HashLink's `bytes_lz4_compress`
native over its vendored lz4, so every build of the compiler writes the same bytes.
Under the Haxe interpreter, which has no natives, sections are written uncompressed.
Why LZ4 here and zlib for an AOT executable's DWARF: see "Compression" in
`docs/design/AOT_BACKEND.md`.

Section kinds are independently versioned:

- `1:1` — function identities. Each record associates a stable function ID and
  HLB function index with qualified/display names and its enclosing source span.
- `2:2` — opcode source spans. The payload begins with a local table of
  length-prefixed UTF-8 source paths, followed by function groups ordered by
  stable function ID. Each mapping contains an opcode index, source-path index,
  signed start/end offsets encoded as `offset + 1`, start line/column, end
  line/column, a 32-bit FNV-1a hash of the UTF-8 source contents, and flags.
- `3:1` — compiled source snapshots. The payload contains entries ordered by
  signed 32-bit source hash. Each entry stores the hash followed by the length
  and exact UTF-8 bytes of the compiled source. Hashes are unique and zero is
  reserved for debug locations whose source snapshot is unavailable.

Opcode source-span flag bit 0 marks compiler-generated code. An unavailable
range is encoded as start and end `-1`; a present range must satisfy
`0 <= start <= end`. Function groups and opcode mappings are unique. These
invariants let debuggers use exact source locations while retaining the legacy
HLB file/line table as a fallback.
