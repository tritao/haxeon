package haxeon.ui.gestures;

import haxeon.ui.core.WidgetId;

/** Configurable callback and threshold shared by concrete gesture recognizers. */
class GestureRecognizer {
	public final kind:Int;
	public final threshold:Float;
	public final interval:Float;
	public final onRecognized:GestureEvent->Void;
	public final hasHandler:Bool;

	public function new(kind:Int, threshold:Float, interval:Float,
			onRecognized:Null<GestureEvent->Void>) {
		if (kind < GestureKind.Tap || kind > GestureKind.Swipe || !finite(threshold) || !finite(interval)
			|| threshold < 0.0 || interval < 0.0
			|| ((kind == GestureKind.DoubleTap || kind == GestureKind.LongPress) && interval == 0.0))
			throw "Gesture thresholds and intervals must be finite and valid";
		this.kind = kind;
		this.threshold = threshold;
		this.interval = interval;
		hasHandler = onRecognized != null;
		this.onRecognized = onRecognized == null ? function(_) {} : onRecognized;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Gesture recognizer output categories. */
class GestureKind {
	public static inline var Tap:Int = 1;
	public static inline var DoubleTap:Int = 2;
	public static inline var LongPress:Int = 3;
	public static inline var DragStart:Int = 4;
	public static inline var Drag:Int = 5;
	public static inline var DragEnd:Int = 6;
	/** Recognizer category for two-pointer pinch; its events are PinchStart, PinchUpdate and PinchEnd. */
	public static inline var Pinch:Int = 7;
	public static inline var PinchStart:Int = 8;
	public static inline var PinchUpdate:Int = 9;
	public static inline var PinchEnd:Int = 10;
	/** Recognizer category and event for a fast horizontal flick. */
	public static inline var Swipe:Int = 11;
}

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

/** Recognizes a pointer release without a long press or drag. */
class TapRecognizer extends GestureRecognizer {
	public function new(?onTap:GestureEvent->Void, movementTolerance:Float = 8.0)
		super(GestureKind.Tap, movementTolerance, 0.0, onTap);
}

/** Recognizes two taps on the same target within a time and distance window. */
class DoubleTapRecognizer extends GestureRecognizer {
	public function new(?onDoubleTap:GestureEvent->Void, intervalSeconds:Float = 0.30,
			distanceTolerance:Float = 24.0)
		super(GestureKind.DoubleTap, distanceTolerance, intervalSeconds, onDoubleTap);
}

/** Recognizes a stationary pointer held for the configured duration. */
class LongPressRecognizer extends GestureRecognizer {
	public function new(?onLongPress:GestureEvent->Void, durationSeconds:Float = 0.50,
			movementTolerance:Float = 8.0)
		super(GestureKind.LongPress, movementTolerance, durationSeconds, onLongPress);
}

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

/** Pointer velocity in px/s from the samples of the last 100 ms. */
class VelocityTracker {
	public static inline var WindowSeconds:Float = 0.1;
	final times:Array<Float> = [];
	final xs:Array<Float> = [];
	final ys:Array<Float> = [];
	public var velocityX(default, null):Float = 0.0;
	public var velocityY(default, null):Float = 0.0;

	public function new() {}

	public function reset():Void {
		times.resize(0);
		xs.resize(0);
		ys.resize(0);
		velocityX = 0.0;
		velocityY = 0.0;
	}

	public function add(time:Float, x:Float, y:Float):Void {
		times.push(time);
		xs.push(x);
		ys.push(y);
		while (times.length > 2 && time - times[0] > WindowSeconds) {
			times.shift();
			xs.shift();
			ys.shift();
		}
	}

	/** Updates velocityX and velocityY; a pointer that has rested for the whole window has none. */
	public function compute(now:Float):Void {
		velocityX = 0.0;
		velocityY = 0.0;
		var count = times.length;
		if (count < 2 || now - times[count - 1] > WindowSeconds)
			return;
		var first = 0;
		while (first < count - 1 && times[count - 1] - times[first] > WindowSeconds)
			first++;
		var elapsed = times[count - 1] - times[first];
		if (elapsed < 0.004)
			return;
		velocityX = (xs[count - 1] - xs[first]) / elapsed;
		velocityY = (ys[count - 1] - ys[first]) / elapsed;
	}
}
