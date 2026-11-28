package haxeon.ui.animation;

/** One Haxe-side animation advanced by the UiContext frame clock. */
interface Animation {
	/** Advances by a non-negative duration and returns whether it remains active. */
	function advance(deltaSeconds:Float):Bool;
}

/**
 * An animation that can spend time waiting for a deadline with nothing visibly changing.
 * The scheduler asks for frames only while an animation is not waiting, and the host wakes
 * once at the earliest deadline instead of drawing frames to count the delay down.
 */
interface DelayedAnimation extends Animation {
	/** Seconds until the next visible change, or 0 when the animation changes every frame. */
	function delaySeconds():Float;
}

/** Repeating normalized phase advanced by the Haxe UI frame clock. */
class LoopAnimation implements Animation {
	/** Where in the loop it is, from 0 up to 1. */
	public var phase(default, null):Float;

	/** Loops per second. */
	public var speed:Float;

	/** A loop at phase zero, running `speed` loops per second. Throws unless `speed` is finite and positive. */
	public function new(speed:Float = 1.0) {
		if (!finite(speed) || speed <= 0.0)
			throw "Loop animation speed must be finite and positive";
		this.speed = speed;
		phase = 0.0;
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!finite(deltaSeconds) || deltaSeconds < 0.0)
			throw "Loop animation time must be finite and non-negative";
		phase += deltaSeconds * speed;
		phase -= Std.int(phase);
		return true;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
