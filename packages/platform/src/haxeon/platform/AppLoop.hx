package haxeon.platform;

import haxe.Int64;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import nativekit.ffi.NativeKitTypes.Result;

/** Drives an app from native surface callbacks and the runtime's event pump. */
class AppLoop implements Disposable {
	final loop:EventLoop;
	final surface:Surface;
	final app:App;
	final recorder:Null<FrameRecorder>;
	final readySubscription:EventSubscription;
	final completionSubscription:EventSubscription;
	var frameSubscription:Null<SurfaceFrameSubscription>;
	var pending:Null<Int64>;
	var submittedTiming:Null<SurfaceFrameTiming>;
	var frameRan = false;
	var stopped = false;
	var disposed = false;
	var failure:Dynamic;

	@:allow(haxeon.platform.Runtime)
	private function new(events:EventPump, surface:Surface, app:App, recorder:Null<FrameRecorder>) {
		loop = new EventLoop(events);
		this.surface = surface;
		this.app = app;
		this.recorder = recorder;
		readySubscription = surface.onReady(startFrames);
		try {
			completionSubscription = surface.onFrameComplete(function(token, result) {
				if (pending != null && token == pending) {
					pending = null;
					if (result != Result.Ok)
						fail(new NativeKitError(result, "AppLoop.frame", "Rendering or presentation failed"));
				}
			});
		} catch (error:Dynamic) {
			readySubscription.dispose();
			throw error;
		}
	}

	/** Pumps one browser tick without blocking. Returns false once any submitted frame has completed and the app has stopped. */
	public function tick():Bool
		return advance(false);

	@:allow(haxeon.platform.Runtime)
	function run():Void
		EventLoop.run(function() return advance(true));

	function advance(wait:Bool):Bool {
		if (disposed)
			return false;
		try {
			loop.step(function(hadEvent) {
				stopped = stopped || app.shouldQuit();
				return wait && !hadEvent && !frameRan && (!stopped || pending != null) ? 0.1 : null;
			});
			if (recorder != null) {
				var timing = submittedTiming;
				submittedTiming = null;
				if (timing != null) recorder.track(timing);
				recorder.collect();
			}
			if (frameRan) {
				frameRan = false;
				if (failure == null)
					app.afterFrame();
			}
			stopped = stopped || app.shouldQuit();
		} catch (error:Dynamic) {
			fail(error);
		}
		if (!stopped || pending != null)
			return true;
		if (failure != null)
			throw failure;
		return false;
	}

	function startFrames():Void {
		if (stopped || frameSubscription != null)
			return;
		try {
			if (app.shouldQuit())
				return;
			app.ready();
			frameSubscription = surface.onFrameTick(draw);
		} catch (error:Dynamic) fail(error);
	}

	function draw(tick:FrameTick):Void {
		if (stopped || frameRan || pending != null || tick.width <= 0 || tick.height <= 0)
			return;
		try {
			if (app.shouldQuit())
				return;
			var timing = recorder == null ? null : recorder.begin(surface, tick.timeSeconds);
			var frame = surface.acquireFrame();
			defer {
				if (frame.wasSubmitted())
					pending = frame.token();
				else if (!frame.isFinished())
					frame.cancel();
				if (timing != null && (frame.wasSubmitted() || frame.wasPresented())) {
					timing.markSubmitted();
					submittedTiming = timing;
				}
			}
			frameRan = true;
			app.frame(tick, frame);
		} catch (error:Dynamic) fail(error);
	}

	function fail(error:Dynamic):Void {
		if (failure == null)
			failure = error;
		stopped = true;
	}

	public function dispose():Void {
		if (disposed)
			return;
		if (pending != null)
			throw BindingError.invalidState("AppLoop.dispose", "Advance the loop until its submitted frame completes");
		defer readySubscription.dispose();
		defer completionSubscription.dispose();
		if (frameSubscription != null)
			frameSubscription.dispose();
		disposed = true;
	}
}
