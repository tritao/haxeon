# Runtime metadata ownership

This table defines the ownership rules used by the reload runtime. Logical IDs
belong to compiler state; physical pointers always belong to one loaded runtime
module generation.

## Cutover contract

The Haxe-owned path is identified by `HL_MODULE_HAXE_METADATA`. In that path,
Haxeon is the sole owner of decoded module metadata, type/function identity,
patch policy, and generation lifetime. HashLink borrows those records while it
performs JIT, executable-memory, GC, native-symbol, and platform work. The
native kernel must not decode HLB/HLP bytes or reconstruct a metadata graph for
this path.

The legacy path remains deliberately separate: `hl_runtime_module_load` may
decode HLB and the legacy byte-oriented patch entry points may decode HLP. Those
entry points own the native compatibility graph until their module is retired;
they are not alternate implementations of the Haxe-owned path.

The handoff is therefore narrow and explicit:

| Operation | Haxe-owned entrypoint | Native responsibility |
| --- | --- | --- |
| Cold load | `hl_runtime_module_load_haxe_metadata` | Borrow `hl_code`, identity/slot arrays, and optional debugger payload; initialize JIT/runtime state |
| Patch | `hl_runtime_module_apply_haxe_patch` | Validate the prepared projection, JIT changed functions, and publish executable slots |
| Retirement | Haxe registry/module owner | Check native quiescence and release executable/platform resources |

No pointer in the handoff is implicitly transferred. Haxe-owned arenas and
decoded models stay alive until native retirement succeeds; native executable
allocations stay alive until their Haxe generation owner releases its handle.

The dedicated Haxeon runtime facade also enters a thread-local native-decoder
guard around its cold-load and Haxe-decoded patch publication operations. Any
accidental call to `hl_code_read` or `hl_patch_read` is rejected immediately;
the legacy byte-decoder APIs remain available outside those guarded operations.

| Category | Allocator | Owner | Borrowers | Retirement |
| --- | --- | --- | --- | --- |
| Module identity and stable IDs | Compiler HCS/HLI codecs | Compiler state and Haxeon `LoadedModule`; the decoded Haxe manifest is borrowed by `hl_runtime_module` | Host reconnect logic, stable-ID resolver, native call validation | Compiler state and `LoadedModule` release; legacy native copies release with the runtime module |
| Base bytecode metadata | Haxeon metadata arena for `HlNativeModuleLoader.loadRuntime`; HashLink code reader arena for the legacy host facade | `hl_module` | JIT code, globals, objects, closures, reflection | Runtime-module release after calls have quiesced |
| Type arena entries | Haxeon metadata arena on the Haxe-built path; HashLink code arena on the legacy path | `hl_module` | JIT code, heap values, globals, reflection | Runtime-module release; future GC pinning may permit earlier generation retirement |
| Function dispatch slots | Haxe runtime manifest plus `hl_module` | Loaded module generation and Haxe `HlFunctionVersionTable` | Patchable calls and staged closures | Runtime-module release |
| Base JIT image | HashLink executable allocator | `hl_module` | Dispatch slots, closures, active calls | Runtime-module release after calls quiesce |
| JIT ABI wrapper image | HashLink executable allocator | Process runtime | Dynamic-call bridge and wrapper closures | Global HashLink shutdown after all modules and managed values are finished |
| Module-registry snapshot | HashLink module registry | Debugger, profiler, stack capture, symbol resolver, or type dump operation | Module metadata during one inspection | Reader releases its pin; unload waits after removing publication |
| Platform JIT registration | Windows unwind service or Intel VTune | `hl_module` JIT image | Native unwinding and profiler symbol lookup | Notify or unregister before releasing executable code or debug metadata |
| Object/prototype runtime metadata | Haxeon metadata arena for derived layout; HashLink module arena for native prototype state | `HlMetadataGeneration` plus `hl_module` | Reflection and dynamic dispatch | Module teardown after managed borrowers are gone |
| Field-name and GUID caches | Process runtime | HashLink process | Reflection by copied name or GUID data | Global HashLink shutdown; entries do not borrow module pointers |
| Native-library mapping | Platform loader | HashLink process | Resolved native function pointers | Process shutdown; module retirement never unloads a shared library |
| TLS and deque roots | HashLink process or owning managed handle | GC root registry | Managed values stored by user code | Clearing/finalizing the container removes roots; module-owned values remain visible in the managed allocation census |
| Explicit Haxe GC handles | HashLink GC handle bridge | `LoadedModule`, `HlRuntimeModule`, or `HlNativeModule` for owned handles; process runtime for unowned handles | Haxeon/native consumers that explicitly retain the handle | Owned handles close during module retirement; unowned handles close explicitly or when finalized |
| Explicit Haxe weak GC roots | HashLink weak-root registry and Haxe weak-handle finalizer | `WeakRoot<T>` handle plus the HashLink collector | Haxeon/native caches that explicitly retain the weak handle | Target slot is cleared after strong marking when unreachable; the weak slot is unregistered on close or handle finalization |
| Patch JIT image | HashLink patch transaction | Haxe `HlRuntimePatchLedger` policy plus `hl_module` patch-code owner and one Haxe-owned external code handle per committed generation | Dispatch slots, escaped closures, active calls, Haxe generation ledger | Haxe tracks superseded generations; handle release remains after module retirement while native owner lists decide executable reclamation |
| Patched function descriptors, register arrays, opcodes, debug pairs, and source spans | Haxe metadata arena | Loaded Haxe generation and its patch ledger | Native JIT, dispatch slots, debugger | Generation teardown after the native module and retained code handles are released |
| Patch stable-ID and relocation resolution plans | Haxe-managed policy state | Haxe patch transaction/generation and patch-input projection | Haxe patch-input construction | Transaction state is discarded on failure; native publication never borrows it |
| Decoded HLP patch input records | Haxe metadata arena | Haxe patch transaction/generation | Native JIT staging and machine-sensitive validation | Arena checkpoint rollback on failure; generation teardown after native publication retires |
| Patched scalar pools (integers, floats, strings, lengths, and UTF-16 views) | Haxe metadata arena on the Haxe-built path; HashLink patch transaction on the legacy path | Loaded Haxe generation or `hl_module` | JIT and patched code | Haxe arena release or runtime-module release |
| Constant descriptors | Haxe metadata arena on the Haxe-built path; HashLink patch transaction on the legacy path | Haxe `HlMetadataGeneration` or `hl_module` | Native constant-initialization kernel and module metadata | Haxe arena release or runtime-module release |
| Materialized constant objects | HashLink module allocator through the native constant-initialization kernel | `hl_module` | Generated code, globals, and GC scanning | Runtime-module release after calls have quiesced |
| Patch source snapshots | Haxe metadata arena on the Haxe-built path; HashLink patch transaction on the legacy path | Loaded Haxe generation or `hl_module` | Debugger and source resolver | Haxe arena release or runtime-module release |
| Globals storage | HashLink module allocator | Loaded module generation | Generated code and rooted heap values | Runtime-module release after plugin deactivation |
| Managed objects, closures, and array storage | HashLink GC with an explicit allocation owner | `hl_module` whose type or callable produced the value | Host roots, globals, other managed values | GC sweep removes ownership records when values become unreachable |
| Plugin state envelope | Host Haxe heap | `RuntimeDomain` transition | Candidate restore call | End of transition; payload is copied serialized text and contains no generation pointers |
| Candidate module | Host loader | `RuntimeDomain` transition | Candidate plugin before publication | Dispose on pre-publication failure, or transfer ownership to the domain at publication |
| Retired module | `RuntimeDomain` | Domain retirement backlog | Permitted in-flight calls only | Disposal after deactivation/publication; failed disposal remains tracked for retry |

Logical declaration identity is the compiler's qualified name and stable function
ID. Layout identity is the ABI descriptor for one module generation. A layout
change creates a replacement domain generation; old heap objects must never be
interpreted with the replacement generation's type pointer.

References may cross a compatible function patch because the loaded module and
its type arena remain alive. Plugin objects, callbacks, and native handles may
not escape a structural domain reload. State crosses that boundary only through
`RuntimeStateEnvelope`, which copies serialized text into host-owned storage.
The host must unregister callbacks and deactivate the old plugin before module
retirement. In-flight calls are synchronized with patch publication by the
runtime-module mutex; domain shutdown requires host-level call quiescence.

Replaced patch JIT images are conservatively pinned until module shutdown because
HashLink closures contain direct code pointers and the GC does not yet report
closure borrowers to patch ownership. This is safe but can retain memory during
long-running repeated closure patches. The non-moving arena and transaction
steps must add measurable borrower-aware reclamation before claiming bounded
closure-patch memory.

The type arena is one contiguous, non-moving allocation with 65,536 append slots
reserved when a module is loaded. Compatible patches may append primitive,
abstract, function, reference, and nullable descriptors. Haxeon constructs
those records and their recursive payloads in a checkpointed metadata
transaction before asking HashLink to publish the patch. Object,
struct/interface-like virtual, enum, method, and packed descriptors still
require a structural reload; both the HLP policy and native validation reject
them. Function descriptor payloads and abstract names are module-owned until
shutdown. A native publication failure rolls the Haxe arena and pointer table
back to their prior cursors, leaving the published type count, revision,
dispatch slots, and existing behavior unchanged. The count and capacity are
exposed as runtime metrics so long-running tests can distinguish arena growth
from JIT retention.

The contiguous reserve is deliberate: generated code, heap values, function
signatures, globals, and reflection retain direct `hl_type *` pointers, while
several HashLink consumers derive type indices with pointer subtraction. Growing
the backing allocation or switching to chunks would invalidate those contracts.
Exhaustion therefore requests a new module generation through the normal reload
path. Arena entries and their auxiliary allocations are reclaimed at module
shutdown; borrower-aware reclamation within a live generation remains
unverified and is intentionally not attempted.

The Haxeon-native loader now exercises the external metadata boundary: it decodes
HLB and HLI, builds the complete `hl_code` graph in `HlMetadataGeneration`, and
passes that graph plus the decoded manifest to
`hl_runtime_module_load_haxe_metadata`. HashLink initializes its JIT and runtime
wrapper from those Haxe-owned records without reparsing HLB or HLI on this path.
The normal Haxeon loader passes no raw HLB payload; debugger-compatible payloads
are an explicit opt-in at the kernel boundary. Both
the external loader and the legacy host facade use the same native opaque
`hl.Abstract<"realtime_module">` ABI type; the host source exposes a local
`RuntimeModuleHandle` alias while standalone stdlib builds use the native type
directly. Only C-layout records remain `RawPtr<T>` values. Haxeon owns HLI
identity validation, initializer policy, stable-ID call-shape validation,
function-version state, dispatch-slot resolution, and the external wrapper's
revision state. Its HLP
operation preflights the section envelope, fixed module-ID, revision header,
and replacement function identities before handing the bytes to HashLink; the
native patch kernel still performs complete wire, operand, relocation, symbol,
and live-compatibility validation. On the Haxe-built path, Haxeon also builds
the patched `hl_function` descriptors, register arrays, opcodes, debug pairs,
source spans, source snapshots, and cumulative scalar pools in the existing
generation arena; native JIT publication borrows those records and pool
pointers without taking ownership of their storage. The public host `Runtime.load` facade remains
on the legacy native-decoder path when compiled by the pinned host Haxe
toolchain. Haxeon-generated runtime code now takes the same decoded-manifest
path: it builds and publishes `HlMetadataGeneration`, passes the native code
record and stable ID/slot tables through `HlRuntimeModuleKernel`, resolves
stable identities to slots in Haxe before active calls, and retains the metadata
generation in a parallel ownership ledger until native module teardown
completes. This keeps the host compatibility fallback while making Haxeon-owned
metadata and dispatch policy the active path for generated runtime code.

The decoded Haxe manifest's stable-ID and dispatch-slot arrays are borrowed by
the native runtime wrapper; `LoadedModule` retains the dispatch table for the
entire native module lifetime. The legacy encoded HLI path still copies those
entries into native storage, so its ownership and teardown behavior remain
independent of Haxe-managed arrays.

The metadata-only `HlNativeModule` wrapper follows the same boundary through
`HlMetadataModuleKernel`. Its Haxe-facing owner handles leases, constants,
patch policy, and teardown state; `NativeHlMetadataModuleKernel` is the only
current adapter that forwards module allocation, JIT initialization, native
calls, publication, and retirement to `HlTypeBridge`. This keeps the direct
HashLink primitives injectable and prevents metadata policy from spreading
back into native declarations.

Each Haxe-built external patch generation privately owns one opaque native
patch-code handle. The non-owning diagnostic snapshots do not copy that handle;
the live generation releases it only after the native runtime wrapper has
retired, keeping detached JIT allocations and their decoded function metadata
alive until Haxe-owned generation state is finished.

Haxe-built modules initialize HashLink with `HL_MODULE_HAXE_METADATA`. That
boundary flag tells the native kernel to retain Haxeon's enum and virtual
layout, lookup, index, and mark-bit tables instead of rebuilding them in
`hl_module_init_indexes`. Haxe publication also binds object prototypes and
function-valued fields to their Haxe-owned function descriptors before the
native call. Native initialization only rebases module context/global storage
and performs the remaining JIT work. After the JIT entrypoint table is
finalized, the Haxe module wrapper iterates the published type table and asks
the native kernel to publish each object or struct prototype from the
Haxe-owned records. The native operation is deliberately per type; it does
not own a second module-wide metadata walk. Legacy modules retain their
existing implicit initialization path. Haxe metadata publication therefore
never asks HashLink to construct a prototype against an uninitialized or
Haxe-only function-pointer table.

Executable object-prototype publication is an explicit second kernel operation:
Haxe-owned module initialization first installs the JIT and dispatch tables,
then iterates and publishes the executable prototype tables one type at a time.
Both Haxe-owned module kernels expose this per-type operation, while the
low-level native operation remains responsible for the executable
representation and its runtime-sensitive setup.

Constant initialization follows the same policy/mechanism split. Haxe validates
and iterates the arena-owned `hl_constant` descriptors after the module's JIT
and global tables are ready, invoking the native kernel once per descriptor.
The kernel retains the bootstrap-sensitive work: allocating the materialized
object through the module allocator, resolving UTF-16 strings and type entries,
copying scalar fields, and completing the GC-visible global representation.
Legacy modules still use HashLink's eager C loop. The Haxe path therefore moves
constant construction policy without pretending that GC allocation or
write-barrier-sensitive materialization has moved into Haxeon.

Haxe-built patch publication follows the same single-model rule. `HlPatchReader`
decodes each HLP once, and the generation arena owns the `hl_patch_input`
projection consumed by the native kernel. Haxe resolves stable IDs to dispatch
slots while constructing that projection, so its instruction operands are
already ready for native validation and JIT staging. Its instruction, relocation,
debug, and source-snapshot fields remain valid through the locked publication call.
The native byte parser remains available for the legacy host-facing patch API,
but the Haxe-owned runtime path no longer reparses its HLP input.

For Haxe-built object and enum descriptors, `globalValue` follows HashLink's
two-stage representation: `HlMetadataGeneration.globalIndex()` stores the
1-based module-global index while the record is being handed to HashLink, and
`hl_module_init_indexes` rebases it to the native module's global storage during
initialization. `globalPointer()` remains the Haxe-owned value-slot accessor; the
two APIs must not be conflated.

`HlRuntimeModuleRegistry` owns publication and retirement for the Haxe-built
external path. Loading a candidate publishes it as the current module and moves
the previous module into a retryable Haxe-owned retirement queue. A
`HlRuntimeModuleLease` is an explicit Haxe-side borrower: retirement reports the
module as pending while a lease is held, and `disposeRetired()` can reclaim it
after the lease is released. Native HashLink still performs the final quiescence
check and executable/metadata release, so this registry does not infer that a
module is safe to unmap merely because Haxe policy no longer publishes it.
The public Haxeon runtime facade uses this Haxe queue exclusively; HashLink's
separate failed-retirement queue remains reachable only from the legacy native
byte-decoder facade.

The loaded-module lifecycle and registry transitions are serialized by Haxe
mutexes. Removing a module from publication first closes its borrow gate, so a
new lease cannot appear between retirement and disposal; existing leases remain
valid until they are released. Calls and patch publication are serialized with
the same module lifecycle lock, while a failed native retirement remains in the
registry for a later retry.

If Haxe-owned initialization fails before `HlRuntimeModuleRegistry` can publish
the candidate, `HlNativeModuleLoader` retains the native wrapper and metadata
arena when HashLink reports retirement blocked. The loader exposes this
process-local queue through `failedRetirementCount()` and
`retryFailedRetirements()`; metadata is released only after the wrapper is
reclaimed.

HashLink records module ownership when a managed allocation is created. A major
collection removes records for dead allocations, and the runtime exposes the
remaining per-module count for diagnostics and reclamation tests. Closure and
array allocations pass their logical module owner explicitly because their GC
header type can be synthetic or shared. A zero count covers managed allocations
only; it is not permission to unmap a module because native caches, JIT entry
points, and other non-GC borrowers still need separate ownership tracking.

GC roots now carry an optional explicit owner as well. Module global roots use
the loaded `hl_module` as that owner, and the runtime reports them separately
from managed allocations. Process-global runtime roots remain unowned. Removing
a root removes its ownership record in the same GC-locked operation, so the
count describes the current root set rather than historical registrations.
Replacing the value in an existing `GcHandle` uses the collector-locked root
update barrier; callers do not write the registered slot directly and cannot
publish a new managed target concurrently with a collection.

`WeakRoot<T>` uses a separate collector registration and never marks its target
as reachable. HashLink clears the target slot after strong marking when the
target is not marked, before finalizers and sweeping run; a reachable target is
left available for the current collection. Reading, replacing, and removing a
weak slot are synchronized with the collector, and the Haxe handle finalizer
unregisters forgotten weak slots. Weak roots are therefore suitable for
non-owning caches and metadata side tables, but cannot replace a `GcHandle<T>`
when runtime state must keep a value alive.

`Runtime.retirementStatus()` takes these counters under the runtime-module call
mutex. It reports module-owned roots separately from borrowers because teardown
can remove the former itself. Managed allocations and pinned registry readers are
known borrowers. The flags repeat the nonzero categories so callers do not need
to recreate native classification rules from counts. This is a diagnostic and a
building block for staged retirement; it does not by itself authorize executable
unmapping.

The cache and external-handle audit found no additional module pointer owner in
HashLink's object/prototype metadata, field-name cache, GUID map, native-library
table, TLS storage, or deque storage. Object/prototype metadata is reached only
through the module type arena. Field names and GUID entries copy process-owned
data. Native libraries intentionally remain process-loaded. TLS and deque roots
may retain managed module values, which the explicit GC allocation-owner ledger
counts without inferring ownership from `hl_type *`.

All host-mediated execution of module code, including calls through retained
closures, holds the runtime-module mutex. Acquiring that mutex for retirement is
therefore the active-call quiescence proof. The host keeps each retained value
paired with its originating `LoadedModule`; the native call bridge receives that
module explicitly and does not infer ownership from the closure's header type,
which may be synthetic.

`Runtime.retirementStatus()` reports the Haxe-side retained-value borrower count
alongside HashLink's managed-allocation and registry-reader counts. This makes
the known Haxe ownership visible to shutdown diagnostics; it does not authorize
patch-code unmapping while HashLink may still hold an untracked closure pointer.

When the last retained value releases a module whose native teardown was deferred,
the loaded-module owner completes Haxe generation and metadata disposal and removes
the module from the retirement backlog in the same lifecycle transition; the retry
queue remains for native borrowers that are still untracked or otherwise blocked.

When a module exception crosses the native call boundary, the bridge discards
the generation-owned exception object and captured JIT return addresses before
raising the host-facing `RuntimeError`. Caught module failures therefore do not
leave hidden borrowers in the current thread's exception state.
