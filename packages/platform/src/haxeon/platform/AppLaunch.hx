package haxeon.platform;

/** Owns a running application and closes it after its final frame completes. */
class AppLaunch implements Disposable {
	final runtime:Runtime;
	final app:App;
	final loop:AppLoop;
	var disposed = false;

	@:allow(haxeon.platform.Runtime)
	private function new(runtime:Runtime, app:App, loop:AppLoop) {
		this.runtime = runtime;
		this.app = app;
		this.loop = loop;
	}

	/** Runs one loop iteration. Returns false once the app has stopped and its last frame finished. */
	public function tick():Bool {
		if (disposed) return false;
		var active = false;
		defer if (!active) dispose();
		#if wasm
		active = loop.tick();
		#else
		active = loop.tick(true);
		#end
		return active;
	}

	@:allow(haxeon.platform.BrowserHost)
	function stepFrame(timeSeconds:Float):Bool {
		if (disposed) return false;
		var active = false;
		defer if (!active) dispose();
		active = loop.stepFrame(timeSeconds);
		return active;
	}

	/** Whether a frame has reached the screen yet. */
	public function firstFramePresented():Bool
		return loop.firstFramePresented;

	@:allow(haxeon.platform.Runtime)
	function run():Void {
		defer dispose();
		loop.run();
	}

	/** Requests shutdown. Tick again if the last submitted frame is still pending. */
	public function stop():Bool {
		if (disposed) return true;
		if (!loop.stop()) return false;
		dispose();
		return true;
	}

	public function dispose():Void {
		if (disposed) return;
		#if wasm
		if (!loop.stop()) return;
		#end
		disposed = true;
		defer runtime.dispose();
		defer app.dispose();
		loop.dispose();
	}
}
