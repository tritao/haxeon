# IR allocation report

Status: read-only prototype, stage 1 of a possible `@:noAlloc` check. Nothing is enforced and no source annotation exists yet.

`IrAllocationReport` lists what a function can allocate, following calls from it. It runs on the final post-inline IR, because
inlining and scalar replacement are what remove value-class temporaries.

Enable it with `HAXEON_IR_ALLOC_ROOTS`: exact IR function names, a prefix ending in `*`, or `@file` with one pattern per line.
Rows are written to stderr as `IR_ALLOC` JSON lines; a compiler server writes them to its log under `~/.cache/haxeon/compiler`.
A server reads its environment once, so use `@file` to change roots without restarting it.

## Kinds

| kind | meaning |
|---|---|
| `alloc` | creates a heap object each time it runs: `new`, a closure or its environment, boxing, an iterator, an enum with a payload, a string or array built by the runtime, a map `get` of primitive values, a map `keys` or `values` snapshot |
| `grow` | allocates only when capacity runs out: `push`, `insert`, `resize`, map `set`, string buffer add |
| `store` | an indexed array store; allocates only if the index is past the end (bounds are not checked) |
| `unknown` | an operation this report does not classify: a C native, an I/O or reflection native, a static closure, a virtual wrapper |
| `dynamic` | a call whose target is not resolved: a closure call, or a method call with more than `FanOutLimit` (8) implementations |

## What is followed

- Calls to program functions, breadth first, so each finding carries the shortest call chain from the root.
- A method call into every override of the receiver's class, or every class implementing its interface, up to the fan-out limit.
  Without the limit a frame root reaches every widget through `View.build`.
- A closure's body, from the point where the closure is created.

Blocks that end in a throw are skipped: they build an error and leave.

## What it does not know

- How often a path runs. An allocation behind a flag or a rare branch is reported like any other.
- Runtime natives are classified by name and signature. The C implementations were not read.
- A container's amortized growth shows as `alloc` inside its own grow function (`IdSet.grow`), reached from a call that usually does not grow.
- HashLink lowering may add allocations the IR does not show. Runtime counters (`hl.Gc.totalAllocated`) remain the ground truth.

## Checks

`tests/compiler/AllocationReportMain.hx` covers each kind, call chains, overrides, interface implementors, recursion, root patterns,
native classification and that the report leaves the IR unchanged.

Agreement with hand-made allocation-free code (key-scope project, 2026-10-29): `IdSet.has`, `IdSet.clear`, `RenderNode.find` and
`RenderNode.findFrom` report nothing; `LayoutAxis.fit`, which the allocation census named as a per-frame site, reports allocations.
