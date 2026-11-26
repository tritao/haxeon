package haxeon.platform;

/** Monotonic callback time in seconds and the size of the framebuffer in pixels. */
class FrameTick {
	/** The callback's monotonic time. */
	public final timeSeconds:Float;
	/** Time since the previous app frame, capped by AppLoop. Raw surface ticks default to zero. */
	public final deltaSeconds:Float;

	/** The framebuffer's width, in pixels. */
	public final width:Int;

	/** The framebuffer's height, in pixels. */
	public final height:Int;

	/** A tick at `timeSeconds` for a `width` by `height` framebuffer. */
	public function new(timeSeconds:Float, width:Int, height:Int, deltaSeconds:Float = 0.0) {
		this.timeSeconds = timeSeconds;
		this.deltaSeconds = deltaSeconds;
		this.width = width;
		this.height = height;
	}
}
