package haxeon.ui.gestures;

import haxeon.ui.core.WidgetId;

/** Configurable callback and threshold shared by concrete gesture recognizers. */
class GestureRecognizer {
	/** Which gesture it recognizes. */
	public final kind:GestureKind;

	/** The distance, in pixels, that decides the gesture: how far a tap may move, or how far a drag must. */
	public final threshold:Float;

	/** The time window, in seconds, for gestures that have one: a long press's hold or a double tap's gap. */
	public final interval:Float;

	/** Called when the gesture is recognized. */
	public final onRecognized:GestureEvent->Void;
	internal final hasHandler:Bool;

	/**
	 * A recognizer of `kind`. Throws when `threshold` or `interval` is negative or not finite, or `interval` is zero
	 * for a double tap or long press.
	 */
	public function new(kind:GestureKind, threshold:Float, interval:Float,
			onRecognized:Null<GestureEvent->Void>) {
		if (!finite(threshold) || !finite(interval)
			|| threshold < 0.0 || interval < 0.0
			|| ((kind == GestureKind.DoubleTap || kind == GestureKind.LongPress) && interval == 0.0))
			throw "Gesture thresholds and intervals must be finite and valid";
		this.kind = kind;
		this.threshold = threshold;
		this.interval = interval;
		hasHandler = onRecognized != null;
		this.onRecognized = onRecognized == null ? _ -> {} : onRecognized;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** What a gesture recognizer recognized, or which recognizer it is. */
enum GestureKind {
	/** One tap. */
	Tap;
	/** Two taps in quick succession. */
	DoubleTap;
	/** A press held without moving. */
	LongPress;
	/** A drag began. */
	DragStart;
	/** A drag moved. */
	Drag;
	/** A drag ended. */
	DragEnd;
	/** The two-pointer pinch recognizer; its events are `PinchStart`, `PinchUpdate` and `PinchEnd`. */
	Pinch;
	/** A pinch began. */
	PinchStart;
	/** A pinch changed scale. */
	PinchUpdate;
	/** A pinch ended. */
	PinchEnd;
	/** A fast horizontal flick: the recognizer and its event. */
	Swipe;
}

/** Position and pointer data emitted by a Haxe gesture recognizer. */
class GestureEvent {
	/** What was recognized. */
	public final kind:GestureKind;

	/** The detector's widget. */
	public final target:WidgetId;

	/** The pointer that made the gesture. */
	public final pointerId:Int;

	/** Where the pointer went down, x. */
	public final startX:Float;

	/** Where the pointer went down, y. */
	public final startY:Float;

	/** Where the pointer is now, x. */
	public final x:Float;

	/** Where the pointer is now, y. */
	public final y:Float;

	/** How far it moved from where it went down, x; zero for taps. */
	public final deltaX:Float;

	/** How far it moved from where it went down, y; zero for taps. */
	public final deltaY:Float;

	/** How long since the pointer went down. */
	public final elapsedSeconds:Float;
	/** Pointer velocity in px/s over the last 100 ms; set on drag end and swipe, zero otherwise. */
	public final velocityX:Float;

	/** The vertical velocity, in px/s, as `velocityX`. */
	public final velocityY:Float;
	/** Pinch events: current distance between the pointers over the starting distance (1.0 at start). */
	public final scale:Float;
	/** Pinch events: midpoint between the pointers. */
	public final focusX:Float;

	/** The y of the pinch midpoint. */
	public final focusY:Float;
	/** Swipe events: SwipeRecognizer.Left or SwipeRecognizer.Right; zero otherwise. */
	public final direction:Int;

	/** An event for recognized `kind` on `target`. */
	public function new(kind:GestureKind, target:WidgetId, pointerId:Int, startX:Float, startY:Float,
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
	/** Calls `onTap` for a release within `movementTolerance` pixels of the press. */
	public function new(?onTap:GestureEvent->Void, movementTolerance:Float = 8.0)
		super(GestureKind.Tap, movementTolerance, 0.0, onTap);
}

/** Recognizes two taps on the same target within a time and distance window. */
class DoubleTapRecognizer extends GestureRecognizer {
	/** Calls `onDoubleTap` for a second tap within `intervalSeconds` and `distanceTolerance` pixels of the first. */
	public function new(?onDoubleTap:GestureEvent->Void, intervalSeconds:Float = 0.30,
			distanceTolerance:Float = 24.0)
		super(GestureKind.DoubleTap, distanceTolerance, intervalSeconds, onDoubleTap);
}

/** Recognizes a stationary pointer held for the configured duration. */
class LongPressRecognizer extends GestureRecognizer {
	/**
	 * Calls `onLongPress` once the pointer has been held `durationSeconds` without moving `movementTolerance` pixels.
	 */
	public function new(?onLongPress:GestureEvent->Void, durationSeconds:Float = 0.50,
			movementTolerance:Float = 8.0)
		super(GestureKind.LongPress, movementTolerance, durationSeconds, onLongPress);
}

/** Recognizes a threshold-crossing drag and reports start, updates, and end. */
class DragRecognizer extends GestureRecognizer {
	/** Called when the pointer has moved `threshold` pixels. */
	public final onStart:GestureEvent->Void;

	/** Called for each move after the drag began. */
	public final onMove:GestureEvent->Void;

	/** Called when the pointer is released after a drag. */
	public final onEnd:GestureEvent->Void;
	internal final hasStart:Bool;
	internal final hasMove:Bool;
	internal final hasEnd:Bool;
	/** Velocity in px/s of the most recent drag release, written by the arena just before onEnd runs. */
	public var velocityX(default, null):Float = 0.0;

	/** The vertical velocity of the most recent release, in px/s. */
	public var velocityY(default, null):Float = 0.0;

	/** A drag that begins once the pointer has moved `threshold` pixels. */
	public function new(threshold:Float = 6.0, ?onStart:GestureEvent->Void,
			?onMove:GestureEvent->Void, ?onEnd:GestureEvent->Void) {
		super(GestureKind.Drag, threshold, 0.0, null);
		hasStart = onStart != null;
		hasMove = onMove != null;
		hasEnd = onEnd != null;
		this.onStart = onStart == null ? _ -> {} : onStart;
		this.onMove = onMove == null ? _ -> {} : onMove;
		this.onEnd = onEnd == null ? _ -> {} : onEnd;
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
	/** A swipe toward the left. */
	public static inline var Left:Int = -1;

	/** A swipe toward the right. */
	public static inline var Right:Int = 1;

	/** The slowest release, in px/s, that counts as a swipe. */
	public final minVelocity:Float;

	/** Calls `onSwipe` for a release faster than `minVelocity` after moving `minDistance` pixels. */
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
	/** Called when the second pointer goes down. */
	public final onBegin:GestureEvent->Void;

	/** Called as either pointer moves. */
	public final onUpdate:GestureEvent->Void;

	/** Called when either pointer is released. */
	public final onEnd:GestureEvent->Void;
	internal final hasBegin:Bool;
	internal final hasUpdate:Bool;
	internal final hasEnd:Bool;

	/** A pinch with the given callbacks. */
	public function new(?onBegin:GestureEvent->Void, ?onUpdate:GestureEvent->Void, ?onEnd:GestureEvent->Void) {
		super(GestureKind.Pinch, 0.0, 0.0, null);
		hasBegin = onBegin != null;
		hasUpdate = onUpdate != null;
		hasEnd = onEnd != null;
		this.onBegin = onBegin == null ? _ -> {} : onBegin;
		this.onUpdate = onUpdate == null ? _ -> {} : onUpdate;
		this.onEnd = onEnd == null ? _ -> {} : onEnd;
	}
}

/** Pointer velocity in px/s from the samples of the last 100 ms. */
class VelocityTracker {
	/** How far back, in seconds, samples count. */
	public static inline var WindowSeconds:Float = 0.1;
	final times:Array<Float> = [];
	final xs:Array<Float> = [];
	final ys:Array<Float> = [];

	/** The horizontal velocity `compute` found, in px/s. */
	public var velocityX(default, null):Float = 0.0;

	/** The vertical velocity `compute` found, in px/s. */
	public var velocityY(default, null):Float = 0.0;

	/** A tracker with no samples. */
	public function new() {}

	/** Drops every sample and zeroes the velocity. */
	public function reset():Void {
		times.resize(0);
		xs.resize(0);
		ys.resize(0);
		velocityX = 0.0;
		velocityY = 0.0;
	}

	/** Records the pointer at `x`, `y` at `time` seconds. */
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
