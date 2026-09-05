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
| Patch JIT image and decoded function metadata | HashLink patch transaction | `hl_module` patch-code owner | Dispatch slots, escaped closures, active calls | Retain replaced images through module release until borrower tracking exists |
| Constant and string append storage | HashLink patch transaction | `hl_module` | Patched code and appended type metadata | Runtime-module release |
| Globals storage | HashLink module allocator | Loaded module generation | Generated code and rooted heap values | Runtime-module release after plugin deactivation |
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
