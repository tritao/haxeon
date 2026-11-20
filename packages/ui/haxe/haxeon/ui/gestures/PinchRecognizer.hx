package haxeon.ui.gestures;

import haxeon.ui.gestures.GestureKind;
import haxeon.ui.gestures.GestureRecognizer;

/**
 * Recognizes two pointers pressed on the same detector. Each callback receives a GestureEvent whose `scale` is the
 * pointer distance over its starting distance and whose `focusX`/`focusY` is their midpoint. While a pinch is active the
 * two pointers produce no tap, drag or swipe.
 */
class PinchRecognizer extends GestureRecognizer {
	public final onBegin:GestureEvent->Void;
	public final onUpdate:GestureEvent->Void;
	public final onEnd:GestureEvent->Void;
	public final hasBegin:Bool;
	public final hasUpdate:Bool;
	public final hasEnd:Bool;

	public function new(?onBegin:GestureEvent->Void, ?onUpdate:GestureEvent->Void, ?onEnd:GestureEvent->Void) {
		super(GestureKind.Pinch, 0.0, 0.0, null);
		hasBegin = onBegin != null;
		hasUpdate = onUpdate != null;
		hasEnd = onEnd != null;
		this.onBegin = onBegin == null ? function(_) {} : onBegin;
		this.onUpdate = onUpdate == null ? function(_) {} : onUpdate;
		this.onEnd = onEnd == null ? function(_) {} : onEnd;
	}
}
