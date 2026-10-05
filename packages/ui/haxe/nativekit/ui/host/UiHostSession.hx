package nativekit.ui.host;

enum abstract UiHostLifecycle(Int) from Int to Int {
	var Starting = 0;
	var LoadingResources = 1;
	var Running = 2;
	var Stopping = 3;
	var Stopped = 4;
	var Failed = 5;
}

/** Structured host error retained after asynchronous startup or frame failure. */
class UiHostError {
	public final stage:String;
	public final message:String;
	public final cause:Dynamic;
	public final stack:String;

	public function new(stage:String, cause:Dynamic) {
		this.stage = stage;
		this.cause = cause;
		this.message = Std.string(cause);
		this.stack = haxe.CallStack.toString(haxe.CallStack.exceptionStack());
	}

	public function toString():String return stage + ": " + message;
}

/** Nonblocking handle for a hosted application's complete lifetime. */
class UiHostSession {
	public var state(default, null):UiHostLifecycle = UiHostLifecycle.Starting;
	public var error(default, null):Null<UiHostError> = null;
	public final cleanupErrors:Array<UiHostError> = [];
	final stopCallback:Void->Void;
	var disposed:Bool = false;
	var stopNotified:Bool = false;

	public function new(stopCallback:Void->Void) this.stopCallback = stopCallback;

	@:allow(nativekit.ui.host.UiHostRuntime)
	@:allow(nativekit.ui.host.BrowserUiHost)
	@:allow(nativekit.ui.host.DesktopUiHost)
	function transition(next:UiHostLifecycle):Void {
		if (state == next) return;
		var valid = switch (state) {
			case UiHostLifecycle.Starting:
				next == UiHostLifecycle.LoadingResources || next == UiHostLifecycle.Running ||
				next == UiHostLifecycle.Stopping || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.LoadingResources:
				next == UiHostLifecycle.Running || next == UiHostLifecycle.Stopping ||
				next == UiHostLifecycle.Failed;
			case UiHostLifecycle.Running:
				next == UiHostLifecycle.Stopping || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.Stopping:
				next == UiHostLifecycle.Stopped || next == UiHostLifecycle.Failed;
			case UiHostLifecycle.Stopped, UiHostLifecycle.Failed: false;
			case _: false;
		};
		if (!valid) throw "Invalid UI host lifecycle transition";
		state = next;
	}

	@:allow(nativekit.ui.host.UiHostRuntime)
	@:allow(nativekit.ui.host.BrowserUiHost)
	@:allow(nativekit.ui.host.DesktopUiHost)
	function fail(stage:String, cause:Dynamic):Void {
		if (error == null) error = new UiHostError(stage, cause);
		if (state != UiHostLifecycle.Stopped) state = UiHostLifecycle.Failed;
	}

	@:allow(nativekit.ui.host.UiHostRuntime)
	@:allow(nativekit.ui.host.BrowserUiHost)
	@:allow(nativekit.ui.host.DesktopUiHost)
	function cleanupFailed(stage:String, cause:Dynamic):Void
		cleanupErrors.push(new UiHostError(stage, cause));

	public function isActive():Bool return state == UiHostLifecycle.Starting ||
		state == UiHostLifecycle.LoadingResources || state == UiHostLifecycle.Running;

	/** Stops the hosted application. Browser hosts do not claim to close the tab. */
	public function stop():Void {
		if (disposed || stopNotified || state == UiHostLifecycle.Stopped ||
			state == UiHostLifecycle.Failed) return;
		stopNotified = true;
		state = UiHostLifecycle.Stopping;
		stopCallback();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		if (state != UiHostLifecycle.Stopped && state != UiHostLifecycle.Failed)
			state = UiHostLifecycle.Stopping;
		if (!stopNotified) {
			stopNotified = true;
			stopCallback();
		}
	}
}
