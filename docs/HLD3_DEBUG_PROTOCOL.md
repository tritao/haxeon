# HLD3 patch mapping extension

HLD3 is an opt-in extension of HashLink's HLD2 debugger handshake. Set
`HL_DEBUG_PROTOCOL=3` in the debuggee to enable it. Without that environment
variable, the runtime emits the byte-for-byte compatible HLD2 handshake.

The HLD3 handshake keeps every HLD2 field in its existing order. After each
module's ordinary function records it appends:

- the module address, used as its stable mapping identity;
- the byte length and contents of its original HLB image, or zero when the
  launch module is already known to the client;
- the module revision as an `Int32`;
- the module globals pointer and runtime type-table pointer;
- the base JIT pointer, byte size, function count, and function records. MAP3
  records add the stable function ID before the existing HLD2 function data;
- the number of patch JIT regions as an `Int32`;
- for each region: its base pointer, byte size, one-byte retired flag, and
  function count;
- for each region function: its HLB function index, stable function ID, the
  existing 13-byte HLD function header, opcode-offset table, and
  variable-location data;
- after each MAP3 function record, an `Int32` source-span count. Base functions
  use zero because their spans are already present in the embedded HLB. Patched
  functions provide one record per opcode containing debug-file index, start
  line/column, end line/column, UTF-8 source-content FNV-1a hash, start/end offsets, and
  flags as `Int32` values.

Repeating the base JIT table makes a module first observed in a later `MAP3`
snapshot fully self-describing; such a module was not present in the initial
HLD2-compatible prefix.
Active patch regions replace mappings for their listed function indices.
Their source-span records likewise replace the HLB opcode spans for those
functions as one part of applying the complete MAP3 snapshot.
Retired regions remain addressable for stacks that were executing superseded
code when a patch was published.

After consuming the handshake, an HLD3 client keeps the socket open. Sending
the byte `R` requests a fresh mapping snapshot. The runtime replies with
`MAP3`, the module count, and for each module its address followed by the same
revision and patch-region payload described above. Any other command closes
the connection. Clients should refresh after observing a revision change and
reinstall source breakpoints at the active function mappings.

After atomically publishing a patch, the runtime sends `REV3`, the module
identity pointer, and its new revision. The publishing thread then waits while
the adapter sends `R`, consumes the resulting `MAP3`, and safely rewrites its
software breakpoints. The adapter completes the transaction by sending `A`;
only then does the publishing thread return to user code.

Runtime-loaded modules send the same `REV3` notification at revision 1, making
their embedded HLB and base JIT table visible before the load call returns. An
initial `A` releases `--debug-wait`; the runtime confirms it with `ACK3`.

Revision-time software breakpoint writes use `B`, an entry count, and entries
containing an address plus the requested byte. The runtime responds with
`BRK3`, the count, and each replaced byte. This lets the adapter retain the
original bytes without using ptrace while the publisher is parked.

Breakpoint rewrites are performed by the runtime's protocol thread after the
complete `MAP3` frame. This avoids both requesting a snapshot from a
ptrace-stopped server and writing process memory while the target is running.

## Diagnostic tracing

Set `HL_DEBUG_TRACE` to a writable file path to record newline-delimited JSON
from the runtime, debugger core, and DAP adapter. The trace includes revision
publication and acknowledgement, mapping refreshes, breakpoint function/opcode
identity and native addresses, verified code writes, native wait results, trap
recognition, target exit status, and uncaught adapter errors.

Tracing is disabled by default. `test-dap-hot-reload.sh` enables it for its
isolated target and prints the trace automatically when the test fails.
