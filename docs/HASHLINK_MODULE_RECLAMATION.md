# HashLink whole-module reclamation

## Result

Whole loaded modules cannot currently be reclaimed safely inside the shared
HashLink process. Runtime domains must use process isolation when physical
whole-module reclamation is required. Compatible patch generations continue to
reclaim superseded JIT allocations in-process through stable dispatch entries.

## Source findings

`hl_module_free()` passes `m->code` to `hl_free_executable_memory()` even though
`m->jit_code` owns the executable mapping. On Linux the former is normally not a
page-aligned mapping, so `munmap` fails and the JIT mapping remains resident.
Changing the call to `m->jit_code` makes the mapping disappear but exposes stale
process state and causes a later segmentation fault.

The teardown order also calls `hl_free(&m->ctx.alloc)` before its remaining reads
of `m->code`, including function counts and debug data. A future unload design
must move allocator destruction after every metadata consumer.

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

This demonstrates that managed heap reachability is insufficient as a retirement
proof. At least one relevant borrower lives in unmanaged state that the collector
does not enumerate. Possible owners include native callback metadata, runtime
object/prototype caches, exception or stack-unwind state, and other process-global
JIT bookkeeping.

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

## Required proof for a future in-process design

An in-process implementation is safe only after HashLink provides a unified
module ownership registry covering:

- active frames on every registered thread;
- heap objects, closures, virtuals, and enums;
- globals, exception state, and native roots;
- runtime object/prototype and reflection caches;
- native callback wrappers and external handles;
- JIT debug, unwind, profiler, and stack-capture metadata;
- stable dispatch and patch allocations;
- synchronized access to the global module list.

Every category needs acquire/release accounting or an enumerable quiescence
proof. Physical teardown must then remove the module from lookup registries,
release executable mappings, and free metadata in dependency order. Until that
contract exists, process termination is the reliable reclamation boundary.

## Reproduction gate

Use `./test-hot-reload.sh` after any unload experiment. The unsafe prototype
failed with signal 11 after its first successful physical module reclamation;
the restored implementation passes the suite.
