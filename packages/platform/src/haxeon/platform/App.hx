package haxeon.platform;

/** Application callbacks driven by a platform surface. */
interface App extends Disposable {
	function ready():Void;
	function frame(tick:FrameTick, frame:SurfaceFrame):Void;
	function afterFrame():Void;
	function shouldQuit():Bool;
}
