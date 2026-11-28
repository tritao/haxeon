package haxeon.ui.animation;

import haxeon.ui.animation.Animation;

/**
 * Advances active Haxe animations whenever the host drives a UI frame, and asks for frames while one changes. An
 * animation changes the view only through what it writes: a signal or state that views read rebuilds them, a scroll
 * offset settles in layout, and custom paint that reads it paints again; the scheduler itself rebuilds nothing.
 */
class AnimationScheduler {
	final active:Array<AnimationHandle>;
	internal var onFrameRequested:Null<Void->Void>;

	internal function new() {
		active = [];
		onFrameRequested = null;
	}

	/** Registers an animation and returns a stable handle for its lifetime. */
	public function track(animation:Animation):AnimationHandle {
		if (animation == null)
			throw "Cannot track a null animation";
		for (handle in active)
			if (handle.matches(animation))
				return handle;
		var handle = new AnimationHandle(this, animation);
		active.push(handle);
		requestFrame();
		return handle;
	}

	/** Stops advancing `animation`, as cancelling the handle `track` returned for it does. */
	public function remove(animation:Animation):Void {
		if (animation == null || active.length == 0)
			return;
		var pending:Null<Array<AnimationHandle>> = null;
		for (handle in active)
			if (handle.matches(animation)) {
				if (pending == null) pending = [];
				pending.push(handle);
			}
		if (pending != null)
			for (handle in pending)
				removeHandle(handle);
	}

	@:allow(haxeon.ui.animation.AnimationHandle)
	function removeHandle(handle:AnimationHandle):Void {
		if (handle == null)
			return;
		if (active.remove(handle)) handle.deactivate();
	}

	internal function advance(deltaSeconds:Float):Void {
		if (!finite(deltaSeconds) || deltaSeconds < 0.0)
			throw "Animation time must be finite and non-negative";
		if (active.length == 0) return;
		var current = active.copy();
		for (handle in current) {
			if (active.indexOf(handle) < 0) continue;
			if (!handle.advance(deltaSeconds)) removeHandle(handle);
		}
		if (needsFrame)
			requestFrame();
	}

	internal function cancelAll():Void {
		if (active.length == 0)
			return;
		for (handle in active)
			handle.deactivate();
		active.resize(0);
	}

	/** How many animations it is advancing. */
	public var activeCount(get, never):Int;
	inline function get_activeCount():Int
		return active.length;

	/** Whether some animation changes on every frame, as opposed to only waiting for a deadline. */
	public var needsFrame(get, never):Bool;
	function get_needsFrame():Bool {
		for (handle in active)
			if (handle.delaySeconds() <= 0.0)
				return true;
		return false;
	}

	/**
	 * Seconds until the earliest deadline when every active animation is waiting, or -1 when
	 * nothing is active or some animation needs frames now.
	 */
	public function waitSeconds():Float {
		var earliest = -1.0;
		for (handle in active) {
			var delay = handle.delaySeconds();
			if (delay <= 0.0)
				return -1.0;
			if (earliest < 0.0 || delay < earliest)
				earliest = delay;
		}
		return earliest;
	}

	function requestFrame():Void {
		if (onFrameRequested != null)
			onFrameRequested();
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Stable registration returned by AnimationScheduler.track. */
class AnimationHandle {
	final scheduler:AnimationScheduler;
	final animation:Animation;

	/** Whether the animation is still being advanced. */
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
