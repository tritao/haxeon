# HashLink patch transaction

`hl_runtime_module_apply_hlp` holds the runtime-module mutex from decoding through
publication. Calls through the host runtime take the same mutex for stable-ID
resolution and remain locked until the call returns. Two patches based on the
same revision therefore serialize; the first may publish and the second observes
the new revision and fails as stale.

Before staging, the runtime validates module identity, revision and symbol bases,
prefix hashes, the complete appended-type delta, stable function identity,
relocations, register and symbol bounds, opcode operands, and duplicate slots.
It also validates content-addressed source snapshots before copying them into the
staged code owner; their lifetime therefore matches active or retired patch JIT code
that can reference them in debugger stacks.
The compiler writes HLP 12 (`HlSectionPatch`), made of module sections, which is first
linked against the link state the loader kept for the module (`hl_module_link_patch`,
docs/design/MODULE_SECTIONS.md, "As built in slice 4a" and "As built in slice 4b").
That fills the same tables HLP 11 carries, so the checks above run on it unchanged
except the prefix hashes, which keys replace. What the linker staged in the link state
is committed with the patch or dropped with it. HLP 11 is still read, for the runtime
tests that build it by hand, until it is deleted.
It then creates combined symbol tables, initializes reserved non-moving type
slots, builds private function metadata, and JIT-compiles a private code image.
Any failure frees staged storage and clears reserved type slots while leaving the
published revision, symbol counts, dispatch pointers, and owners unchanged.

Publication begins only after JIT finalization and owner-array capacity are
ready. Under the same mutex, the runtime transfers appended-type ownership,
advances the visible type count, swaps all affected dispatch slots and their code
owners, replaces append-only symbol storage, and finally advances the revision.
Because callers use the mutex, they observe either the complete old state or the
complete new state.

The repeatable hot-reload gate covers malformed bytes, an unreadable section, invalid
metadata references, arena exhaustion, foreign identities, stale patches,
exceptions, repeated replacement, a call overlapping publication, and two
competing writers. One-shot test checkpoints force rollback after symbol staging,
type staging, and finalized JIT staging; the same patch must then succeed without
changing its base revision. Native sanitizer support and shutdown races remain
to be added to the gate.
