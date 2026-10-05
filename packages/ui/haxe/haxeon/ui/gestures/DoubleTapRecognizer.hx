package haxeon.ui.gestures;

import haxeon.ui.gestures.GestureKind;
import haxeon.ui.gestures.GestureRecognizer;

/** Recognizes two taps on the same target within a time and distance window. */
class DoubleTapRecognizer extends GestureRecognizer {
	public function new(?onDoubleTap:GestureEvent->Void, intervalSeconds:Float = 0.30,
			distanceTolerance:Float = 24.0)
		super(GestureKind.DoubleTap, distanceTolerance, intervalSeconds, onDoubleTap);
}
