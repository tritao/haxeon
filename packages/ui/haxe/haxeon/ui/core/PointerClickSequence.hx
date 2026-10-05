package haxeon.ui.core;

/** Recognizes a primary double click on the same item across UI rebuilds. */
class PointerClickSequence {
	var previousKey:String = "";
	var previousTime:Float = -1.0;
	var previousX:Float = 0.0;
	var previousY:Float = 0.0;

	public function new() {}

	public function register(key:String, event:UiEvent):Int {
		var now = event.timestamp >= 0 ? event.timestamp : Sys.time();
		var dx = event.x - previousX, dy = event.y - previousY;
		var doubleClick = event.button == 0 && key == previousKey && previousTime >= 0
			&& now >= previousTime && now - previousTime <= 0.5 && dx * dx + dy * dy <= 25;
		previousKey = doubleClick || event.button != 0 ? "" : key;
		previousTime = now; previousX = event.x; previousY = event.y;
		return doubleClick ? 2 : 1;
	}
}
