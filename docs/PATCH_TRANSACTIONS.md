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
transaction owns the decoded policy input that can grow into patch-state
ownership without introducing a second mutable representation.
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
ledger, and advances those records and its decoded symbol model only after
`RuntimeJit.patch` reports success. Its host-side function table deliberately
tracks identity, slot, signature, and generation without pretending to own the
native JIT entrypoint addresses; those remain inside the native HashLink kernel.

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
competing writers. One-shot test checkpoints force rollback after symbol staging,
type staging, and finalized JIT staging; the same patch must then succeed without
changing its base revision. Native sanitizer support and shutdown races remain
to be added to the gate.
