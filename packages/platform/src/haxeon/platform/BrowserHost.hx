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

	public static function tick():BrowserAppStatus
		return advance(null);

	/** Switches the app to explicit frame times for deterministic captures and benchmarks. */
	public static function step(timeSeconds:Float):BrowserAppStatus {
		if (!Math.isFinite(timeSeconds) || timeSeconds < 0.0)
			throw BindingError.invalidArgument("BrowserHost.step", "Frame time must be finite and nonnegative");
		return advance(timeSeconds);
	}

	static function advance(timeSeconds:Null<Float>):BrowserAppStatus {
		var launch = active;
		if (launch == null) return Stopped;
		var running = false;
		defer if (!running) active = null;
		running = timeSeconds == null ? launch.tick() : launch.stepFrame(timeSeconds);
		if (!running) return Stopped;
		return launch.firstFramePresented() ? Presented : Starting;
	}

	/** Requests shutdown. Returns false while the app still needs ticks to drain its last frame. */
	public static function stop():Bool {
		if (active == null) return true;
		if (!active.stop()) return false;
		active = null;
		return true;
	}
}
