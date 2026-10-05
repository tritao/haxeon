package haxeon.ui.gestures;

import haxeon.ui.gestures.GestureKind;
import haxeon.ui.gestures.GestureRecognizer;

/** Recognizes a stationary pointer held for the configured duration. */
class LongPressRecognizer extends GestureRecognizer {
	public function new(?onLongPress:GestureEvent->Void, durationSeconds:Float = 0.50,
			movementTolerance:Float = 8.0)
		super(GestureKind.LongPress, movementTolerance, durationSeconds, onLongPress);
}
