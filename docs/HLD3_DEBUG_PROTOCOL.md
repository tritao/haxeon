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
- the number of patch JIT regions as an `Int32`;
- for each region: its base pointer, byte size, one-byte retired flag, and
  function count;
- for each region function: its HLB function index followed by the existing
  13-byte HLD function header, opcode-offset table, and variable-location data.

The initial region remains represented by the ordinary HLD2 module fields.
Active patch regions replace mappings for their listed function indices.
Retired regions remain addressable for stacks that were executing superseded
code when a patch was published.

After consuming the handshake, an HLD3 client keeps the socket open. Sending
the byte `R` requests a fresh mapping snapshot. The runtime replies with
`MAP3`, the module count, and for each module its address followed by the same
revision and patch-region payload described above. Any other command closes
the connection. Clients should refresh after observing a revision change and
reinstall source breakpoints at the active function mappings.

Refresh requests must be made while the debugger has stopped the target. This
matches HLD's existing process-memory inspection model and prevents a patch
publication from racing a mapping snapshot.
