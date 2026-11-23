# Live editing

With `haxeon run --watch --live`, your app keeps running while you change its code. Each time you save, Haxeon compiles
what changed and applies it to the running app as a **patch**: the next frame runs the new code, and every object and
value the app holds stays as it was. This guide makes a series of edits to the app from [Your first app](01-first-app.md)
and shows what each one does: which edits patch, which reload, and what happens to an edit that is wrong.

## Start a live session

In the app's directory, run:

```sh
haxeon run --watch --live
```

The app builds and its window opens, as with `haxeon run`. Click the button a few times so the count is not zero, and
keep the window where you can see it. Leave the command running: it watches your source files until you close the
window or press Ctrl+C.

## Change the code

Open `src/Main.hx` and change the count's text and what the button does, in `view`:

```haxe
new KeyedView("count", new Text('Count: ${Main.count.value}')),
new KeyedView("button", new Button("Add 2", null, () -> Main.count.value = Main.count.value + 2)),
```

Save the file. Within a few seconds the window shows the new text and the new button, and the count is still the
number you clicked to. The terminal shows, among other lines:

```text
haxeon: source changed; rebuilding Haxe code
haxeon: patched live module to revision 2
```

The app did not restart. The patch replaced the code of `view` and of the button's function, and the count, which lives
in the `Signal` in `Main`, kept its value. Click the button: it now adds 2.

## Add data

A patch can also add fields, functions and classes. Give `App` a field that holds the highest count so far, and a
function that the button calls:

```haxe
/** The highest count so far. */
var best = 0;
```

```haxe
function add(amount:Int):Void {
	Main.count.value = Main.count.value + amount;
	if (Main.count.value > best)
		best = Main.count.value;
}
```

Then show it, and call `add` from the button:

```haxe
new KeyedView("count", new Text('Count: ${Main.count.value}')),
new KeyedView("best", new Text('Best: $best')),
new KeyedView("button", new Button("Add 2", null, () -> add(2))),
```

Save, and the window shows `Best: 0`: the `App` object that was already running got the new field, set to its initial
value. A field added by a patch starts with its initial value (the value after `=` in its declaration) in objects that
already exist, because their constructor does not run again. Click, and `Best` follows the count.

## Edits that reload

Some edits change what is already in memory in a way a patch cannot, and Haxeon **reloads** the app's code instead. Add
a static variable to `Main` for the amount a click adds:

```haxe
/** How much a click adds. */
public static var step = 3;
```

and use it in the button:

```haxe
new KeyedView("button", new Button('Add ${Main.step}', null, () -> add(Main.step))),
```

Save. The window closes and opens again, and the terminal says why:

```text
haxeon: revision 4 cannot patch revision 3 (the build requires a reload: global_layout_changed Main.step); reloading module
haxeon: reloaded live module to revision 4
```

The process keeps running, but the app's code is loaded afresh, and objects made by the old code are gone. Before the
reload, Haxeon calls `saveState` on the old code, then `start` and `restoreState` on the new code. The template's `Main`
saves the count:

```haxe
public static function saveState():String
	return Std.string(count.value);

public static function restoreState(state:String):Void
	count.value = Std.parseInt(state) ?? 0;
```

So after the reload the count is the same, but `Best` is back to 0: it lived in the `App` object, which the reload made
anew, and `saveState` does not save it. Whatever you want to keep across a reload goes in the string `saveState`
returns.

## What patches and what reloads

These edits patch, and the app keeps all of its state:

- Any change to the code inside functions: logic, the UI that `view` builds, event handlers, calls to C and C++
  libraries through their bindings.
- New functions, methods, classes and interfaces.
- Fields added to or removed from a class. Objects that already exist get an added field's initial value.
- A changed parameter list of a static function or a constructor. Haxeon compiles every call to it again.

These edits reload, and the app keeps what `saveState` returns:

- A new static variable.
- A changed enum, a changed interface, or a removed class.
- A field whose type changed, or a change to a class's base class or the interfaces it implements.
- A changed parameter list of a method that is called on an object, and a method added that overrides another or is
  overridden.
- More than a few fields added to one class: each class has room for a few new fields, and a reload makes room again.
- A call to a native function that no code of the app called before.

Changes to anything other than Haxe code, such as `haxeon.toml` or the C and C++ code of a package, rebuild the whole
project and restart the app. A restart starts the app afresh in a new process, and nothing is carried across.

## When an edit is wrong

Make a typo: show the step in a new line under the buttons, but misspell `step`:

```haxe
new KeyedView("hint", new Text('Each click adds ${Main.stpe}'))
```

Save. The build fails, and the terminal shows the error:

```text
src/Main.hx:47:54: error[E1005]: Unknown static field "Main.stpe"
 47 |             new KeyedView("hint", new Text('Each click adds ${Main.stpe}'))
    |                                                               ^^^^^^^^^

1 error
haxeon: build failed; keeping the current app open
```

The app keeps running the code it had, with its state. Fix the typo and save again:

```haxe
new KeyedView("hint", new Text('Each click adds ${Main.step}'))
```

The fixed code patches the app as usual.

An edit that compiles can still be refused when the app is running. Before a patch changes anything, the runtime checks
it against the running app: for example, a patch that deletes a function is refused while the app still holds a
callback to that function. A refused patch leaves the app exactly as it was, and Haxeon reloads the app's code instead,
carrying the state across through `saveState` and `restoreState`. To be told instead, run with `--strict-live`: an
edit that cannot patch is then refused with the reason, and the app keeps running the code it had.

The template's `liveRelease` and `liveRebuild` functions in `Main` help here. Haxeon calls `liveRelease` before a patch
that deletes functions, so the UI lets go of its handlers, and `liveRebuild` after every patch, so the window is built
again from the new code. Keep them when you change `Main`.

## How an app takes part

`haxeon run` calls `main`, which runs until the window closes. `haxeon run --watch --live` does not: it keeps the
process, calls `start` once, then `tick` for each step of the app until it returns 0, and `close` at the end. The
template's `Main` has all of them:

```haxe
public static function start(arguments:String):Void
	session = DesktopUiHost.open(options(), create);

public static function tick():Int
	return session != null && session.tick() ? 1 : 0;

public static function close():Int
	return session == null ? 0 : session.close();
```

Patches are applied between two calls to `tick`, so no code is half-way through when it changes.

Live editing works on development builds only. A release build (`haxeon build --build-mode=release`) is compiled ahead of
time and cannot be watched or patched.

## Next

- [The CLI reference](../reference/CLI.md) lists the options of `haxeon run`, and the events file that `--watch` writes
  for tools: each rebuild, patch, reload and refusal, one JSON object per line.
- [Live patching](../reference/LIVE_PATCHING.md) describes in detail what a patch can change and why.
