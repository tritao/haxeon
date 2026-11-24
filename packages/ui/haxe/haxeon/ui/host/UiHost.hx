package haxeon.ui.host;

/** Runs a UI application on the current platform. */
class UiHost {
	#if wasm
	static var session:Null<BrowserUiHostSession> = null;

	public static function run(create:UiHostContext->UiApplication, options:UiHostOptions):Int {
		start(create, options);
		return 0;
	}

	public static function start(create:UiHostContext->UiApplication, options:UiHostOptions):Void
		session = BrowserUiHost.start(options, create);

	public static function tick(time:Float = 0):Int {
		var active = session;
		if (active == null) return 0;
		var status = active.advance(time);
		if (status < 0) throw Std.string(active.error);
		return status;
	}

	public static function close():Int {
		if (session != null) session.dispose();
		session = null;
		return 0;
	}
	#else
	static var session:Null<DesktopUiHostSession> = null;

	public static function run(create:UiHostContext->UiApplication, options:UiHostOptions):Int {
		start(create, options);
		while (tick() != 0) {}
		return close();
	}

	public static function start(create:UiHostContext->UiApplication, options:UiHostOptions):Void
		session = DesktopUiHost.open(new DesktopUiHostOptions(options).withArguments(Sys.args()), create);

	public static function tick(time:Float = 0):Int
		return session != null && session.tick() ? 1 : 0;

	public static function close():Int {
		var active = session;
		session = null;
		return active == null ? 0 : active.close();
	}
	#end
}
