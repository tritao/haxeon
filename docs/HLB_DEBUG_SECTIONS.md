# HLB debug sections

HLB version 7 appends a versioned debug-section stream after the constant
table. The stream starts with an unsigned section count. Each section contains
an unsigned kind, version, flags, payload length, and exactly that many payload
bytes. Readers must reject malformed known sections and skip unknown kinds or
versions by payload length.

Section kinds are independently versioned:

- `1:1` — function identities. Each record associates a stable function ID and
  HLB function index with qualified/display names and its enclosing source span.
- `2:1` — opcode source spans. The payload begins with a local table of
  length-prefixed UTF-8 source paths, followed by function groups ordered by
  stable function ID. Each mapping contains an opcode index, source-path index,
  signed start/end offsets encoded as `offset + 1`, line, and flags.

Opcode source-span flag bit 0 marks compiler-generated code. An unavailable
range is encoded as start and end `-1`; a present range must satisfy
`0 <= start <= end`. Function groups and opcode mappings are unique. These
invariants let debuggers use exact source locations while retaining the legacy
HLB file/line table as a fallback.
