# HashLink whole-module reclamation

## Result

Runtime-owned modules now use retryable two-phase reclamation inside the shared
HashLink process. Retirement first prevents host calls, removes runtime discovery
and owned roots, and runs a major collection. The module remains intact while a
managed allocation or registry reader can still borrow it. Once those counts are
zero, teardown releases the actual base JIT mapping and its metadata in dependency
order. Compatible patch generations continue to reclaim superseded JIT
allocations through stable dispatch entries.

## Source findings

`hl_module_free()` previously passed `m->code` to
`hl_free_executable_memory()` even though `m->jit_code` owns the executable
mapping. On Linux the former was normally not page aligned, so `munmap` failed
and the JIT mapping remained resident. Teardown now releases `m->jit_code` only
after staged retirement has cleared tracked borrowers.

Module allocator destruction now runs after every metadata consumer. This fixes
the teardown dependency order independently of whether the executable mapping is
physically released.

## Prototype tested

A prototype performed these steps before physical teardown:

1. removed the module's GC globals from the root set;
2. ran a stop-the-world major collection while the module remained registered;
3. enumerated live GC blocks and rejected retirement when an object type pointer
   referenced the module's stable type arena;
4. conservatively scanned every live GC block for pointers into the module's JIT
   mapping and stable dispatch mapping;
5. kept pinned modules in the global module registry for stack/debug lookup;
6. corrected executable-memory ownership and module allocator teardown order.

The census reported no managed references and reclaimed one module. The process
then reproducibly segfaulted during subsequent compiler work. Expanding the
managed-heap scan from type headers to every pointer-sized field did not change
the result. Restoring the original non-unmapping behavior restored the complete
hot-reload test.

The original crash demonstrated that managed heap reachability alone was
insufficient. The subsequent ownership audit and fixes cover the concrete
process-global and native borrowers described below, while the staged transition
keeps retryable modules intact whenever tracked reachability remains.

The callback audit subsequently identified one concrete borrower. HashLink's
process-global C-to-HL and HL-to-C wrapper pointers were republished from every
base JIT image, and wrapper closure objects copied the HL-to-C address. The
wrappers are architecture support code rather than module code, so they now live
in one process-owned executable image copied from the first finalized JIT support
prefix. Later module loads no longer redirect those globals into their own JIT
images, and global shutdown releases the support image explicitly.

Debugger and profiler inspection use pinned module-registry snapshots. Stack
capture, symbol resolution, type dumps, VTune enumeration, and the debugger
handshake increment a per-module reader pin before inspecting metadata. Unload
first removes the module from publication, then waits for prior snapshots to
release their pins before freeing metadata. Profiler samples may retain raw
numeric JIT addresses, but later symbolization only dereferences metadata found
through a new pinned snapshot; samples for an unloaded module resolve as unknown.

Platform registrations now have symmetric teardown. Windows function tables are
removed before any executable-memory release. VTune method IDs are retained per
module, duplicate publication is avoided, and every published method receives
an unload notification before its JIT metadata is freed. Global shutdown also
stops an active profiler worker before releasing the module registry or the
process-owned JIT wrapper image.

The remaining runtime caches and external containers have also been classified.
Object/prototype metadata belongs to the module arena; field-name and GUID caches
retain copied process-owned data; native libraries remain loaded for the process;
and TLS/deque values remain visible through managed allocation ownership. A
structured retirement snapshot reports live managed allocations, module-owned
roots, registry readers, and typed category flags while host calls are quiesced.
Owned roots are teardown inputs rather than external borrowers, so the API does
not flatten these categories into a `ready` boolean.

## Retirement contract

The in-process runtime contract covers:

- active host-mediated call frames;
- heap objects, closures, virtuals, and enums;
- globals, exception state, and native roots;
- runtime object/prototype and reflection caches;
- native callback wrappers and external handles;
- JIT debug, unwind, profiler, and stack-capture metadata;
- stable dispatch and patch allocations;
- synchronized access to the global module list.

Host-mediated calls are serialized with retirement. Retained Haxe values keep the
native handle borrowed, and the native GC ledger covers module-produced managed
values. A blocked attempt stays in a Haxe-owned retirement backlog and is retried
at later runtime safe points or by `Runtime.retryRetirements()`. This contract
requires plugins to deactivate and unregister callbacks before disposal; native
code that retains an unregistered raw JIT address, or a module that starts an
untracked background thread, remains outside the supported runtime API.

## Reproduction gate

Use `./test-hot-reload.sh` after any unload change. It includes 100 repeated
load/call/retire cycles with physical JIT unmapping, retained-object and closure
retries, patch stress, and exception paths. Run `./scripts/test-poc.sh` for the
full compiler, plugin, and runtime regression suite.
