import haxeon.ui.host.UiHost;
import haxeon.ui.host.UiHostContext;
import haxeon.ui.host.UiHostOptions;

class Main {
	static var app:Null<App> = null;

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
	static function main():Int
		return UiHost.run(create, options());

	// `haxeon run --watch` sees these, keeps one process and calls them instead of `main`, so edits apply to the running app.

	public static function start(arguments:String):Void
		UiHost.start(create, options());

	public static function tick():Int
		return UiHost.tick();

	public static function close():Int
		return UiHost.close();

	public static function saveState():String
		return "";

	public static function restoreState(state:String):Void {}

	public static function liveRelease():Void
		if (app != null)
			app.release();

	public static function liveRebuild():Void
		if (app != null)
			app.rebuild();
}
