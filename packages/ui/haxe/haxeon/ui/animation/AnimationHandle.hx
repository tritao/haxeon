package haxeon.ui.animation;

/** Stable registration returned by AnimationScheduler.track. */
class AnimationHandle {
	final scheduler:AnimationScheduler;
	final animation:Animation;
	public var active(default, null):Bool;

	@:allow(haxeon.ui.animation.AnimationScheduler)
	private function new(scheduler:AnimationScheduler, animation:Animation) {
		this.scheduler = scheduler;
		this.animation = animation;
		active = true;
	}

	/** Removes this animation from its scheduler. Repeated cancellation is safe. */
	public function cancel():Void {
		if (active)
			scheduler.removeHandle(this);
	}

	@:allow(haxeon.ui.animation.AnimationScheduler)
	function advance(deltaSeconds:Float):Bool
		return animation.advance(deltaSeconds);

	/** Time before this animation next changes anything visible; 0 when it changes every frame. */
	@:allow(haxeon.ui.animation.AnimationScheduler)
	function delaySeconds():Float {
		if (!Std.isOfType(animation, DelayedAnimation))
			return 0.0;
		var delayed:DelayedAnimation = cast animation;
		return delayed.delaySeconds();
	}

	@:allow(haxeon.ui.animation.AnimationScheduler)
	function deactivate():Void
		active = false;

	@:allow(haxeon.ui.animation.AnimationScheduler)
	function matches(candidate:Animation):Bool
		return animation == candidate;
}
