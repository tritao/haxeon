package haxeon.ui.animation;

import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;

/** Time-based scalar tween controller retained in Haxe widget state. */
class AnimationController implements Animation {
	/** The tween's current value. */
	public var value(default, null):Float;

	/** Whether a tween is running. */
	public var active(default, null):Bool;

	/** Called with each new value. */
	public var onUpdate:Float->Void;

	/** Called when a tween reaches its end. */
	public var onComplete:Void->Void;
	var hasUpdate:Bool;
	var hasComplete:Bool;
	var scheduler:Null<AnimationScheduler>;
	final animationToken:Animation;
	var registration:Null<AnimationHandle>;
	var tween:Null<Tween>;
	var elapsed:Float;

	/** An idle controller at zero, advanced by `scheduler` once it has one. */
	public function new(?scheduler:AnimationScheduler, ?onUpdate:Float->Void,
			?onComplete:Void->Void) {
		this.scheduler = scheduler;
		animationToken = this;
		registration = null;
		this.onUpdate = onUpdate == null ? _ -> {} : onUpdate;
		this.onComplete = onComplete == null ? () -> {} : onComplete;
		hasUpdate = onUpdate != null;
		hasComplete = onComplete != null;
		value = 0.0;
		active = false;
		tween = null;
		elapsed = 0.0;
	}

	/** Moves the controller to `scheduler`, carrying a running tween over. */
	public function attach(scheduler:AnimationScheduler):Void {
		if (scheduler == null)
			throw "Animation controller requires a scheduler";
		if (registration != null)
			registration.cancel();
		registration = null;
		this.scheduler = scheduler;
		if (active)
			track();
	}

	/** Tweens from `from` to `to` over `duration` seconds. A zero duration jumps to `to` and completes at once. */
	public function play(from:Float, to:Float, duration:Float,
			easing:Easing = Easing.Linear):Void {
		var next = new Tween(from, to, duration, easing);
		value = from;
		elapsed = 0.0;
		tween = next;
		active = duration > 0.0;
		if (active) {
			track();
		} else {
			cancelRegistration();
			value = to;
			if (hasUpdate)
				onUpdate(value);
			if (hasComplete)
				onComplete();
		}
	}

	/** Stops the tween where it is, without completing it. */
	public function stop():Void {
		active = false;
		cancelRegistration();
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!active || tween == null)
			return false;
		elapsed += deltaSeconds;
		var completed = elapsed >= tween.duration;
		value = completed ? tween.to : tween.valueAt(elapsed);
		if (hasUpdate)
			onUpdate(value);
		if (completed) {
			active = false;
			cancelRegistration();
			if (hasComplete)
				onComplete();
			return false;
		}
		return true;
	}

	function track():Void {
		if (scheduler == null)
			return;
		if (registration == null || !registration.active)
			registration = scheduler.track(animationToken);
	}

	function cancelRegistration():Void {
		if (registration != null)
			registration.cancel();
		registration = null;
	}
}

/** Immutable scalar tween sampled by an AnimationController. */
class Tween {
	/** The value at the start. */
	public final from:Float;

	/** The value at the end. */
	public final to:Float;

	/** How long it takes, in seconds. */
	public final duration:Float;

	/** How it moves between the two. */
	public final easing:Easing;

	/**
	 * A tween from `from` to `to` over `duration` seconds. Throws when a value is not finite or the duration is
	 * negative.
	 */
	public function new(from:Float, to:Float, duration:Float, easing:Easing = Easing.Linear) {
		if (!finite(from) || !finite(to) || !finite(duration) || duration < 0.0)
			throw "Tween endpoints and duration must be finite, and the duration non-negative";
		this.from = from;
		this.to = to;
		this.duration = duration;
		this.easing = easing;
	}

	/** Its value `seconds` after the start, holding `to` once the duration has passed. */
	public function valueAt(seconds:Float):Float {
		if (!finite(seconds))
			throw "Tween sample time must be finite";
		var progress = duration == 0.0 ? 1.0 : seconds / duration;
		var eased = easing.apply(progress);
		return from + (to - from) * eased;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** An easing curve, evaluated by Haxe before each render transaction. */
enum Easing {
	/** Constant speed. */
	Linear;
	/** Starts slow and speeds up. */
	EaseIn;
	/** Starts fast and slows down. */
	EaseOut;
	/** Slow at both ends. */
	EaseInOut;

	/** The curve at `value`, clamped to 0..1. */
	public function apply(value:Float):Float {
		var t = value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value;
		return switch this {
			case EaseIn: t * t;
			case EaseOut: 1.0 - (1.0 - t) * (1.0 - t);
			case EaseInOut: t * t * (3.0 - 2.0 * t);
			case Linear: t;
		};
	}
}

/** Damped scalar spring simulated in Haxe with bounded semi-implicit steps. */
class SpringController implements Animation {
	/** The spring's current position. */
	public var value(default, null):Float;

	/** Its current velocity, per second. */
	public var velocity(default, null):Float;

	/** Where it is settling toward. */
	public var target(default, null):Float;

	/** Whether it is still moving. */
	public var active(default, null):Bool;

	/** How hard it pulls toward the target. */
	public final stiffness:Float;

	/** How strongly it resists motion. */
	public final damping:Float;

	/** How heavy it is. */
	public final mass:Float;

	/** How close to the target and to rest it must be to stop. */
	public final tolerance:Float;

	/** Called with each new position. */
	public var onUpdate:Float->Void;
	var hasUpdate:Bool;
	var scheduler:Null<AnimationScheduler>;
	final animationToken:Animation;
	var registration:Null<AnimationHandle>;

	/**
	 * A spring at rest at `initial`. Throws when a parameter is not finite, or the stiffness, mass or tolerance is not
	 * positive, or the damping is negative.
	 */
	public function new(initial:Float, stiffness:Float = 180.0, damping:Float = 24.0,
			mass:Float = 1.0, tolerance:Float = 0.001,
			?scheduler:AnimationScheduler, ?onUpdate:Float->Void) {
		if (!finite(initial) || !finite(stiffness) || !finite(damping) || !finite(mass) || !finite(tolerance)
			|| stiffness <= 0.0 || damping < 0.0 || mass <= 0.0 || tolerance <= 0.0)
			throw "Spring parameters must be finite and physically valid";
		value = initial;
		velocity = 0.0;
		target = initial;
		active = false;
		this.stiffness = stiffness;
		this.damping = damping;
		this.mass = mass;
		this.tolerance = tolerance;
		this.scheduler = scheduler;
		animationToken = this;
		registration = null;
		this.onUpdate = onUpdate == null ? _ -> {} : onUpdate;
		hasUpdate = onUpdate != null;
	}

	/** Sets where the spring settles, starting it with `initialVelocity`. */
	public function setTarget(value:Float, initialVelocity:Float = 0.0):Void {
		if (!finite(value) || !finite(initialVelocity))
			throw "Spring target and velocity must be finite";
		target = value;
		velocity = initialVelocity;
		active = true;
		track();
	}

	/** Moves the spring to `scheduler`, carrying its motion over. */
	public function attach(scheduler:AnimationScheduler):Void {
		if (scheduler == null)
			throw "Spring controller requires a scheduler";
		if (registration != null)
			registration.cancel();
		registration = null;
		this.scheduler = scheduler;
		if (active)
			track();
	}

	/** Stops the spring where it is. */
	public function stop():Void {
		active = false;
		velocity = 0.0;
		cancelRegistration();
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!active)
			return false;
		if (!finite(deltaSeconds) || deltaSeconds < 0.0)
			throw "Spring time must be finite and non-negative";
		var remaining = deltaSeconds;
		while (remaining > 0.0) {
			var step = remaining > 1.0 / 120.0 ? 1.0 / 120.0 : remaining;
			var acceleration = (stiffness * (target - value) - damping * velocity) / mass;
			velocity += acceleration * step;
			value += velocity * step;
			remaining -= step;
		}
		if (lessThanAbsolute(value - target, tolerance) && lessThanAbsolute(velocity, tolerance)) {
			value = target;
			velocity = 0.0;
			active = false;
			cancelRegistration();
		}
		if (hasUpdate)
			onUpdate(value);
		return active;
	}

	function track():Void {
		if (scheduler == null)
			return;
		if (registration == null || !registration.active)
			registration = scheduler.track(animationToken);
	}

	function cancelRegistration():Void {
		if (registration != null)
			registration.cancel();
		registration = null;
	}

	static inline function lessThanAbsolute(value:Float, threshold:Float):Bool
		return (value < 0.0 ? -value : value) < threshold;

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
