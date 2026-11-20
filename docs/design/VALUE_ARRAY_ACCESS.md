# Reading value arrays at the cost of a field

Status: proposed; steps 1 to 4 implemented on HashLink (`HlLower.lowerValueArrayRead`, `valueArrayView`, the validity lane in `value_arrays.c`).

## Problem

An `Array` of payload-free or inline enums, or of structs, is a value array (`IrValueArrayLayout`): elements are laid out
in a scalar lane and a reference lane, not boxed. Reading one element used to make two native calls, a validation and
`__value_array_read_*`, each finding the array's descriptor, checking the index and computing the slot: about five times
the cost of reading the same enum from an object's field. The first step reads 8, 16 and 32 bit slots of arrays without
validity bits inline, which halves it, but each read still finds out at run time what the compiler could know:

- **Which header it holds.** A typed `Array<E>` is either the value array itself or a forwarding header: an ordinary array
  converted in place where it entered typed code (`__value_array_retype`), so that its `Dynamic` aliases see the same
  array. A forwarding header's `data` is the value array's descriptor, which is how the runtime finds it. So every read
  compares the header's type with the value array's (as pointers: the VM compares type registers structurally).
- **The element's layout.** The stride is read from the header, though the element type fixes it.
- **The index and the header again,** for every read of the same array in a loop.

## Proposal

1. **Resolve a header once per array value.** Whichever header a typed `Array<E>` value is, it stays that header, and the
   value array it leads to (itself, or a forwarding header's `data`) keeps its identity when it grows. So the lowering
   resolves it once per SSA array value, where the value is defined or first read, to a register holding the value array
   itself; every read takes the size and the scalar lane from that. Forwarded arrays get the fast path too, and the type
   global and its comparison leave the reads.
2. **Layout in the IR.** Reads and writes become IR operations that carry the element's slot and layout (stride, offset,
   width, sign, whether elements have validity bits) instead of calls to `__value_array_read_*` with constant arguments.
   HashLink lowers them to a bounds check and a load; the Wasm backends lower them as they lower the natives now. The
   validity bitmap becomes a lane of its own, which the value array points to as it does to its reference lane, so
   checking presence is a load and a bit test (today it follows the payload in the scalar lane, at an offset that
   depends on the capacity; moved before the payload, the payload's offset would depend on it instead).
3. **Bounds checks proved once.** An IR analysis of indices proven in range (loop induction variables bounded by the
   array's length, an index checked earlier on every path) removes the check from reads it covers, for raw `Int` and
   `Float` arrays as for value arrays; raw arrays have a per-block version of this already (`provenInRange`).

## Migration

1. Inline scalar reads, the header compared per read (done).
2. Headers resolved per array value where the value is defined (done).
3. The bounds analysis (`IrLoopBounds`) for value array reads (done). Raw `Int` and `Float` reads keep the VM's check:
   on x86-64 its fused check and load costs less than a separate load, and on ARM64 the gain needs a fused opcode in
   the VM.
4. The validity lane in the HashLink runtime, so arrays of non-null structs read inline too (done). The Wasm runtimes
   keep their own layouts; nothing else depends on this one.
5. Value array reads and writes as IR operations with their layout; the natives remain for `Dynamic` bridges and the
   reflection paths.

## Checks

A loop reading a million-element array of an enum, against the same loop over objects' enum fields; the compiler's self
compile (allocated bytes, main-thread instructions); the value array tests, Wasm parity and the full test driver at each
step. Layout offsets the lowering reads are asserted in the runtime (`value_arrays.c`).
