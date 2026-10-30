package haxeon.ui.animation;

import haxeon.ui.animation.Animation;

/** Advances active Haxe animations whenever the host drives a UI frame. */
class AnimationScheduler {
	final active:Array<AnimationHandle>;
	public var onFrameRequested:Null<Void->Void>;
	public var revision(default, null):Int;

	public function new() {
		active = [];
		onFrameRequested = null;
		revision = 0;
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
		if (!handle.retained) revision++;
		requestFrame();
		return handle;
	}

	/** Compatibility removal for callers that still retain the animation object. */
	public function remove(animation:Animation):Void {
		if (animation == null)
			return;
		var pending:Array<AnimationHandle> = [];
		for (handle in active)
			if (handle.matches(animation))
				pending.push(handle);
		for (handle in pending)
			removeHandle(handle);
	}

	@:allow(haxeon.ui.animation.AnimationHandle)
	function removeHandle(handle:AnimationHandle):Void {
		if (handle == null)
			return;
		if (active.remove(handle)) {
			handle.deactivate();
			if (!handle.retained) revision++;
		}
	}

	public function advance(deltaSeconds:Float):Void {
		if (!finite(deltaSeconds) || deltaSeconds < 0.0)
			throw "Animation time must be finite and non-negative";
		var hadActive = rebuildingCount > 0;
		var current = active.copy();
		for (handle in current)
			if (active.indexOf(handle) >= 0 && !handle.advance(deltaSeconds))
				removeHandle(handle);
		if (needsFrame)
			requestFrame();
		if (hadActive)
			revision++;
	}

	public function cancelAll():Void {
		if (active.length == 0)
			return;
		var rebuilding = rebuildingCount > 0;
		for (handle in active)
			handle.deactivate();
		active.resize(0);
		if (rebuilding) revision++;
	}

	public var activeCount(get, never):Int;
	inline function get_activeCount():Int
		return active.length;

	/** Active animations whose frames rebuild the view; RetainedAnimation ones do not. */
	public var rebuildingCount(get, never):Int;
	function get_rebuildingCount():Int {
		var count = 0;
		for (handle in active)
			if (!handle.retained) count++;
		return count;
	}

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
