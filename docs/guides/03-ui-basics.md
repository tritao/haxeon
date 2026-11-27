# UI basics

In this guide you build a small task list with the `ui` package: a list of tasks, a detail pane for the selected task, a
form that adds a task, a second tab with settings, and a switch between a light and a dark theme. Along the way you
meet layout, text, lists, forms, navigation and theming.

The finished project is in [examples/03-ui-basics/tasks](examples/03-ui-basics/tasks/), without its runners (`linux/`,
`macos/`, `windows/`), which `haxeon create .` adds. It builds and runs on Linux, macOS and Windows.

## Start from the app template

Create an app and run it once, so the first build of the UI package's native code is out of the way:

```sh
haxeon create tasks --org org.example
cd tasks
haxeon run
```

`haxeon create` wrote the manifest, the code and a runner for each platform. `haxeon.toml` makes the project an app and
depends on the UI package:

```toml
[app]
name = "Tasks"
id = "org.example.tasks"
version = "1.0.0"
platforms = ["linux", "macos", "windows"]

[dependencies]
ui = "^0.3"
```

`linux/`, `macos/` and `windows/` are the app's runners, which build the executable on each platform. You do not need to
change them in this guide.
`src/Main.hx` holds the window's content and the code that opens the window. In this guide the content moves to its own
file, `src/App.hx`, and `src/Main.hx` keeps only the window:

```haxe
static function options():UiHostOptions {
	var options = new UiHostOptions();
	options.title = "Task List";
	options.width = 720;
	options.height = 480;
	return options;
}

static function create(host:UiHostContext):App {
	var created = new App(host);
	app = created;
	return created;
}

/** `haxeon run`: open the window and run until it closes. */
static function main():Void
	UiHost.run(create, options());
```

The rest of `src/Main.hx` (`start`, `tick`, `close`, `saveState`, `restoreState`) lets `haxeon run --watch`
patch the running app, and stays as the template wrote it, apart from the state it saves. Copy the whole file from the example project.

## How a window gets its content

`UiHost.run` starts the platform host and calls `create` once to make your application object. Each time the window draws
a frame, it calls the object's `submit`, which builds a tree of views and hands it to the `UiContext`:

```haxe
public function submit(frame:LayoutFrame):RenderNode
	return ui.submit(view(), frame);
```

`view()` is yours. It builds the whole window from the app's state, every time. You never change a view after you made
it: you change the state, and the next frame shows it. Keep the state in fields of the application object:

```haxe
// The app's state. `view()` builds the window's content from it each time the window draws a frame.
final tasks = [new Task("Buy milk"), new Task("Write the report"), new Task("Call the plumber")];
var selected = 0;
var draft = "";
var tab = "tasks";
var dark = false;
var theme = Theme.light();
final listScroll = new ScrollController();
```

`Task` is a plain class in `src/Task.hx`:

```haxe
class Task {
	public var title:String;
	public var done:Bool;

	public function new(title:String) {
		this.title = title;
		done = false;
	}
}
```

## Layout and text

`Column` stacks its children from top to bottom and `Row` from left to right. Each child is wrapped in a `KeyedView`
with a key that is unique among its siblings. The key is how the UI recognises a view from one frame to the next, so the
text field you are typing in keeps its focus and its caret when the window is rebuilt.

A `LayoutStyle` says how big a view is and how it places its children:

```haxe
function view():View {
	var style = new LayoutStyle();
	style.width = LayoutAxis.grow();
	style.height = LayoutAxis.grow();
	style.padding = new Insets(16, 16, 16, 16);
	style.childGap = 12;
	style.background = theme.tokens.surface;
	return new Column("root", [
		new KeyedView("title", new Text("Tasks", null, null, null, TextRole.Heading)),
		new KeyedView("tabs", tabs())
	], style);
}
```

- `LayoutAxis.grow()` takes the room the parent has left; `LayoutAxis.fixed(320)` is exactly 320 logical pixels;
  `LayoutAxis.fit()`, the default, is as big as the content.
- `padding` is the space inside the view's edges (left, top, right, bottom) and `childGap` the space between its children.
- `background` fills the view. Here it comes from the theme, so it changes with it (see [Theming](#theming)).

`Text` shows a string. Its role (`Body` by default, `Heading`, `Label`, `Caption` or `Button`) picks its size and colour
from the theme.

The task page puts the list and the form in a fixed-width column on the left, and the detail on the right:

```haxe
return new Row("tasks-page", [
	new KeyedView("list", new Column("list-column", [
		new KeyedView("list", taskList()),
		new KeyedView("form", addForm())
	], column(320))),
	new KeyedView("detail", detail())
], style);
```

`column(width)` is a small helper of the example that makes a vertical `LayoutStyle`; with 0 it grows:

```haxe
static function column(width:Float):LayoutStyle {
	var style = new LayoutStyle();
	style.width = width > 0 ? LayoutAxis.fixed(width) : LayoutAxis.grow();
	style.height = LayoutAxis.grow();
	style.childGap = 8;
	return style;
}
```

## Lists

`VirtualList` shows rows of the same height and builds only the rows that are visible, so it stays fast with thousands
of items. Give it the number of rows, their height, and a function that builds the row at an index:

```haxe
function taskList():VirtualList {
	var style = new LayoutStyle();
	style.width = LayoutAxis.grow();
	style.height = LayoutAxis.grow();
	style.clipVertical = true;
	return new VirtualList("task-list", tasks.length, 40, index -> {
		var task = tasks[index];
		var label = task.done ? '${task.title} (done)' : task.title;
		var row = new LayoutStyle();
		row.width = LayoutAxis.grow();
		row.height = LayoutAxis.fixed(36);
		return new Button(label, row, () -> selected = index, 'task-$index', null, null, index == selected);
	}, style, index -> 'task-$index', listScroll);
}
```

Each row is a `Button`: clicking it sets `selected`, and the button of the selected task is drawn as selected. The
arguments after the label are the style, the action, the key, whether it is enabled, its variant and whether it is
selected. The `ScrollController` is a field, so the list keeps its scroll position from frame to frame.

For rows of different heights, or a list backed by a data model, the package also has `ListView`, `TreeView` and
`TableView` in `haxeon.ui.widgets.collections`.

## Forms

The detail pane shows the selected task with a checkbox and a button:

```haxe
function detail():View {
	if (tasks.length == 0)
		return new Text("No tasks yet.", null, null, null, TextRole.Caption);
	var task = tasks[selected];
	return new Column("detail", [
		new KeyedView("title", new Text(task.title, null, null, null, TextRole.Heading)),
		new KeyedView("done", new Checkbox("done", "Done", task.done, value -> task.done = value)),
		new KeyedView("remove", new Button("Remove", null, () -> remove(selected), "remove"))
	], column(0));
}
```

A control shows the value you pass it and calls your function when the user changes it. `Checkbox` takes the current
value and a function that receives the new one; the function updates the task, and the next frame shows it. `Toggle`
works the same way and looks like a switch.

The form adds a task. A `TextField` reports every edit through its change function, and `onSubmit` runs when the user
presses Enter:

```haxe
function addForm():View {
	var field = new TextField("new-task", draft, text -> draft = text);
	field.placeholder = "New task";
	field.onSubmit = _ -> add();
	var style = new LayoutStyle();
	style.width = LayoutAxis.grow();
	style.childGap = 8;
	return new Row("add-form", [
		new KeyedView("field", field),
		new KeyedView("add", new Button("Add", null, add, "add", draft.length > 0, ButtonVariant.Primary))
	], style);
}

function add():Void {
	if (draft.length == 0)
		return;
	tasks.push(new Task(draft));
	selected = tasks.length - 1;
	draft = "";
}
```

The field shows `draft`, so setting `draft` to an empty string in `add()` clears it. The Add button is enabled only
while there is text, and `ButtonVariant.Primary` marks it as the main action.

Other controls follow the same pattern: `RadioGroup`, `Select`, `ComboBox`, `Slider` and `TextArea` (in
`haxeon.ui.widgets.controls` and `haxeon.ui.widgets.text`).

## Navigation

`Tabs` shows a row of tab headers and the page of the selected one. With `TabsSelectionMode.Controlled` the app owns the
selection: `tab` says which page is shown, and the change function updates it when the user picks another tab:

```haxe
function tabs():Tabs {
	var options = new TabsOptions();
	options.selectionMode = TabsSelectionMode.Controlled;
	var style = new LayoutStyle();
	style.width = LayoutAxis.grow();
	style.height = LayoutAxis.grow();
	options.style = style;
	return Tabs.withOptions("tabs", [
		new TabItem("tasks", "Tasks", tasksPage()),
		new TabItem("settings", "Settings", settingsPage())
	], tab, key -> tab = key, options);
}
```

Because the selection is ordinary state, any code can switch tabs by setting `tab`.

For screens that slide in over each other, as on a phone, the package has `NavigationStack` with a
`NavigationController` (`push`, `pop`) in `haxeon.ui.widgets.navigation`.

## Theming

A `Theme` holds the colours, text styles and spacing every control draws with. `Theme.light()` and `Theme.dark()` are the
two built-in palettes. The app passes its theme to the `UiContext` when it makes it:

```haxe
public function new(host:UiHostContext) {
	this.host = host;
	ui = new UiContext(null, host.fonts, theme);
}
```

The settings page has a switch that changes it:

```haxe
function settingsPage():View {
	var style = column(0);
	style.padding = new Insets(0, 12, 0, 0);
	var toggle = new Toggle("dark", "Dark theme", dark, setDark);
	return new Column("settings", [new KeyedView("dark", toggle)], style);
}

function setDark(value:Bool):Void {
	dark = value;
	theme = dark ? Theme.dark() : Theme.light();
	ui.setTheme(theme);
}
```

`ui.setTheme` restyles every control on the next frame. Colours you set yourself, like the window's background, read
the theme's tokens (`theme.tokens.surface`), so they change with it. `Theme` and `ThemeTokens` in
`haxeon.ui.theme` list every colour and text style a theme has.

## Run it

```sh
haxeon run
```

Click a task to select it, tick Done, type a title and press Enter, then switch to Settings and turn on the dark theme.

An app's window also takes a few options after `--` that let a script run it without a person: `--frames=N` stops after N
rendered frames, requesting redraws as needed even when the app is idle. `--capture=DIR` writes diagnostics to DIR
and on X11 saves a picture of the app window as `frame.png`, taken
with ImageMagick's `import`, and `--input-script=PATH` plays timed clicks and typing from a JSON file. Under Linux without a
display, run it with `xvfb-run`:

```sh
xvfb-run -a haxeon run -- --frames=10 --capture=out/capture
```

The capture's `app-state.json` holds what the app's `diagnosticState()` returns; in this example the number of tasks,
the selection, the tab and the theme.

## Next

- Change the code while the app runs: `haxeon run --watch` keeps the window open and applies your edits.
- [Calling a C or C++ library](04-calling-c-and-cpp.md) from your app.
- [Shipping](05-shipping.md) the app as an executable.
- The UI package's own documentation: [packages/ui/README.md](https://github.com/tritao/haxeon/blob/main/packages/ui/README.md).
