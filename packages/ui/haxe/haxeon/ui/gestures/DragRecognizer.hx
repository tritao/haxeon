package haxeon.ui.gestures;

import haxeon.ui.gestures.GestureKind;
import haxeon.ui.gestures.GestureRecognizer;

/** Recognizes a threshold-crossing drag and reports start, updates, and end. */
class DragRecognizer extends GestureRecognizer {
	public final onStart:GestureEvent->Void;
	public final onMove:GestureEvent->Void;
	public final onEnd:GestureEvent->Void;
	public final hasStart:Bool;
	public final hasMove:Bool;
	public final hasEnd:Bool;
	/** Velocity in px/s of the most recent drag release, written by the arena just before onEnd runs. */
	public var velocityX(default, null):Float = 0.0;
	public var velocityY(default, null):Float = 0.0;

	public function new(threshold:Float = 6.0, ?onStart:GestureEvent->Void,
			?onMove:GestureEvent->Void, ?onEnd:GestureEvent->Void) {
		super(GestureKind.Drag, threshold, 0.0, null);
		hasStart = onStart != null;
		hasMove = onMove != null;
		hasEnd = onEnd != null;
		this.onStart = onStart == null ? function(_) {} : onStart;
		this.onMove = onMove == null ? function(_) {} : onMove;
		this.onEnd = onEnd == null ? function(_) {} : onEnd;
	}

	@:allow(haxeon.ui.gestures.GestureArena)
	function setVelocity(x:Float, y:Float):Void {
		velocityX = x;
		velocityY = y;
	}
}
