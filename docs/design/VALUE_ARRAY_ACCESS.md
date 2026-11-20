# Reading value arrays at the cost of a field

Status: proposed (first step implemented: inline scalar reads, `HlLower.lowerValueArrayRead`).

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
   validity bitmap moves before the payload, at a fixed offset from the lane's start, so checking presence is one load
   too (today it follows the payload, at an offset that depends on the capacity).
3. **Bounds checks proved once.** An IR analysis of indices proven in range (loop induction variables bounded by the
   array's length, an index checked earlier on every path) removes the check from reads it covers, for raw `Int` and
   `Float` arrays as for value arrays; raw arrays have a per-block version of this already (`provenInRange`).

## Migration

1. Inline scalar reads, the header compared per read (done).
2. Headers resolved per array value, in `HlLower`, within a block first (as `elementOffsets` and `provenInRange` are),
   then across blocks from the value's definition.
3. Value array reads and writes as IR operations with their layout; the natives remain for `Dynamic` bridges and the
   reflection paths. The validity bitmap before the payload, in the runtime and both Wasm backends at once.
4. The bounds analysis, then its use by the raw array accesses in place of `provenInRange`.

## Checks

A loop reading a million-element array of an enum, against the same loop over objects' enum fields; the compiler's self
compile (allocated bytes, main-thread instructions); the value array tests, Wasm parity and the full test driver at each
step. Layout offsets the lowering reads are asserted in the runtime (`value_arrays.c`).
