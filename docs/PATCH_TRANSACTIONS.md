# HashLink patch transaction

`hl_runtime_module_apply_hlp` holds the runtime-module mutex from decoding through
publication. Calls through the host runtime take the same mutex for stable-ID
resolution and remain locked until the call returns. Two patches based on the
same revision therefore serialize; the first may publish and the second observes
the new revision and fails as stale.

Before native staging, the host `Runtime.patchSet` boundary decodes the complete
HLP wire model and rejects malformed sections, unsupported patch opcodes,
truncated payloads, invalid debug metadata, and invalid source snapshots. The
Haxe-built `HlNativeModuleLoader.loadRuntime` path decodes and retains the
complete Haxe `HlPatch` model before native publication. Its envelope is a
derived identity-policy view, so the external path and host path share one HLP
wire decoder and the shared `HlPatchPolicy` compatibility validator. Native
still rechecks live compatibility and performs the JIT publication; the Haxe
transaction owns the decoded policy input, compatible appended type graph,
patched `hl_function` descriptors, source spans, and source snapshots. Native
retains the HLP wire decoder, machine-sensitive validation, and publication
mechanism, while the JIT and debugger consume the arena-owned registers,
opcodes, debug pairs, spans, and snapshots.
Before staging, that policy now also checks symbol-base counts and HashLink-
compatible prefix hashes, appended type references, stable-ID-to-slot mapping,
unchanged function signatures, register type indices, and relocation instruction
bounds against the loaded HLB model. It also checks that every patch debug file
is present in the loaded module's debug-file set. `HlPatchHashes` is shared by
the HLP writer and runtime policy, keeping the byte-level compatibility rule in
one Haxe-owned implementation.

`HlRuntimeModuleRegistry` keeps module replacement separate from patch
transactions. A patch changes the revision of the published module in place;
loading a replacement publishes a new module generation and retires the old
wrapper. `HlRuntimeModuleLease` makes Haxe-side borrowers explicit, while native
HashLink remains the final quiescence authority during retirement.

`HlRuntimePatchTransaction` snapshots the complete HLP model when staging: it
owns a copy of the patch bytes, records the base and target revisions, and
rejects a foreign module identity before native staging. Both `patch(bytes)`
and explicit stage/commit callers use this same transaction path. Commit still
rechecks the live revision, so two transactions staged from one generation
cannot both publish. A successful commit appends an `HlRuntimePatchGeneration`
record to the loaded module's Haxe-owned patch ledger. That record retains the
canonical patch model, envelope, published function-version snapshot, and
stable-ID dependency lists; failed and rolled-back transactions never enter the
ledger. Committed records and diagnostic accessors use deep HLP-model snapshots,
so mutating a transaction or returned diagnostic model cannot rewrite published
history. The same successful transition also advances the Haxe-owned symbol
pools, so later patches validate against the actual post-publication counts and
prefix hashes rather than the original HLB snapshot.

The legacy host `LoadedModule` follows the same ordering: it retains a
Haxe-owned revision, stable function-version table, and private patch-generation
ledger, and advances those records and its decoded symbol model only after the
native JIT publication result reports success. Its host-side function table
tracks identity, slot, signature, and generation, while each committed record
also holds one opaque native code handle for the published patch allocation.
The handle is an ownership token, not a callable address or a second dispatch
table; HashLink continues to own publication and target selection.

`RuntimeKernel` and `RuntimeJit` are the two Haxe declarations of the legacy
host's native bootstrap boundary. The kernel exposes opaque module loading,
invocation, metadata, and retirement operations; the JIT boundary exposes patch
publication and executable/code-region diagnostics. `Runtime` owns the policy
and transaction orchestration around both. Keeping these surfaces small and
separate makes the remaining native responsibilities explicit and leaves the
JIT implementation replaceable without spreading native declarations back
through the Haxe runtime facade. Both declarations accept the single opaque
`RuntimeModuleHandle` type, so splitting the bridge does not create a second
pointer representation for a loaded module. `RuntimeJitBackend` is the
Haxe-owned interface for this mechanism; `NativeRuntimeJitBackend` is the
current HashLink adapter and keeps its forwarding calls inline so generated
runtime code retains direct native-call lowering.

For the legacy host, `PatchSet` copies its HLP bytes at construction. The
transaction decodes and publishes that owned snapshot, so a compiler result or
caller-owned buffer can be reused or mutated without changing a staged native
publication input. `RuntimeJitBackend.applyPatch` receives the staged
transaction rather than an unrelated byte buffer; the current native adapter
extracts the owned bytes at the final ABI boundary. This keeps the Haxe policy
record and its publication input coupled for future backend implementations.

`Runtime` also keeps a small side ledger of committed patch revisions, native
code handles, and their JIT lifecycle codes. Each entry is a
`RuntimeJitGeneration` owner rather than a set of independently synchronized
arrays. Native success creates a `Published` entry and transfers one external
owner for the new `hl_patch_code` allocation; a close request changes live
entries to `Retiring`, and successful native retirement releases those handles
and removes the module's ledger entry.
HashLink still decides dispatch publication and executable-memory reclamation.
When module teardown has detached an allocation from its owner lists, the
external handle is what keeps its code and decoded function metadata alive until
Haxeon finishes retiring the generation.

Haxeon-generated `Runtime.load` also records the base `HlMetadataGeneration`
beside the `LoadedModule` in a parallel ledger. Native disposal completes before
that arena is released, so Haxe-owned type, function, pool, and debug pointers
remain valid for the whole native module lifetime.

The Haxe-built external loader follows the same rule: every committed external
patch generation privately owns one native code handle, while diagnostic
snapshots remain non-owning. The generation releases its handle only after the
runtime wrapper has retired, so policy owns code lifetime without exposing
executable addresses.

`HlRuntimePatchLedger` now owns the Haxe-side generation history separately from
the module loader. It maps each stable function ID to the generation that last
published it and records a generation in a Haxe-owned retirement list once all
of that generation's replaced functions have been superseded. This is policy
state only: the native dispatch-owner array and closure/JIT reclamation rules
still decide when executable storage can actually be freed. The split makes
generation ownership and future borrower-aware retirement explicit without
moving bootstrap-sensitive reclamation into Haxe prematurely.

The external wrapper exposes the existing native staging-failure checkpoints
only for tests. Exercising all three checkpoints proves that Haxe arena cursors,
symbol models, revisions, dispatch results, and the retirement ledger remain
unchanged when native publication rejects a candidate, and that the same HLP
can be retried successfully afterward.

The Haxe-built external path decodes HLP exactly once. `HlPatchReader` owns the
wire-format parse and `HlNativeMetadataBuilder` projects the resulting model
into an arena-owned `HlRuntimePatchInput`, including native-layout instruction,
relocation, debug-file, and source-snapshot records. The native bridge consumes
that model directly; it does not call `hl_patch_read` or allocate a second HLP
model for this path. The legacy byte-oriented entry points retain the native
HLP parser for ordinary HashLink compatibility.

`Runtime.stagePatch` exposes the same staged/committed/rolled-back lifecycle for
the legacy host path, while `Runtime.patchSet` remains the convenience API that
stages and commits immediately. Host policy validation and native publication
are performed under the module mutex at commit time, so a transaction staged
against an older generation becomes stale rather than publishing out of order.

Native staging then validates module identity, revision and symbol bases,
prefix hashes, the complete appended-type delta, stable function identity,
relocations, register and symbol bounds, opcode operands, and duplicate slots.
HLP version 7 also validates content-addressed source snapshots before copying
them into the staged code owner; their lifetime therefore matches active or
retired patch JIT code that can reference them in debugger stacks.
On the Haxe-built external path, Haxeon has already constructed the compatible
appended type records, patched function descriptors, source spans, source
snapshots, and cumulative integer, float, and string pools in the generation's
arena. It also constructs an arena-owned resolution plan: every replacement
function and relocation carries its stable identity and the dispatch slot
chosen by Haxe policy. The projection applies those slots directly to the
instruction operands before publication. Native validates the resolved model
and does not derive the Haxe path's replacement or relocation mapping from the
wire data. Native borrows the Haxe pool and debug pointers and swaps them into
the live module only during successful publication. The legacy native-decoder
path retains the old native combined-pool, type, function, debug, and
relocation staging behavior. Any failure frees staged storage; the Haxe path
also rolls back its arena, pool
model, and type-table cursors, leaving the published revision, symbol counts,
dispatch pointers, and owners unchanged.

Publication begins only after JIT finalization and owner-array capacity are
ready. Under the same mutex, the runtime marks Haxe-prepared appended types as
module-owned (or transfers native-staged type ownership on the legacy path),
advances the visible type count, swaps all affected dispatch slots and their code
owners, replaces append-only symbol storage, and finally advances the revision.
Because callers use the mutex, they observe either the complete old state or the
complete new state.

The repeatable hot-reload gate covers malformed bytes, bad prefix hashes, invalid
metadata references, arena exhaustion, foreign identities, stale patches,
exceptions, repeated replacement, a call overlapping publication, and two
competing writers. One-shot test checkpoints force rollback after symbol staging,
type staging, and finalized JIT staging; the same patch must then succeed without
changing its base revision. Native sanitizer support and shutdown races remain
to be added to the gate.
