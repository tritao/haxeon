package haxeon.platform;

/** Monotonic callback time in seconds and the size of the framebuffer in pixels. */
class FrameTick {
	public final timeSeconds:Float;
	/** Time since the previous app frame, capped by AppLoop. Raw surface ticks default to zero. */
	public final deltaSeconds:Float;
	public final width:Int;
	public final height:Int;

	public function new(timeSeconds:Float, width:Int, height:Int, deltaSeconds:Float = 0.0) {
		this.timeSeconds = timeSeconds;
		this.deltaSeconds = deltaSeconds;
		this.width = width;
		this.height = height;
	}
}
