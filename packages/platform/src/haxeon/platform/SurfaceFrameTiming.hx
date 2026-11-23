package haxeon.platform;

import haxe.Int64;

/** Timing for one surface callback. All timestamps use monotonic seconds. */
class SurfaceFrameTiming {
	public final frameId:Null<Int64>;
	public final callbackSeconds:Float;
	public var submittedSeconds(default, null):Null<Float>;

	final surface:Surface;

	@:allow(haxeon.platform.Surface)
	private function new(surface:Surface, frameId:Null<Int64>, callbackSeconds:Float) {
		this.surface = surface;
		this.frameId = frameId;
		this.callbackSeconds = callbackSeconds;
	}

	/** Records when the caller finished submitting drawing commands. */
	public function markSubmitted():Void {
		submittedSeconds = Sys.monotonicTime();
	}

	/** Returns the display timestamp when the backend has feedback for this frame. */
	public function presentationSeconds():Null<Float> {
		var id = frameId;
		return id == null ? null : surface.presentationSeconds(id);
	}
}
