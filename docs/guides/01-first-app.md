# Your first app

In this guide you create an app, run it, change it, and build an executable you can give to someone
else, on Linux, macOS or Windows. [Other platforms](#other-platforms) says where Android and the web stand.

## Before you start

[Get started](00-get-started.md) installs the C and C++ toolchain an app needs and Haxeon from a release archive. When
`haxeon doctor` reports nothing missing, you are ready:

```sh
haxeon doctor
```

## Create an app

```sh
haxeon create my_app
cd my_app
```

`haxeon create` makes a new directory from the app template: a window with a counter. It prints what it created and
what to run next. It makes the app for Linux, macOS and Windows; `--platforms` narrows that.

## What is in the project

```text
my_app/
  haxeon.toml      the project's manifest
  src/Main.hx      the app's code
  linux/           the Linux runner: the project that builds the app's executable
  macos/           the macOS runner, which builds the app as my_app.app
  windows/         the Windows runner, which builds my_app.exe
```

`haxeon.toml` says what the project is and what it uses:

```toml
version = 1
entry = "Main"
sourceRoots = ["src"]
nullSafety = "strict"

[package]
name = "my_app"

[app]
name = "My App"
id = "com.example.my_app"
version = "1.0.0"
platforms = ["linux", "macos", "windows"]

[dependencies]
ui = "^0.3"

[compatibility]
haxeon = "^0.3"
```

- `entry` is the class whose `main` starts the program, and `sourceRoots` the directories that hold the code.
- `nullSafety = "strict"` makes the compiler reject code that could use a `null` where a value is required.
- The `[app]` section makes the project an app rather than a command-line program: its display name, its identifier
  (`--org` on `haxeon create` sets the part before the name), its version and the platforms it is built for.
- `ui = "^0.3"` is the UI package. It comes with the release, so nothing is downloaded.

[The manifest reference](../reference/MANIFEST.md) describes every field.

`linux/`, `macos/` and `windows/` are the app's **runners**: each a small CMake project that builds the executable on its
platform. They are yours to change, for example to rename the executable or package it. `haxeon build` compiles your
code, writes a file the runner includes (under `build/generated/linux/` on Linux), then builds the runner of the
platform you are on with CMake. You do not need to touch the runners to write the app.

## Run it

```sh
haxeon run
```

The first build takes a few minutes: it compiles the UI package's C and C++ code into your app. Later builds compile
only what changed. A window opens with a button and a count of clicks. Close the window to stop the app.

## Change the UI

Open `src/Main.hx`. The `App` class draws the window: its `view` function returns what the window shows, built from
widgets such as `Column`, `Text` and `Button`. Give the window a title and a second button that sets the count back to
zero:

```haxe
function view():View {
	var style = new LayoutStyle();
	style.padding = new Insets(24, 24, 24, 24);
	style.childGap = 12;
	return new Column("root", [
		new KeyedView("title", new Text("My first app")),
		new KeyedView("count", new Text('You clicked ${Main.count.value} times')),
		new KeyedView("button", new Button("Click me", null, () -> Main.count.value = Main.count.value + 1)),
		new KeyedView("reset", new Button("Reset", null, () -> Main.count.value = 0))
	], style);
}
```

Each `KeyedView` gives a widget a key that stays the same from one frame to the next, so the UI knows which widget is
which when it draws the window again. The count is a `Signal` in the `Main` class: setting its `value` draws the window
again with the new count.

Run the app again with `haxeon run` to see the change. To see changes without restarting the app, and without losing
the count, run it with `haxeon run --watch` instead: [Live editing](02-live-editing.md) shows how.

## Build it for shipping

`haxeon run` builds a development version: your code is compiled to bytecode that the Haxeon runtime runs, so it can be
changed while it runs. To build the version you give to people, compile it ahead of time:

```sh
haxeon build --build-mode=release
haxeon run --build-mode=release
```

A release build compiles your code to C and builds it with your C compiler into one executable, in `build/linux/app/`
on Linux with the libraries it uses beside it: ship that directory. On macOS the app is the bundle
`build/macos/app/my_app.app`, and on Windows `build/windows/app/` holds `my_app.exe` and its DLLs. A release build cannot
be edited while it runs; for that, go back to `haxeon run`. [Shipping](05-shipping.md) says what to give people on each
platform.

## Other platforms

- **Linux, macOS and Windows** build and run apps, each through its runner, as above. Console programs
  (`haxeon create my_tool --template console`) build and run there too.
- **Android**: Haxeon builds Android apps (arm64-v8a and x86_64) and edits them live, but today only from a checkout of
  the Haxeon repository, not from a release, and not yet through a runner in your project. See
  [Android](../reference/ANDROID.md).
- **The web**: Haxeon compiles to WebAssembly (`wasm32` and `wasm-gc`), but this is experimental: builds only, and no
  runner for apps yet. See [WebAssembly](../reference/WASM_BACKEND.md).
- **iOS** is planned.

This guide will show each platform as its runner arrives.

## Next

- [Live editing](02-live-editing.md): change the app while it runs.
- [The CLI reference](../reference/CLI.md): every `haxeon` command.
