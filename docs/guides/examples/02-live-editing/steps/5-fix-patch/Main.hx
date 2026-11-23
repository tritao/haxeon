import haxeon.reactive.Signal;
import haxeon.ui.Insets;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.host.DesktopUiHostSession;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;

/** The window's content. Change `view` while `haxeon run --watch --live` runs: the window updates and keeps the count. */
class App implements DesktopUiApplication {
	final ui:UiContext;
	final host:DesktopUiHostContext;

	/** The highest count so far. */
	var best = 0;

	public function new(host:DesktopUiHostContext) {
		this.host = host;
		ui = new UiContext(null, host.fonts);
	}

	function add(amount:Int):Void {
		Main.count.value = Main.count.value + amount;
		if (Main.count.value > best)
			best = Main.count.value;
	}

	function view():View {
		var style = new LayoutStyle();
		style.padding = new Insets(24, 24, 24, 24);
		style.childGap = 12;
		return new Column("root", [
			new KeyedView("title", new Text("My first app")),
			new KeyedView("count", new Text('Count: ${Main.count.value}')),
			new KeyedView("best", new Text('Best: $best')),
			new KeyedView("button", new Button('Add ${Main.step}', null, () -> add(Main.step))),
			new KeyedView("reset", new Button("Reset", null, () -> Main.count.value = 0)),
			new KeyedView("hint", new Text('Each click adds ${Main.step}'))
		], style);
	}

	public function context():UiContext
		return ui;

	public function submit(frame:LayoutFrame):RenderNode
		return ui.submit(view(), frame);

	public function dispose():Void {}

	public function diagnosticState():Dynamic
		return {count: Main.count.value};

	/** Before a patch that removes code: let go of the UI built from the old code, its handlers among them. */
	public function release():Void
		ui.releaseRetained();

	/** After every patch: draw a frame, which builds the UI from the patched code. */
	public function rebuild():Void
		host.requestFrame();
}

class Main {
	/** The app's state: a live edit keeps it, and a reload carries it through `saveState` and `restoreState`. */
	public static final count = new Signal(0);

	/** How much a click adds. */
	public static var step = 3;

	static var session:Null<DesktopUiHostSession> = null;
	static var app:Null<App> = null;

	static function options():DesktopUiHostOptions {
		var options = new DesktopUiHostOptions();
		options.title = "My App";
		options.width = 480;
		options.height = 320;
		return options.withArguments(Sys.args());
	}

	static function create(host:DesktopUiHostContext):App {
		var created = new App(host);
		app = created;
		return created;
	}

	/** `haxeon run`: open the window and run until it closes. */
	static function main():Int
		return DesktopUiHost.run(options(), create);

	// `haxeon run --watch --live` keeps one process and calls these instead of `main`, so edits apply to the running app.

	public static function start(arguments:String):Void
		session = DesktopUiHost.open(options(), create);

	public static function tick():Int
		return session != null && session.tick() ? 1 : 0;

	public static function close():Int
		return session == null ? 0 : session.close();

	public static function saveState():String
		return Std.string(count.value);

	public static function restoreState(state:String):Void
		count.value = Std.parseInt(state) ?? 0;

	public static function liveRelease():Void
		if (app != null)
			app.release();

	public static function liveRebuild():Void
		if (app != null)
			app.rebuild();
}
