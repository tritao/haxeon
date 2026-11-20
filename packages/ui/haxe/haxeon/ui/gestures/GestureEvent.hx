package haxeon.ui.gestures;

import haxeon.ui.core.WidgetId;

/** Position and pointer data emitted by a Haxe gesture recognizer. */
class GestureEvent {
	public final kind:Int;
	public final target:WidgetId;
	public final pointerId:Int;
	public final startX:Float;
	public final startY:Float;
	public final x:Float;
	public final y:Float;
	public final deltaX:Float;
	public final deltaY:Float;
	public final elapsedSeconds:Float;
	/** Pointer velocity in px/s over the last 100 ms; set on drag end and swipe, zero otherwise. */
	public final velocityX:Float;
	public final velocityY:Float;
	/** Pinch events: current distance between the pointers over the starting distance (1.0 at start). */
	public final scale:Float;
	/** Pinch events: midpoint between the pointers. */
	public final focusX:Float;
	public final focusY:Float;
	/** Swipe events: SwipeRecognizer.Left or SwipeRecognizer.Right; zero otherwise. */
	public final direction:Int;

	public function new(kind:Int, target:WidgetId, pointerId:Int, startX:Float, startY:Float,
			x:Float, y:Float, deltaX:Float, deltaY:Float, elapsedSeconds:Float, velocityX:Float = 0.0,
			velocityY:Float = 0.0, scale:Float = 1.0, focusX:Float = 0.0, focusY:Float = 0.0, direction:Int = 0) {
		this.kind = kind;
		this.target = target;
		this.pointerId = pointerId;
		this.startX = startX;
		this.startY = startY;
		this.x = x;
		this.y = y;
		this.deltaX = deltaX;
		this.deltaY = deltaY;
		this.elapsedSeconds = elapsedSeconds;
		this.velocityX = velocityX;
		this.velocityY = velocityY;
		this.scale = scale;
		this.focusX = focusX;
		this.focusY = focusY;
		this.direction = direction;
	}
}
