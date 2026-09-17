# Runtime self-hosting lifecycle

This document defines the current Haxeon/HashLink runtime boundary. It is the
lifecycle companion to [METADATA_OWNERSHIP.md](METADATA_OWNERSHIP.md) and
[PATCH_TRANSACTIONS.md](PATCH_TRANSACTIONS.md).

The objective is not to remove every line of native code. Haxeon owns runtime
policy, decoded metadata, generation state, and lifetime decisions; HashLink
retains the bootstrap-sensitive kernel: JIT code, executable memory, GC
materialization, native symbols, and platform operations.

## Current architecture

```text
HLB/HLI                         HLP
  │                              │
  ▼                              ▼
Haxe HlReader                 Haxe HlPatchReader
  │                              │
  ▼                              ▼
HlMetadataGeneration          HlRuntimePatchInput
  │                              │
  ├── hl_code graph              ├── resolved slots/relocations
  ├── type arena                 ├── patched function descriptors
  ├── constants                  ├── scalar pools
  └── dispatch table             └── debug/source records
          │                              │
          ▼                              ▼
hl_runtime_module_load_       hl_runtime_module_apply_
haxe_metadata                 haxe_patch
          │                              │
          └──────────────┬───────────────┘
                         ▼
                 HashLink native kernel
                 JIT / GC / OS / ABI
```

The normal Haxeon path passes no raw HLB bytes to HashLink. An original HLB is
accepted only by the explicit debugger payload variant for legacy MAP support;
it is not used to construct execution metadata.

## Cold-load lifecycle

`HaxeRuntimeModuleLoader` performs these steps:

1. Validate the decoded HLI manifest against the Haxe module model.
2. Build the complete `hl_code` graph in a non-moving `HlMetadataGeneration`.
3. Build the stable-ID to dispatch-slot table in Haxe-owned storage.
4. Call `hl_runtime_module_load_haxe_metadata` through
   `HlRuntimeModuleKernel`.
5. Register the native module handle with the Haxe lifecycle owner before
   GC-sensitive initialization can fail.
6. Publish object prototypes from the Haxe-owned type records.
7. Materialize constants through the narrow native constant kernel.
8. Invoke the validated initializer slot, if one exists.

The native loader borrows the Haxe records and identity arrays. It may allocate
JIT, module-global, GC, and platform state, but it does not parse HLB/HLI or
rebuild the metadata graph.

If any step fails, the Haxe owner disposes the native wrapper and metadata
generation. A retirement-blocked wrapper remains in the retryable Haxe queue;
its generation is not freed until native retirement succeeds.

## Patch lifecycle

`HaxeRuntimePatchCoordinator` owns patch policy and generation state:

```text
active generation
        │
        ▼
decode HLP once in Haxe
        │
        ▼
validate identity, revision, ABI compatibility, and policy
        │
        ▼
stage next function versions and metadata arena checkpoint
        │
        ▼
hl_runtime_module_apply_haxe_patch
        │
        ├── failure → rollback checkpoint and discard candidate
        │
        └── success → publish JIT slots, commit generation, retire old one
```

Before native publication, Haxe resolves stable IDs to slots and constructs the
native-layout patch projection. The native kernel still validates the prepared
projection, performs JIT work, and publishes executable addresses. Haxe commits
the function-version table and generation only after native publication reports
success.

Every pre-commit failure must leave the previous revision, type count, dispatch
slots, JIT generation, and module behavior unchanged. Native failure injection
and the golden lifecycle test exercise this rule.

## Ownership invariants

| Resource | Allocated by | Owner | Native may retain it until |
| --- | --- | --- | --- |
| `hl_code`, types, functions, constants, pools | Haxe metadata arena | `HlMetadataGeneration` | module/generation retirement |
| stable IDs and dispatch slots | Haxe dispatch table | loaded module generation | module retirement |
| decoded patch input | Haxe metadata arena | patch transaction/generation | patch publication completes |
| materialized constants and globals | HashLink module allocator | HashLink module | native module retirement |
| JIT code and executable pages | HashLink JIT allocator | native module/code handle | active calls and retained handles finish |
| managed objects and closures | HashLink GC | originating module/GC owner | all managed borrowers finish |
| explicit GC handles | HashLink GC handle bridge | owning Haxe module or process | handle close/finalization |

The central invariant is:

```text
Anything reachable by native runtime state is either

1. in the active Haxe generation,
2. in an explicitly retained older generation, or
3. permanently owned by the native/process kernel.
```

Raw pointers are borrowed views. They do not keep an arena, module, JIT image,
or GC object alive. A pointer becomes invalid when its recorded owner retires,
so a native pointer stored in a generation must not outlive that generation.

## Structural reload policy

The v1 policy is deliberately conservative:

- compatible primitive, abstract, function, reference, and nullable descriptors
  may append to the reserved type arena;
- code-only and metadata-compatible patches publish through the normal patch
  transaction;
- object, virtual/interface, enum, method, packed-layout, inheritance, or
  function-signature changes are structural;
- structural changes create a replacement module/generation and do not mutate
  the live object layout in place;
- state crossing a structural boundary uses a host-owned serialized state
  envelope, not pointers to old-generation objects or callbacks.

Arena exhaustion follows the same replacement-generation path. The arena is
contiguous and non-moving because HashLink consumers retain `hl_type *` values
and may derive type indices by pointer subtraction.

## Legacy compatibility boundary

The following native byte-oriented APIs remain for ordinary HashLink and native
callers:

- `hl_runtime_module_load` for native HLB decoding;
- `hl_runtime_module_apply_hlp*` for native HLP decoding;
- the standard `hl_runtime_module_load_code` compatibility entrypoint.

They are not part of Haxeon runtime execution. Haxe-owned load and patch
operations enter a thread-local decoder guard; an accidental `hl_code_read` or
`hl_patch_read` call fails and is counted. The boundary audit also checks that
removed Haxeon aliases and bridge declarations do not return.

The Haxe bindings enforce the same separation. `HlRuntimeJitBackend` exposes
only publication of a decoded patch projection plus executable-code lifetime
and inspection operations. Encoded `patch`, `patchCode`, and
`patchCodeWithHaxeTypes` calls live behind the explicitly named
`HlLegacyRuntimePatchBackend`, which is retained only by the compatibility
facade. `HlLoadedRuntimeModule` and the host runtime publisher use the decoded
metadata method directly.

## Native kernel responsibilities

The native boundary should remain small and mechanism-focused:

- initialize and retire a wrapper around Haxe-owned metadata;
- materialize GC-sensitive constants and globals;
- publish executable object prototypes;
- JIT changed functions and publish executable dispatch slots;
- allocate/release executable memory and platform unwind/debug state;
- perform native symbol lookup, GC operations, and platform ABI work;
- report quiescence and retirement diagnostics.

It must not decide Haxe metadata ownership, patch compatibility, stable function
identity, generation policy, or structural migration policy.

## Verification commands

The boundary audit is intentionally cheap and runs as part of the normal suite:

```text
bash scripts/test-haxeon-runtime-boundary.sh
bash scripts/test-haxeon-runtime-metadata.sh
HAXEON_RUNTIME_STRESS_ITERATIONS=1000 bash scripts/test-haxeon-runtime-stress.sh
TEST_JOBS=1 ./scripts/test.sh
./scripts/test-sanitizers.sh
```

The metadata suite covers decoder rejection, rollback, the golden
load/patch/GC/retirement lifecycle, and host transactions. The stress suite
repeats patch, execution, collection, and retirement across 1,000 generations.
