# Live patching

A successful patch keeps the running app and its state. Functions in a patch become visible together.
If the runtime refuses a patch, the running code stays as it was. A watch session normally reloads
the module when an edit cannot patch. See [Live editing](../guides/02-live-editing.md) for how to start
a session and carry state across a reload.

## What a patch can add

A patch can change a function body and add functions, string constants, classes and interfaces.
A new class can extend a loaded class or implement a loaded interface. An added static variable,
a changed enum or existing interface, a removed class or a change to native bindings can require a reload.

### Changed signatures

Changing the signature of a constructor or static function can patch. An edit that changes an inferred
result or field type has the same effect as changing its annotation. Direct callers are rebuilt,
including callers in files that did not change. Existing objects keep the state their constructors
gave them. Changing a method signature used in object dispatch, such as an override or interface
implementation, requires a reload.

### Stored closures

A stored callback can follow a signature change if its old arguments and result can be adapted to
the new signature. Arguments are matched by name and can be widened to `Null<T>` or `Dynamic`.
Removed arguments are dropped. Added arguments need a supported literal default (`Int`, `Float`,
`Bool`, or `null` for an optional parameter). The result must convert back to the old result type,
or can be dropped if the old result type was `Void`.

Deleting a function or changing its signature incompatibly can patch after the app releases any
stored closures that refer to it. A refusal names the affected function and, where available, what
holds the closure.

An entry class can provide `liveRelease()` to release callbacks before a patch checks for retained
closures and `liveRebuild()` to rebuild afterward. The rebuild hook also runs after a refused patch.
A Haxeon UI app releases its retained render tree and handlers, keeps focus, presses and widget state
by ID, and requests a new frame. Hook exceptions are reported as warnings.

### Lambda names

Inserting or moving callbacks can patch if the compiler can match each stored closure to its lambda.
Ambiguous matches can require a reload with `generated_functions_renumbered`. If an edit changes
what a lambda captures, the patch needs any stored closures for the old lambda to be released.

### Strict mode

`haxeon run --watch --strict-live` reports edits that cannot patch and keeps the current module loaded.
Later edits can patch the running revision if the compiler still has its history. If the compiler
loses that history, restart the app to load the latest build.

If an added field initializer throws after a patch takes effect, strict mode reports
`LIVE PATCH INCOMPLETE` and keeps running the new revision. The default host reloads.

## Object layout changes

Adding, removing or reordering fields can patch, including fields on a base class with live subclass
instances. A field can use a type added by the same patch. Adding a method that neither overrides
nor is overridden, or removing a method that did not override another, can also patch. Reflection
and dynamic calls find added methods after the next reload.

### Existing instances get the declaration initializer

Existing instances run the declaration initializer for an added field, such as
`var saved:Array<String> = []`. Their constructors run only when the instances are first created.
A field without a declaration initializer starts at its zero value (`0`, `false` or `null`).
Base fields initialize before subclass fields. If an initializer throws, that instance's added
field keeps its zero value. Removing and restoring a field with the same type can recover its
previous value. A restored declaration initializer runs again.

### Threads

Other threads pause while the patch applies and existing objects are updated. A call already
running can finish with its old body, and later calls use the new code. A constructor already in
progress can finish with an object whose added field was left uninitialized. An initializer
that runs during a patch must finish without waiting for another thread.

### What still reloads, and why

| Reason | Edit |
| --- | --- |
| `object_field_type_changed` | A field's type changed. |
| `object_field_reserve_exhausted` | The class has no more room to add fields during live editing. |
| `object_method_dispatch_changed` | An edit changes overrides or affects special methods such as `toString`, `__compare`, `__cast` or `__get_field`. |
| `object_layout_changed` | The base class or interfaces changed, or a field or class layout is fixed by inline storage or native code. |
| `closure_layout_changed` | A closure's captured values changed and the running layout cannot be reused. |
| `object_removed` | A class was removed. |

## Artifact builds and live sessions

Ordinary builds assemble the module from the current source. A build in a warm compiler session
produces the same module bytes as a cold build with the same inputs. A live session retains build
history so future patches can apply to the running module.

`haxeon run --watch` uses patchable builds when the entry class has the live host entry points.
Use `haxeon run --watch --restart` to rebuild the artifact and relaunch on each edit. If your own
host applies patches, use `haxeon build --compiler-only --patchable`. A watch session keeps the
compiler it started with. Restart the session to pick up a compiler change. See the
[Run reference](cli/build-run.md#run) for options and watch events.
