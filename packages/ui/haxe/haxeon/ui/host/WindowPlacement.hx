package haxeon.ui.host;

/**
	Where a desktop window sits, so an application can put it back there on its next run: the outer bounds in logical
	screen pixels, and whether it is maximized. For a maximized window the bounds are the ones it restores to.
**/
class WindowPlacement {
	public final x:Int;
	public final y:Int;
	public final width:Int;
	public final height:Int;
	public final maximized:Bool;

	public function new(x:Int, y:Int, width:Int, height:Int, maximized:Bool) {
		this.x = x; this.y = y; this.width = width; this.height = height; this.maximized = maximized;
	}
}
