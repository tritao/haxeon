# HashLink patch transaction

`hl_runtime_module_apply_hlp` holds the runtime-module mutex from decoding through
publication. Calls through the host runtime take the same mutex for stable-ID
resolution and remain locked until the call returns. Two patches based on the
same revision therefore serialize; the first may publish and the second observes
the new revision and fails as stale.

Before staging, the runtime validates module identity, revision and symbol bases,
prefix hashes, the complete appended-type delta, stable function identity,
relocations, register and symbol bounds, opcode operands, and duplicate slots.
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

The repeatable hot-reload gate covers malformed bytes, bad prefix hashes, invalid
metadata references, arena exhaustion, foreign identities, stale patches,
exceptions, repeated replacement, a call overlapping publication, and two
competing writers. Allocation failure is handled by every staging allocation but
is not yet deterministically injected. Native sanitizer support and shutdown
races remain to be added to the gate.
