package haxeon.ui.animation;

/**
 * An animation that can spend time waiting for a deadline with nothing visibly changing.
 * The scheduler asks for frames only while an animation is not waiting, and the host wakes
 * once at the earliest deadline instead of drawing frames to count the delay down.
 */
interface DelayedAnimation extends Animation {
	/** Seconds until the next visible change, or 0 when the animation changes every frame. */
	function delaySeconds():Float;
}
