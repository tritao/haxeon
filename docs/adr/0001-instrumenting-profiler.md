# 1. Instrumenting profiler

Date: 2026-10-23

## Status

Accepted.

## Context

The profiler sampled stacks at a fixed rate and recorded a few hand-placed
spans. Sampling shows where time goes on average but cannot show what one slow
frame did. We want every function call recorded, in Haxe and in the native
code we compile, cheaply enough to leave on while using the editor, and viewable
in Perfetto now and in live viewers such as Tracy later.

The existing recording path could not carry that volume: every record went
through one process-wide 8 MiB ring behind a mutex, spans converted their names
to UTF-8 on each call, and the client polled for 256 KiB at a time.

## Decisions

1. **Sources, not modes.** A session combines `instrument`, `sampling` and
   `alloc`; spans, counters, frame marks and GC statistics are always on.
   Instrumentation is the default once it exists.
2. **The full timeline is recorded.** Totals are derived from it. There is no
   in-application call tree.
3. **Haxe probes come from a compiler pass** over the SSA IR, lowered by each
   backend, rather than from the JIT's prolog and epilog. Only a compiler pass
   reaches every backend, and lowering to a JIT intrinsic keeps the cost of a
   JIT-only approach.
4. **Native probes come from `/Gh /GH`**, scoped per translation unit. Code we
   do not compile is seen only at the boundary: import-table hooks, the DXGI and
   D3D11 vtables, and Vulkan wrappers.
5. **Instrumentation is a separate build flavor.** Ordinary builds carry no
   probes; inside the flavor a global flag starts and stops recording.
6. **Per-thread lock-free buffers** of pooled chunks, drained by one consumer.
   When the pool runs out the producer stalls and records the stall; it never
   drops records.
7. **Assembly happens outside the application.** The runtime pushes compressed
   per-thread segments over the diagnostics socket; a recorder writes them to a
   capture, which an exporter turns into a Perfetto trace. A live viewer is
   another client of the same stream.
8. **One tick clock** (TSC where invariant), calibrated by periodic clock pairs
   and converted only by readers.
9. **Throws close slices with one `UNWIND` record** carrying the depth saved
   when the trap was set.

## Consequences

- The diagnostics protocol moves to version 2 (push streaming) and captures to
  HLPC version 2. Clients of the old pull protocol, including the editor's
  profiler panel, are ported.
- The recorder core moves into `libhl` so the VM, the runtime HDLL and
  instrumented native modules write to the same buffers.
- Instrumented captures are large; recording controls (manual start and stop,
  duration and size limits) are part of the plan.
