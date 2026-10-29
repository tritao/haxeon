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
  slot and last body; the new code does not call it, and the patch applies only
  when no stored closure still reaches it (see "Stored closures").
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
variable), layout changes of existing objects that reserved slots cannot take
(see "Object layout changes" below), enum changes, changes to existing interfaces, removed classes and changed
signatures of methods an object dispatches to (see "Changed signatures" below).

### Changed signatures

An edit that changes a function's signature, such as a parameter added to a constructor or a static function, patches.
It is the old function removed and a new one added under the same name: the assembler moves the old function out of
its slot under a retired name (`<name>~retired<revision>`, `RetiredName.movedFunction`,
`HlModuleAssembler.moveChangedSignatures`), and the function takes a new slot with a new stable ID.

- **Direct callers** are compiled again in the same patch, wherever they are: the assembler finds every function whose
  lowered code calls, or makes a closure of, the old slot (`HlModuleAssembler.callersOfMoved`), callers in files the edit
  did not touch included, so no call keeps reaching the old slot.
- **Stored closures** (a `scale` kept in a static) call the old slot, which takes an **adapter** to the new function
  (`HlModuleAssembler.signatureAdapter`): it has the old signature, passes on each argument the function still takes
  (matched by name; widened to `Null<T>` or `Dynamic` where the parameter widened), passes the literal default of each
  parameter the function gained (`IrProgram.parameterDefaults`: an `Int`, `Float` or `Bool` literal, or `null` for an
  optional one), drops each it lost, and converts the result back (or drops it for an old `Void`). The adapters of earlier
  moves of the same function are rebuilt against the newest signature, so a chain of edits is one step: a closure stored
  before two edits runs the latest code.
- When **no adapter can be built** (a required parameter added, a parameter's type narrowed, a result that does not
  convert back), the old slot keeps its old code and the patch names it as a **guard** (see "Stored closures" below):
  it applies only when no stored closure still reaches the slot.

Objects made before the edit keep the state the old constructor gave them; constructors never run again on existing
objects (see "Object layout changes"). A subclass constructor that calls a changed `super(...)` is recompiled with it.

A method an object dispatches to through its prototype keeps its slot: the prototype entry names the slot, and the
running module's types never change. A changed signature of such a method (`Point.sum()` given a parameter, an
override, an interface implementation) still reloads with `function_signature_changed` (`PatchPlanner.plan`).

A fresh module (a reload) drops the retired functions and their stable IDs (`BackendAssembly.freshLayout`), since only
closures of the module it replaces call them.

### Stored closures

A closure the running program stored (a handler in a static array, a callback a widget keeps) outlives the edit that
changes or deletes its function. Keeping the old body behind it would let the app run code the source no longer has, so a
patch never does that silently:

- A function whose signature changed gets an adapter (above).
- A function the build drops, and a changed function no adapter can bridge, is a **guard** of the patch (HLP section 9,
  `HlModuleAssembler.dropGuards`): functions and lambdas the last build had and this one lacks, lambdas a rename retires
  among them. With every other thread stopped and before anything commits, the runtime looks for live closures to each
  guard in one heap scan (`check_patch_guards` in hlpatch.c): GC closures by their code address, and the closures the
  module made at load (`OStaticClosure`, module memory the module lists, `hl_emit_final`) when something holds them: a
  heap block, a global, a native root (`hl_add_root`, as a native UI callback or thread-local storage keeps one) or a
  running thread's stack or registers (`hl_gc_root_holder`), as a GC closure would be kept alive. Patch code makes GC
  closures, never static ones: without a value (`hl_alloc_closure_void`), on pages of raw data, which the scan reads too. The module's list only grows with the code it lists: when the list cannot grow the code is
  not made (a load or a patch fails) rather than left unlisted, and a refused patch's code adds nothing. If any is left the
  patch is refused (`ClosuresHeld`), nothing applied, with a message that names the function, the count and what holds
  them, walked back from the closure through arrays and fields to a static field, for example
  `a deleted lambda at Keys.hx:42; 1 stored closure still references it (held by App.keyHandlers[3])` or
  `Main.scale changed signature incompatibly; 2 stored closures still reference it (held by Holder.scaler, ...)`. The
  patch carries the names of the module's globals for that (HashLink has none). A closure nothing on the heap holds is
  `held by a native root` or `held by a running thread`.
- A strict live host shows the refusal on its banner; the default host reloads.

Apps rebuild some of what holds their callbacks, their UI above all, from their code. Nothing in Haxeon or exosuit did
that after a patch, so a handler only the UI held would have stopped every patch that deleted it. A live host now calls
two optional functions of the app's entry class (`Runtime.patchSetRebuilding`): `liveRelease()` before a patch that carries
guards, to let go of what the app rebuilds, and `liveRebuild()` after every patch, applied or refused, to build it again
(after a patch without guards, it only makes the new code show without waiting for the app's next input). The guard
check then sees only what the app still holds. Nothing ever has to be rolled back: a refused patch changed nothing, and
the app rebuilds from the code it had. (Applying first and scanning after would need a rollback, which is unsound once a
patch has migrated objects or run initializers; see "Existing instances get the declaration initializer".)
A Haxeon UI app's `liveRelease()` calls `UiContext.releaseRetained()`, which drops the render tree with its handlers, the
hit-test picker, hover paths, focus order, in-flight gestures and self-updating builders, keeping focus, presses and widget
state by ID; its `liveRebuild()` requests a frame, whose submit builds the whole tree afresh.

A hook that throws is the app's error, not the patch's. The patch's outcome (applied, refused) is what the runtime did,
and the host prints the hook's exception as `haxeon: warning: Main.liveRebuild() threw: ...`. Once `liveRelease()` ran,
`liveRebuild()` runs too, whether `liveRelease()` or the patch threw, so the app is never left released; a `liveRelease()`
that threw before letting go of everything leaves the guard check to refuse what the app still holds.

### Lambda names

A lambda is named `<member>#<anchor>#<ordinal>` (`Parser.openLambda`,
`LambdaName`). The anchor is where it is written: the variable, field or local
function it is assigned to, the calls it is an argument of, `return`; for
example `build#hover=/resourceState(1)#0`. The ordinal counts the lambdas before
it at the same anchor only, so adding or removing a lambda renames nothing at
other anchors. A lambda with no anchor is `<member>#<ordinal>`; an anchor longer
than 48 characters keeps its last step and a hash.

Inserting a lambda before a sibling at the same anchor (two `items.push(...)`
callbacks, say), deleting one or reordering them still renumbers the siblings
after it: `build#hover=/resourceState(1)#0` becomes `#1`. Such an edit patches.
Before planning, a live HashLink build matches each group of same-anchor
siblings with the running module's by their code (`LambdaAlignment`), and
renames the running module's lambdas to the names their functions have now
(`HlModuleAssembler.renameLambdas`). A renamed lambda keeps its slot, stable ID
and lowered code, and its environment, the cells of its captured variables and
the lambdas written in it move with it, keeping their types. So each closure the
program stored keeps running its own function, or the edited version of it, and
the inserted lambda is an added function in a new slot. The code fingerprint
leaves lambda ordinals out of the names it mentions
(`IrFunctionStateCodec.codeFingerprint`), so a lambda that only moved, with its
environment and nested lambdas, keeps its fingerprint. Because those names lose
their ordinals, a lambda's own code does not tell `() -> () -> 1` from
`() -> () -> 2`; so each lambda's fingerprint is folded with the fingerprints of
the lambdas written in it, in order, all the way down (`PositionalName.nested`).

Matching within a group:

- Siblings with the same fingerprint are matched in order. They and every lambda
  written in them run the same code, so which takes which slot cannot be
  observed.
- An edited sibling is followed through the saved file's text diff
  (`SourceLineMap`): each build records where its lambdas start and the text of
  their files (`IrProgram.positionalPlaces`, in memory only), and the line a
  running lambda started on, carried through the diff (unchanged lines by their
  longest common subsequence, edited ones by likeness), is the line the edited
  lambda starts on; among a group's lambdas on one line they keep their order.
  The fingerprints are the safety check: a pair is taken only when neither's
  code appears elsewhere in the group.
- A new sibling nothing matches is added. A running one nothing matches is
  removed: it keeps its slot and code, and the patch guards it (see "Stored
  closures"); if the new build gives its name to another function, it moves to
  a retired name (`<group>~retired<revision>#<ordinal>`).
- Between two matched siblings, one unmatched running sibling and one unmatched
  new sibling are the same function edited, provided neither's code appears
  elsewhere in the group.

Anything else reloads with `generated_functions_renumbered`, because nothing
tells which function each name stands for: unmatched siblings the diff cannot
follow (a resumed session has no texts), an edited sibling whose new code
copies a neighbour's, and siblings both reordered and edited where the diff
does not tell them apart. Function adapter groups (`$function-adapter:`) are
not renamed; they patch only while every name keeps its function. A Wasm module,
or a compiler resumed without the running layout, cannot take the renames and
reloads too.

A lambda that captures is named after its captures too (a hash before the
ordinal). An edit that keeps the captures is the same function with a new
body, which closures made before the edit pick up. An edit that changes them
makes a new function with a new environment type, and drops the old one: the
patch applies when no stored closure still holds it (see "Stored closures").

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

A new compiler session (the compiler restarted, or its state was deleted)
has none of the running module's history, so none of its builds can patch the
app. A strict host refuses every such build with "the compiler no longer has
the history of the running module" and writes no refusal record (the new
session could not use it); restarting the app loads the latest revision. It
never reloads silently.

A patch whose field initializers threw on existing objects (see "Existing
instances get the declaration initializer") has applied and cannot be taken
back: a strict host shows `LIVE PATCH INCOMPLETE` with the runtime's message
(which class, how many instances, the first exception) and keeps running the
new revision; the default host reloads. A patch the runtime refused because
stored closures still reach what it drops (`ClosuresHeld`) is refused with the
runtime's message.

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
one full mark (`hl_gc_live_instances`) and calls the function on each (`migrate_patch_instances` in hlpatch.c). Bases
migrate before subclasses. An initializer that throws leaves its instance's field at the zero value; the patch stays
applied, and `Runtime.patchSet` throws `RuntimeError(MigrationFailed)` with the runtime's message (strict mode: see
"Strict mode"). Instances made after the patch run the initializers in their constructor as usual.

A field removed and added back with the same type returns to the slot it had (with the value it kept); a field removed
and added back with an initializer runs that initializer again on existing objects, as a new field does (the assembler
remembers removed fields, `HlModuleAssembler.retiredFields`, so the field counts as added).

### Threads

A patch commits with every other thread stopped (`hl_gc_exclusive_begin`/`end` in gc.c, which keep the world stopped
across the collections the migration runs):

- Other threads see a patch's functions all old or all new; a new constructor never meets an old reader of its fields.
- The migration runs before any other thread resumes, so no thread runs new code on an object the migration has not
  reached. The objects one full mark found are pinned (`gc_pinned_lists`, marked by every collection) until the migration
  has reached them: an object another thread drops meanwhile cannot be freed and its memory reused under the migration.
- A thread stopped inside an old function finishes that call with the old code after the commit; its next call runs the
  new code. Code a stopped thread's stack or registers point into is retired, not freed (`hl_gc_threads_reference`), so
  it can return there. So a construction in flight while the patch commits can finish one object without the added field
  (at most one per thread per patch); `tests/runtime/LiveObjectLayoutMain.hx` measures that bound.
- A migration initializer must not wait for another thread: every other thread is stopped until it returns.

`hl_gc_live_instances` and the guard scan use the same stop-the-world collection.

### What patches

The planner (`PatchPlanner.plan`) leaves an object whose kind, base and interfaces are unchanged to the assembler, which
checks its fields and methods against the running layout before lowering (`HlModuleAssembler.planObjects`):

| Edit | Result |
| --- | --- |
| Field added, to any class including a base class with live subclass instances | Patches into a reserved slot; initializer runs on existing instances |
| Field removed | Patches. The slot keeps its name and last value; no code reads it. |
| Fields reordered | Patches; nothing moves |
| Removed field added back with the same type | Patches into the slot it had, with the value it had |
| Field added whose type is a class the same patch adds | Patches; the initializer can construct the new class |
| Field added to a class an earlier patch appended | Patches; appended classes get reserved slots too |
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
| `object_removed` | A class went (a removed closure environment or capture cell patches; see "What a patch can add"). |

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


## Unchanged publication

With publication tracking enabled, a live build whose assembled runtime state is unchanged returns
`CompileResult.unchanged = true`, retains its revision, and leaves no publication pending. The host must not
acknowledge or reject that result; either call reports that no publication is pending. Changed results still
require acknowledgement after publication, or rejection when staging fails. Enabling tracking after an
untracked build still requires an initial publication, even when its source has not changed.

`CompileResult.baseRevision` and the live manifest's `baseRevision` identify the baseline a patch expects.
The live host checks this against its running revision before invoking the patcher; skipped revisions and
legacy manifests without a base revision require a reload. An unchanged CLI build preserves the previous
patch, manifest, and stamp, so a host that has not polled yet can still consume that publication. For changed
builds, the CLI writes the publication stamp after the other artifacts and rolls compiler state back if staging
fails. Switching between artifact and live modes starts a new compiler session.

Each compiler request reads a source into one shared snapshot, including structural-change checks. Consecutive
reads must agree before the snapshot is cached, and a failed request cannot retain that cache for the next one.
Shape-lexer errors name the actual source file.
