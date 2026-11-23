package haxeon.platform;

/** Monotonic callback time in seconds and the size of the framebuffer in pixels. */
class FrameTick {
	public final timeSeconds:Float;
	public final width:Int;
	public final height:Int;

	public function new(timeSeconds:Float, width:Int, height:Int) {
		this.timeSeconds = timeSeconds;
		this.width = width;
		this.height = height;
	}
}
