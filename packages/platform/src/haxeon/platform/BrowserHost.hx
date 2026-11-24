package haxeon.platform;

enum abstract BrowserAppStatus(Int) {
	var Starting = 0;
	var Presented = 1;
	var Stopped = 2;
}

/** Drives the application registered by Runtime.launch from requestAnimationFrame. */
class BrowserHost {
	static var active:Null<AppLaunch>;

	@:allow(haxeon.platform.Runtime)
	static function requireIdle():Void {
		if (active != null)
			throw BindingError.invalidArgument("Runtime.launch", "A browser application is already running");
	}

	@:allow(haxeon.platform.Runtime)
	static function attach(launch:AppLaunch):Void
		active = launch;

	public static function tick():BrowserAppStatus {
		var launch = active;
		if (launch == null) return Stopped;
		var running = false;
		defer if (!running) active = null;
		running = launch.tick();
		if (!running) return Stopped;
		return launch.firstFramePresented() ? Presented : Starting;
	}

	public static function stop():Void {
		if (active != null && active.stop()) active = null;
	}
}
