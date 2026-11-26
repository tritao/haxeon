package haxeon.platform;

/** Application callbacks driven by a platform surface. */
interface App extends Disposable {
	/** Called once the surface can be drawn to, before the first frame. */
	function ready():Void;

	/** Draws one frame into `frame`. */
	function frame(tick:FrameTick, frame:SurfaceFrame):Void;

	/** Called after each frame, for work that should not delay it. */
	function afterFrame():Void;

	/** Whether the app is done; the loop stops after the frame in flight. */
	function shouldQuit():Bool;
}
