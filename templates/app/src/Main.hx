#if android
// Keep the greeting until the UI toolkit supports Android.
function main():Void
	Sys.println("Hello from {{name}}");
#else
import haxeon.platform.AppLaunch;
import haxeon.reactive.Signal;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.host.UiApplication;
import haxeon.ui.host.UiHost;
import haxeon.ui.host.UiHostContext;
import haxeon.ui.host.UiHostOptions;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;

/** The window's content. Change `view` while `haxeon run --watch` runs: the window updates and keeps the count. */
class App implements UiApplication implements UiDiagnosticsProvider {
	final ui:UiContext;
	final theme = Theme.light();
	final host:UiHostContext;

	public function new(host:UiHostContext) {
		this.host = host;
		ui = new UiContext(null, host.fonts, theme);
	}

	function view():View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		style.background = theme.tokens.panelBackground;
		style.padding = new Insets(24, 24, 24, 24);
		style.childGap = 12;
		return new Column("root", [
			new KeyedView("count", new Text('You clicked ${Main.count.value} times')),
			new KeyedView("button", new Button("Click me", null, () -> Main.count.value = Main.count.value + 1))
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

	static var rendered:Int = -1;
	static var app:Null<App> = null;

	static function options():UiHostOptions {
		var options = new UiHostOptions();
		options.title = "{{name}}";
		options.width = 480;
		options.height = 320;
		options.onFrameRendered = () -> rendered = count.value;
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

	// `haxeon run --watch` sees these, keeps one process and calls them instead of `main`, so edits apply to the running app.

	static var launch:Null<AppLaunch>;

	public static function start(arguments:String):Void
		launch = UiHost.open(create, options());

	public static function tick():Int
		return launch != null && launch.tick() ? 1 : 0;

	public static function close():Int {
		if (launch != null) launch.dispose();
		launch = null;
		return 0;
	}

	public static function renderedCount():Int
		return rendered;

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
#end
