# Live patching

Haxeon treats hot replacement as a transaction, not a best-effort reload:

- Every live module has a 128-bit identity.
- Functions receive persistent stable IDs independent of bytecode ordering.
- Patches carry an expected base revision and replacement revisions.
- Symbol tables are verified by prefix length and content hash.
- Patch call sites use stable-target relocations rather than stale bytecode
  function-table indices.
- All replacements are validated and JIT-compiled before publication.
- Multi-function patches become visible atomically.
- Failed staging is discarded without changing the live program.
- Stale, replayed, cross-module, and incompatible patches are rejected.

Calls and commits are synchronized. Permanent per-slot dispatch entries keep
existing closures and object prototypes valid, while superseded JIT code is
reclaimed after protected calls complete. Retained objects and closures pin
their owning module until released, and module disposal is idempotent.

## What a patch can add

Initialized HashLink modules store direct `hl_type*` pointers, so the runtime
reserves room up front and never moves what it has: function slots
(`HL_PATCH_FUNCTION_RESERVE`), globals (`HL_PATCH_GLOBAL_RESERVE`) and the type
table (`HL_PATCH_TYPE_RESERVE`, a non-moving arena). A patch appends to them:

- **Functions**, after the module's last slot. A removed function keeps its
  slot and last body; the new code does not call it.
- **Types** (HLP 10): function, abstract, reference, null and packed types, and
  object, struct and virtual types with their layout. So an edit that adds a
  class (plain, a subclass of a loaded class, or an implementation of a loaded
  interface) or a closure environment patches. The runtime builds the entries in
  place (`stage_patch_object_type`), links them to the module and their value
  slot once the patch's globals are staged (`link_patch_object_types`), and
  publishes them with the patch. Types the module already has never change.
- **Globals**: String constants, and the null value slot each new object type
  has. Patches cannot write the globals they add.

Still a reload: new runtime natives (they sit before every function slot),
changed C dispatch natives, moved slots, other new globals (an added static
variable), changed layouts of existing objects (instances of the old layout are
alive), enum and interface changes, removed classes and changed function
signatures.

### Lambda names

A lambda is named `<member>#<anchor>#<ordinal>` (`Parser.openLambda`,
`LambdaName`). The anchor is where it is written: the variable, field or local
function it is assigned to, the calls it is an argument of, `return`; for
example `build#hover=/resourceState(1)#0`. The ordinal counts the lambdas before
it at the same anchor only, so adding or removing a lambda renames nothing at
other anchors. A lambda with no anchor is `<member>#<ordinal>`; an anchor longer
than 48 characters keeps its last step and a hash. The planner still checks each
group of same-anchor siblings for renumbering (`PatchPlanner.renumberedGroups`):
inserting a lambda before a sibling at the same anchor (two `items.push(...)`
callbacks, say) reloads.

A lambda that captures is named after its captures too (a hash before the
ordinal). An edit that keeps the captures is the same function with a new
body, which closures made before the edit pick up. An edit that changes them
makes a new function with a new environment type; closures made before the edit
keep the code and environment they were made with.

### Strict mode

`haxeon run --watch --live --strict-live` refuses an edit that cannot patch
instead of reloading. The host records the refusal in `<module>.live.refused`
(`<identity>:<running revision>:<refused revision>`), and before the next build
the compiler takes the refused publications back (it keeps the last three,
`CompilerPublication.RETRACTABLE`), so that build patches the revision the app
runs, with the refused edits in it. Patches name the revision they apply to
(`baseRevision`). A build that needs a fresh layout keeps numbering the
module's revisions, and the host treats a same-identity revision that goes
backwards like a new session.

## Artifact builds and live sessions

Live patching needs the compiler to keep its function slots, symbol-table indices, and stable function IDs
append-only across builds, so a patch can address the running module. That history has a cost for anything else:
a removed function keeps its slot, a replaced string constant stays in the table, and the bytes a build produces
depend on what the compiler session compiled before it.

So the history is opt-in. Without `--live`, every compile assembles from a fresh assembler and the module is a
function of the source alone: a warm session that compiled other revisions first produces the same bytes as a
cold one, with no dead functions or constants. Frontend caches (parsing, typing, IR) stay incremental either
way, and HL assembly is about a tenth of a compile, so nothing meaningful is lost.

- `haxeon run --watch --live` builds with `--live` for you.
- **A watch session keeps its compiler.** The worker whose session holds the patch history is chosen once, at
  the first build (`haxeon: compiler worker version <hash> (kept for this watch session)`), and every rebuild
  uses it. Edits to Haxeon's own compiler sources do not reach a running session, and nothing warns about
  it: **restart the session after changing the compiler.** A new worker could not patch the running module
  anyway, since it has none of the session's history.
- The compiler CLI accepts `--live` for `--target=hl`; the `Compiler` API keeps history by default
  (`Compiler.livePatching`), and `CompilerDriver` sets it from the request.
- The `<output>.hli` and `<output>.live.json` sidecars describe the session (module identity, revision), not
  the artifact, and still differ between sessions.
- `<output>.live.stamp` holds the publication key (`identity:revision`) and is published after `.live.json`. The live
  host reads it every tick and parses the description only when it changes; without a stamp it parses every tick.
