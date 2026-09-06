# Runtime metadata ownership

This table defines the ownership rules used by the reload runtime. Logical IDs
belong to compiler state; physical pointers always belong to one loaded runtime
module generation.

| Category | Allocator | Owner | Borrowers | Retirement |
| --- | --- | --- | --- | --- |
| Module identity and stable IDs | Compiler HCS/HLI codecs | Compiler state and `hl_runtime_module` copy | Host reconnect logic, stable-ID resolver | Compiler state deletion and runtime-module release |
| Base bytecode metadata | HashLink code reader arena | `hl_module` | JIT code, globals, objects, closures, reflection | Runtime-module release after calls have quiesced |
| Type arena entries | Base code arena; patch type append allocations | `hl_module` | JIT code, heap values, globals, reflection | Runtime-module release; future GC pinning may permit earlier generation retirement |
| Function dispatch slots | `hl_module` | Loaded module generation | Patchable calls and staged closures | Runtime-module release |
| Base JIT image | HashLink executable allocator | `hl_module` | Dispatch slots, closures, active calls | Runtime-module release after calls quiesce |
| JIT ABI wrapper image | HashLink executable allocator | Process runtime | Dynamic-call bridge and wrapper closures | Global HashLink shutdown after all modules and managed values are finished |
| Module-registry snapshot | HashLink module registry | Debugger, profiler, stack capture, symbol resolver, or type dump operation | Module metadata during one inspection | Reader releases its pin; unload waits after removing publication |
| Platform JIT registration | Windows unwind service or Intel VTune | `hl_module` JIT image | Native unwinding and profiler symbol lookup | Notify or unregister before releasing executable code or debug metadata |
| Object/prototype runtime metadata | Module arena | `hl_module` type descriptors | Reflection and dynamic dispatch | Module teardown after managed borrowers are gone |
| Field-name and GUID caches | Process runtime | HashLink process | Reflection by copied name or GUID data | Global HashLink shutdown; entries do not borrow module pointers |
| Native-library mapping | Platform loader | HashLink process | Resolved native function pointers | Process shutdown; module retirement never unloads a shared library |
| TLS and deque roots | HashLink process or owning managed handle | GC root registry | Managed values stored by user code | Clearing/finalizing the container removes roots; module-owned values remain visible in the managed allocation census |
| Patch JIT image and decoded function metadata | HashLink patch transaction | `hl_module` patch-code owner | Dispatch slots, escaped closures, active calls | Retain replaced images through module release until borrower tracking exists |
| Constant and string append storage | HashLink patch transaction | `hl_module` | Patched code and appended type metadata | Runtime-module release |
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
abstract, and function descriptors. Object, struct/interface-like virtual,
enum, reference, nullable, and packed descriptors require a structural reload;
both the HLP writer and reader reject them. Function descriptor payloads and
abstract names are module-owned until shutdown. Patch staging checks the full
append against the remaining capacity before writing any arena entry, and a
capacity failure leaves the published type count, revision, dispatch slots, and
existing behavior unchanged. The count and capacity are exposed as runtime
metrics so long-running tests can distinguish arena growth from JIT retention.

The contiguous reserve is deliberate: generated code, heap values, function
signatures, globals, and reflection retain direct `hl_type *` pointers, while
several HashLink consumers derive type indices with pointer subtraction. Growing
the backing allocation or switching to chunks would invalidate those contracts.
Exhaustion therefore requests a new module generation through the normal reload
path. Arena entries and their auxiliary allocations are reclaimed at module
shutdown; borrower-aware reclamation within a live generation remains
unverified and is intentionally not attempted.

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

When a module exception crosses the native call boundary, the bridge discards
the generation-owned exception object and captured JIT return addresses before
raising the host-facing `RuntimeError`. Caught module failures therefore do not
leave hidden borrowers in the current thread's exception state.
