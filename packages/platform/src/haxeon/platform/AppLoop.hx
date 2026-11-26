package haxeon.platform;

import haxe.Int64;
import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import nativekit.ffi.NativeKitTypes.Result;

/** Drives an app from native surface callbacks and the runtime's event pump. */
class AppLoop implements Disposable {
	static inline var maxFrameDeltaSeconds = 0.1;

	final loop:EventLoop;
	final surface:Surface;
	final app:App;
	final recorder:Null<FrameRecorder>;
	final poll:Null<Void->Null<Float>>;
	final readySubscription:EventSubscription;
	final lostSubscription:EventSubscription;
	final completionSubscription:EventSubscription;
	var frameSubscription:Null<SurfaceFrameSubscription>;
	var pending:Null<Int64>;
	var submittedTiming:Null<SurfaceFrameTiming>;
	var frameRan = false;
	var lastFrameAt:Null<Float>;
	var stopped = false;
	var surfaceLost = false;
	var started = false;
	var manualFrames = false;
	var redrawDeferred = false;
	var disposed = false;
	var disposalRequested = false;
	var failure:Null<haxe.Exception>;

	/** Whether a frame has reached the screen yet. */
	public var firstFramePresented(default, null) = false;

	@:allow(haxeon.platform.Runtime)
	private function new(events:EventPump, surface:Surface, app:App, recorder:Null<FrameRecorder>,
			?poll:Void->Null<Float>) {
		loop = new EventLoop(events);
		this.surface = surface;
		this.app = app;
		this.recorder = recorder;
		this.poll = poll;
		readySubscription = surface.onReady(function() {
			var wasLost = surfaceLost;
			surfaceLost = false;
			startFrames();
			if (wasLost && !stopped && !app.shouldQuit()) surface.requestFrame();
		});
		try {
			lostSubscription = surface.onLost(function() surfaceLost = true);
			completionSubscription = surface.onFrameComplete(function(token, result) {
				if (pending != null && token == pending) {
					pending = null;
					if (result == Result.Ok)
						firstFramePresented = true;
					else if (result == Result.ErrorCancelled || result == Result.ErrorSurfaceLost) {
						if (!stopped && !app.shouldQuit()) surface.requestFrame();
					} else
						fail(new NativeKitError(result, "AppLoop.frame", "Rendering or presentation failed"));
					requestDeferredRedraw();
				}
			});
		} catch (error:haxe.Exception) {
			defer readySubscription.dispose();
			if (lostSubscription != null) lostSubscription.dispose();
			throw error;
		}
	}

	/** Requests shutdown and reports whether all submitted work has completed. */
	public function stop():Bool {
		stopped = true;
		return pending == null;
	}

	/** Pumps one tick. Returns false after the app stops and any submitted frame completes. */
	public function tick(wait:Bool = false):Bool
		return advance(wait);

	@:allow(haxeon.platform.AppLaunch)
	function run():Void
		EventLoop.run(function() return advance(true));

	@:allow(haxeon.platform.AppLaunch)
	function stepFrame(timeSeconds:Float):Bool {
		if (!manualFrames) {
			manualFrames = true;
			if (frameSubscription != null) {
				frameSubscription.dispose();
				frameSubscription = null;
			}
			lastFrameAt = null;
		}
		if (!advance(false)) return false;
		if (!started || stopped || surfaceLost || pending != null) return true;
		var size = nativekit.ffi.NativeKit.nk_surface_get_framebuffer_size(surface.nativeHandle());
		if (size.status != Result.Ok)
			fail(new NativeKitError(size.status, "AppLoop.stepFrame", "Could not query the framebuffer"));
		else draw(size.out_width, size.out_height, timeSeconds);
		return advance(false);
	}

	function advance(wait:Bool):Bool {
		if (disposed)
			return false;
		try {
			loop.step(function(hadEvent) {
				stopped = stopped || app.shouldQuit();
				var wake = stopped || poll == null ? null : poll();
				return wait && !hadEvent && !frameRan && (!stopped || pending != null)
					? (wake == null ? 0.1 : Math.min(0.1, wake)) : null;
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
				requestDeferredRedraw();
			}
			stopped = stopped || app.shouldQuit();
		} catch (error:haxe.Exception) {
			fail(error);
		}
		if (!stopped || pending != null)
			return true;
		if (disposalRequested)
			detach();
		if (failure != null)
			throw failure;
		return false;
	}

	function startFrames():Void {
		if (stopped || started)
			return;
		try {
			if (app.shouldQuit())
				return;
			app.ready();
			started = true;
			if (!manualFrames) frameSubscription = surface.onFrame(function(w, h) draw(w, h));
		} catch (error:haxe.Exception) fail(error);
	}

	function draw(width:Int, height:Int, ?timeSeconds:Float):Void {
		if (stopped || surfaceLost || width <= 0 || height <= 0)
			return;
		if (frameRan || pending != null) {
			redrawDeferred = true;
			return;
		}
		try {
			if (app.shouldQuit())
				return;
			var now = timeSeconds ?? Sys.monotonicTime();
			var previous = lastFrameAt;
			var delta = previous == null ? 0.0 : Math.max(0.0, Math.min(now - previous, maxFrameDeltaSeconds));
			var tick = new FrameTick(now, width, height, delta);
			var timing = recorder == null ? null : recorder.begin(surface, tick.timeSeconds);
			var frame = surface.acquireFrame();
			defer {
				if (frame.wasSubmitted())
					pending = frame.token();
				else if (frame.wasPresented())
					firstFramePresented = true;
				else if (!frame.isFinished())
					frame.cancel();
				if (timing != null && (frame.wasSubmitted() || frame.wasPresented())) {
					timing.markSubmitted();
					submittedTiming = timing;
				}
			}
			frameRan = true;
			lastFrameAt = now;
			app.frame(tick, frame);
		} catch (error:haxe.Exception) fail(error);
	}

	function requestDeferredRedraw():Void {
		if (redrawDeferred && pending == null && !stopped && !surfaceLost && !app.shouldQuit()) {
			redrawDeferred = false;
			surface.requestFrame();
		}
	}

	function fail(error:haxe.Exception):Void {
		if (failure == null)
			failure = error;
		stopped = true;
	}

	/** Stops the loop. A browser host continues ticking until any pending frame completes. */
	public function dispose():Void {
		if (disposed)
			return;
		disposalRequested = true;
		if (stop()) {
			detach();
			return;
		}
		#if !wasm
		run();
		#end
	}

	function detach():Void {
		defer readySubscription.dispose();
		defer lostSubscription.dispose();
		defer completionSubscription.dispose();
		if (frameSubscription != null)
			frameSubscription.dispose();
		disposed = true;
	}
}
