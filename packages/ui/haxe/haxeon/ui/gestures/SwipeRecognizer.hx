package haxeon.ui.gestures;

import haxeon.ui.gestures.GestureKind;
import haxeon.ui.gestures.GestureRecognizer;

/**
 * Recognizes a horizontal flick on release: faster than `minVelocity` px/s, farther than `minDistance` px, and more
 * horizontal than vertical. The event's `direction` is Left or Right and carries velocityX and velocityY.
 */
class SwipeRecognizer extends GestureRecognizer {
	public static inline var Left:Int = -1;
	public static inline var Right:Int = 1;
	public final minVelocity:Float;

	public function new(?onSwipe:GestureEvent->Void, minVelocity:Float = 600.0, minDistance:Float = 48.0) {
		super(GestureKind.Swipe, minDistance, 0.0, onSwipe);
		this.minVelocity = minVelocity;
	}
}
