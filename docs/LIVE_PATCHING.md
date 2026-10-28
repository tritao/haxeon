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
  interface), a new interface or a closure environment patches. The runtime builds the entries in
  place (`stage_patch_object_type`), links them to the module and their value
  slot once the patch's globals are staged (`link_patch_object_types`), and
  publishes them with the patch. Types the module already has never change.
- **Globals**: String constants, and the null value slot each new object type
  has. Patches cannot write the globals they add.

Still a reload: new runtime natives (they sit before every function slot),
changed C dispatch natives, moved slots, other new globals (an added static
variable), changed layouts of existing objects (instances of the old layout are
alive), enum changes, changes to existing interfaces, removed classes and changed function
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

## Object layout changes

Adding a field to a class is the most common structural edit in UI work, and the objects that have the class are
usually long-lived: the application object, its models, its widgets. A live patch adds the field to those objects in
place, so the edit patches instead of reloading.

### Design: reserved slots

A live build (`--live`) gives every class that can take fields later `BackendAssembly.liveFieldReserve` (4) **reserved
slots**: unnamed `Dynamic` fields after the class's own fields and interface caches. Every instance is allocated with
them, zeroed. A patch that adds a field gives it the class's first free slot: the patch names the slot and gives it the
field's type (HLP section 7), and code addresses it like any field.

Nothing moves, which is what makes this safe:

- An object keeps its address. Native code, `ObjectMap` keys (hashed by address), virtuals' field pointers, closures
  that captured `this`, and values in registers or on the conservatively scanned stack all stay valid. This is why the
  other options were turned down: relocating instances on the GC heap and rewriting references cannot find every
  reference (the stack is scanned conservatively, maps hash addresses, natives hold pointers), and making storage
  indirect or checking a layout version on every field access would slow every program to support an edit.
- Offsets do not move. Slots are reserved per class, not at the end of the object, so a field added to a base class
  takes the base's slot and its subclasses' fields stay where they are.
- The instance size, the GC mark bits and the allocation policy do not change. A reserved slot is a pointer slot, so a
  pointer field added there is traced; a scalar field is fine too, because the precise GC checks every word it marks
  before following it.

The cost is a pointer per slot per instance in live builds; builds without `--live` reserve nothing. Classes get no
slots when a patch could not use them: value objects (other objects hold them inline), objects or fields natives lay
out, closure environments, and classes a native's signature reaches through its arguments, result, fields or bases
(HashLink compares the whole layout with the library's declared signature when it loads the module).

Reflection sees an added field once it has a name: the runtime adds it to the class's field lookup at commit
(`Reflect.field`, `Reflect.setField`, `Reflect.fields`, `Reflect.copy` and dynamic access). Unnamed slots stay hidden,
as interface caches are.

### Existing instances get the declaration initializer

Instances made before the patch run the **declaration initializers** of the fields it adds (`var saved:Array<String> =
[]`), never their constructor. A field without an initializer, or one a constructor assigns, starts at its zero value
(`0`, `false`, `null`). Other hot-reload systems draw the same line: .NET Edit and Continue and Unreal's Live Coding
never rerun a constructor on an object that exists, and .NET gives an existing object's added field its default value.
A constructor cannot be replayed safely: it takes arguments, has side effects and assigns fields that already hold
state. A declaration initializer depends on none of that, so Haxeon runs it, which spares the common
`var items:Array<T> = []` from starting as `null`.

The compiler generates `Class.__liveinit` for each published class with initialized fields the running module lacks
(`IrProgramAssembler.liveInitializersFrom`). The patch names it as the class's **migration** (HLP section 8); after the
commit, and before any other code runs, the runtime collects the live instances of the class and its subclasses with
one full mark (`hl_gc_live_instances`) and calls the function on each (`hl_module_patch_migrate`). Bases migrate before
subclasses. An initializer that throws leaves its instance's field at the zero value and is reported; the patch stays
applied. Instances made after the patch run the initializers in their constructor as usual.

### What patches

The planner (`PatchPlanner.plan`) leaves an object whose kind, base and interfaces are unchanged to the assembler, which
checks its fields and methods against the running layout before lowering (`HlModuleAssembler.planObjects`):

| Edit | Result |
| --- | --- |
| Field added, to any class including a base class with live subclass instances | Patches into a reserved slot; initializer runs on existing instances |
| Field removed | Patches. The slot keeps its name and last value; no code reads it. |
| Fields reordered | Patches; nothing moves |
| Removed field added back with the same type | Patches into the slot it had, with the value it had |
| Method added that overrides nothing and that nothing overrides | Patches; calls reach it directly (`HlLower.addedMethodFunction`) |
| Method removed that overrode nothing | Patches |

Field indices are resolved by name against the published HashLink types (`HlLower.requireObjectFieldByType`), never by
position in the IR, so a patched function finds every field where the running module has it.

### What still reloads, and why

| Reason | Edit |
| --- | --- |
| `object_field_type_changed` | A field's type changed: its slot holds values of the old type. |
| `object_field_reserve_exhausted` | The class's reserved slots are taken. A reload lays the class out afresh with new slots. |
| `object_method_dispatch_changed` | An added method overrides one or is overridden, an override was removed, or the method is one the runtime finds by name in the prototype (`toString`, `__compare`, `__cast`, `__get_field`). Prototype tables would need new or changed entries in every subclass. |
| `object_layout_changed` | The base or the interfaces changed, the object is a value object, an added field is stored inline (a value object) or laid out for natives, or a native's signature reaches the class. |
| `closure_layout_changed` | A closure's captures changed; closures already made hold the old environment. |
| `object_added`, `object_removed` | A class appeared or went: type-table growth (above). |

Added methods have no prototype slot, so reflection and dynamic calls do not find them until the next reload.

### Runtime contract

`vendor/hashlink/src/hlpatch.c` validates the rewrites (each must name a reserved slot of an existing object type, with a
type that fits a pointer), stages them before the JIT compiles the patch (the JIT picks write barriers by field type),
builds each class's next field lookup, publishes the lookups at commit, and puts the slots back if the patch fails. The
patch's type prefix hash covers the definitions the running module has, before the rewrite; the compiler hashes the
published definitions it replaces (`HlPatchWriter.baseTypeDefinitions`).

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
