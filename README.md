# realtime-haxe

An experimental Haxe-compatible realtime compiler targeting HashLink only.

The proof of concept compiles a small Haxe-compatible source file through a
lexer, parser, AST, typed IR, and HashLink backend. The generated entry point
passes the source `main()` result to HashLink's `std@sys_exit` native, making
the result observable to the integration test.

The example is expressed as typed, register-independent IR. `HlLower` assigns
function/type/register indices, interns constants and native names, and lowers
the IR to the serialized HashLink model.

IR values are immutable SSA definitions. Assignments create new values;
condition joins and mutable loop headers receive explicit, predecessor-complete
phi nodes. The HL backend eliminates phis on their incoming edges with parallel
copy snapshots, emits actual HashLink `OLabel` block markers, and leaves no SSA
constructs in HLB/HLP. This supports nested mutable loops and values assigned on
only one conditional branch without making HashLink aware of compiler SSA.

The frontend is split into parsing, declaration/type checking, and IR
generation. The current subset supports `Int`, `Bool`, `Float`, `String`, local
variables, functions, calls, numeric addition/subtraction, integer comparisons,
nested `if`/`else`, and recursive functions. String literals support the common
quote, slash, newline, carriage-return, and tab escapes. Source edits that add
new float or string constants flow through ordinary incremental compilation
into transactional HLP symbol deltas.

The expression subset also includes multiplication, signed division, call or
value expression statements, and `while` control-flow. Hosts can register typed
HashLink natives through `Compiler.registerNative()` before the first build;
source calls remain ordinary Haxe-compatible calls while the backend emits the
configured library/symbol binding. Registrations freeze after compilation so a
native-table layout cannot silently change beneath a live module.

Compiler-owned `new Array<Int>(length)`, `new Array<Float>(length)`, and
`new Array<String>(length)` expressions emit the realtime runtime ABI without
requiring source-level native registration. Indexed operations and `.length`
remain ordinary typed expressions and use HashLink's bounds-checked array
operations.

IR values and control-flow blocks have numeric identities independent of
source names. Functions contain explicit basic blocks terminated by `Return`,
`Jump`, or `Branch`, and an IR verifier checks the graph and types before HL
lowering.

`compiler.modules.Compiler` retains source, tokens, syntax trees, typed trees,
dependencies, diagnostics, and generated IR per module. Qualified calls such
as `Math.add(20, 22)` create dependency edges; updating a module invalidates
its typed dependents while unrelated parsed and typed state is reused.

Function signatures and bodies have separate fingerprints. Body edits replace
only that function's typed and IR artifacts; signature edits propagate through
the function call graph. Cached IR objects for unaffected functions are reused
when the executable module is assembled.

The session-scoped HL assembler assigns append-only indices to functions,
types, strings, and constants. Independently, it assigns persistent stable
function IDs that survive insertion, removal, bytecode reordering, and explicit
assembler compaction. Compilation reports changed stable function IDs
and whether a structural edit requires reload. Removed functions retain a
tombstone slot until `Compiler.compact()` performs a deterministic full rebuild.

User-function slots and stable IDs live in a compiler registry that contains no
natives. During HL assembly, the backend independently lays out the frozen native
registry followed by cached bytecode-function slots and produces the transient
`findex` map. Consequently, changing host-native configuration between separate
build domains can change HLB layout without changing persistent source-function
identity.

The runtime proof of concept loads compiler-produced HLB bytes in-process and
calls functions through compiler-owned stable slots. A compatible edit arrives
as HLP, is validated and JIT compiled privately, and then commits all selected
slots atomically. Failed compilation, malformed bytecode, and structural edits
leave the live code untouched. `vendor/hashlink` tracks
our HashLink fork, which exports the module lifecycle needed by the runtime
bridge and provides an opt-in `HL_MODULE_PATCHABLE` JIT mode. Calls in that mode
dispatch through the module function table, so already-JITed callers immediately
observe a committed replacement. Names and debug metadata are deliberately not
used as function identity.

The lifecycle is exposed as an opaque `hl_runtime_module` owned by HashLink.
Loading, calls, patch decoding/application, synchronization, revision state,
allocation statistics, and destruction stay behind that API; the project HDLL
is only an FFI adapter and does not inspect `hl_module` or `hl_patch`. Runtime
operations return stable status codes, surfaced in Haxe as `RuntimeStatus` and
`RuntimeError`, so malformed, stale, and incompatible patches remain distinct
without coupling callers to native error strings.

Initial module loading includes an `HLI` identity manifest alongside the
standard, unmodified HLB bytes. The manifest binds a 128-bit module ID and
stable function IDs to that generation's HashLink slots. HLP version 4 carries
the module ID and identifies replacement bodies by stable ID; HashLink resolves
the current slot internally and rejects patches from another module before
revision checking or JIT staging. Keeping identity outside HLB preserves normal
`.hl` compatibility with HashLink.

Compiler identity state can be serialized with `Compiler.exportIdentityState()`
and supplied to a new compiler instance, preserving the module ID and stable-ID
registry across editor or compiler restarts. Patch call sites also carry
stable-target relocations, so HashLink resolves user-function calls against the
loaded generation instead of trusting an old HLB function index.

Calls and commits are synchronized. Each stable slot records its owning JIT
allocation; replacing its last referenced slot reclaims that allocation after
protected calls finish. Failed staging is discarded before publication, keeping
repeated editor reloads bounded. Runtime modules also support explicit disposal.
Patch sets carry expected-base and replacement revisions; stale or replayed
updates are rejected before loading or changing live dispatch state.

Compatible incremental builds also emit versioned `HLP` bytes. The patch format
contains the stable symbol/type requirements and only the changed function
definitions, with a strict Haxe decoder serving as the protocol oracle for the
native HashLink decoder. The fork exposes owned `hl_patch_read`/`hl_patch_free`
APIs with strict bounds, version, opcode, function-length, and trailing-data
validation; integration tests feed identical bytes through both decoders.
`hl_module_apply_patch` resolves those records against the live module and JITs
only their functions. Tests instrument the JIT to prove one changed function
causes one compilation and two-function patches publish as a single transaction.
HLP version 4 is a length-delimited section container; unknown sections can be
skipped while required symbol and function sections are validated strictly.
It represents symbol tables as an expected live prefix count and FNV-1a content
hash followed by append-only records, preventing equal-length but different
symbol tables from accepting the same patch. Integer, float, and UTF-8 string
additions are deep-copied, staged, JIT-compiled, and published with the code
transaction. Appended strings own their UTF-16 cache independently so failed
staging rolls back cleanly and committed code retains valid constants. Repeated
mixed-symbol patches retain bounded JIT allocations. Type-table growth still
fails closed: HashLink stores direct `hl_type*` pointers throughout initialized
modules, so moving the type array would invalidate live code. New function or
structural types therefore remain a domain-reload boundary until the fork has a
non-moving type arena.

## Run the proof of concept

```sh
./scripts/bootstrap-tools.sh
./scripts/format.sh
./scripts/format.sh --check
./scripts/bootstrap-status.sh
./scripts/test-poc.sh
./test-hot-reload.sh
```

Bootstrap/reference Haxe is downloaded below `.tools/`, while the runtime is
built from the pinned `vendor/hashlink` submodule. Normal development will
eventually use the checked-in bootstrap compiler instead of official Haxe.

The writer currently targets bytecode format version 6, matching the current
HashLink decoder in `src/code.c`.

Haxe sources are formatted with the repository-pinned Haxe Formatter. Run
`./scripts/format.sh` to apply formatting; `./scripts/format.sh --check` is part
of the proof-of-concept test suite.

`./scripts/bootstrap-status.sh` runs the real lexer, parser, and typer over the
compiler source tree and reports bootstrap progress. Add `--json` for a
machine-readable dashboard.

The staged architecture, reload rules, and Pragtical conversion gates are
tracked in [ROADMAP.md](ROADMAP.md).
