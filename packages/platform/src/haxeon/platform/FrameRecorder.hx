package haxeon.platform;

/** Samples submission and presentation timestamps for a surface's frame callbacks. */
class FrameRecorder {
	final onSubmitted:Null<SurfaceFrameTiming->Void>;
	final onPresented:Null<SurfaceFrameTiming->Float->Void>;
	final pending:Array<{timing:SurfaceFrameTiming, notify:Null<Float->Void>}> = [];

	public function new(?onSubmitted:SurfaceFrameTiming->Void, ?onPresented:SurfaceFrameTiming->Float->Void) {
		this.onSubmitted = onSubmitted;
		this.onPresented = onPresented;
	}

	public function begin(surface:Surface, callbackSeconds:Float):SurfaceFrameTiming
		return surface.captureFrameTiming(callbackSeconds);

	/** Retains recent samples long enough for asynchronous display feedback. */
	public function track(timing:SurfaceFrameTiming, ?notify:Float->Void):Void {
		if (timing.frameId != null && (notify != null || onPresented != null)) {
			if (pending.length >= 8) pending.shift();
			pending.push({timing: timing, notify: notify});
		}
		if (onSubmitted != null) onSubmitted(timing);
	}

	public function collect():Void {
		var index = pending.length - 1;
		while (index >= 0) {
			var sample = pending[index];
			var seconds = sample.timing.presentationSeconds();
			if (seconds != null) {
				pending.splice(index, 1);
				var notify = sample.notify;
				if (notify != null) notify(seconds);
				if (onPresented != null) onPresented(sample.timing, seconds);
			}
			index--;
		}
	}
}
