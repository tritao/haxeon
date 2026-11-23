import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.theme.TextRole;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.TabsOptions;
import haxeon.ui.widgets.controls.TabsSelectionMode;
import haxeon.ui.widgets.controls.Toggle;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

/** The window's content: a list of tasks, the selected task's detail, a form that adds one, and a settings tab. */
class App implements DesktopUiApplication {
	final ui:UiContext;
	final host:DesktopUiHostContext;

	// The app's state. `view()` builds the window's content from it each time the window draws a frame.
	final tasks = [new Task("Buy milk"), new Task("Write the report"), new Task("Call the plumber")];
	var selected = 0;
	var draft = "";
	var tab = "tasks";
	var dark = false;
	var theme = Theme.light();
	final listScroll = new ScrollController();

	public function new(host:DesktopUiHostContext) {
		this.host = host;
		ui = new UiContext(null, host.fonts, theme);
	}

	function view():View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.padding = new Insets(16, 16, 16, 16);
		style.childGap = 12;
		style.background = theme.tokens.panelBackground;
		return new Column("root", [
			new KeyedView("title", new Text("Tasks", null, null, null, TextRole.Heading)),
			new KeyedView("tabs", tabs())
		], style);
	}

	function tabs():Tabs {
		var options = new TabsOptions();
		options.selectionMode = TabsSelectionMode.Controlled;
		options.style = new LayoutStyle();
		options.style.width = LayoutAxis.grow();
		options.style.height = LayoutAxis.grow();
		return Tabs.withOptions("tabs", [
			new TabItem("tasks", "Tasks", tasksPage()),
			new TabItem("settings", "Settings", settingsPage())
		], tab, key -> tab = key, options);
	}

	function tasksPage():View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.padding = new Insets(0, 12, 0, 0);
		style.childGap = 16;
		return new Row("tasks-page", [
			new KeyedView("list", new Column("list-column", [
				new KeyedView("list", taskList()),
				new KeyedView("form", addForm())
			], column(320))),
			new KeyedView("detail", detail())
		], style);
	}

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

	function remove(index:Int):Void {
		tasks.splice(index, 1);
		selected = tasks.length == 0 ? 0 : Std.int(Math.min(index, tasks.length - 1));
	}

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

	/** A vertical stack, `width` wide, or as wide as there is room for with 0. */
	static function column(width:Float):LayoutStyle {
		var style = new LayoutStyle();
		style.width = width > 0 ? LayoutAxis.fixed(width) : LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.childGap = 8;
		return style;
	}

	public function context():UiContext
		return ui;

	public function submit(frame:LayoutFrame):RenderNode
		return ui.submit(view(), frame);

	public function dispose():Void {}

	public function diagnosticState():Dynamic
		return {tasks: tasks.length, selected: selected, tab: tab, dark: dark};

	/** Before a patch that removes code: let go of the UI built from the old code, its handlers among them. */
	public function release():Void
		ui.releaseRetained();

	/** After every patch: draw a frame, which builds the UI from the patched code. */
	public function rebuild():Void
		host.requestFrame();
}
