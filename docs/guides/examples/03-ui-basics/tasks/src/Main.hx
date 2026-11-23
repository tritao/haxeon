import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.host.DesktopUiHostSession;

class Main {
	static var session:Null<DesktopUiHostSession> = null;
	static var app:Null<App> = null;

	static function options():DesktopUiHostOptions {
		var options = new DesktopUiHostOptions();
		options.title = "Task List";
		options.width = 720;
		options.height = 480;
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

	// `haxeon run --watch` sees these, keeps one process and calls them instead of `main`, so edits apply to the running app.

	public static function start(arguments:String):Void
		session = DesktopUiHost.open(options(), create);

	public static function tick():Int
		return session != null && session.tick() ? 1 : 0;

	public static function close():Int
		return session == null ? 0 : session.close();

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
