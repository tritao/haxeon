package haxeon.ui.style;

import haxeon.ui.animation.Animation;
import haxeon.ui.animation.Easing;

/** Scheduler adapter for typed style interpolation. */
class StyleTransitionAnimation implements Animation {
	final from:StyleValue;
	final to:StyleValue;
	final duration:Float;
	final easing:Int;
	final onUpdate:StyleValue->Void;
	final onComplete:Void->Void;
	var elapsed:Float;

	public function new(from:StyleValue, to:StyleValue, duration:Float, easing:Int,
			onUpdate:StyleValue->Void, onComplete:Void->Void) {
		this.from = from;
		this.to = to;
		this.duration = duration;
		this.easing = easing;
		this.onUpdate = onUpdate;
		this.onComplete = onComplete;
		elapsed = 0.0;
	}

	public function advance(deltaSeconds:Float):Bool {
		elapsed += deltaSeconds;
		var complete = duration <= 0.0 || elapsed >= duration;
		var amount = complete ? 1.0 : Easing.apply(elapsed / duration, easing);
		onUpdate(complete ? to : from.interpolateTo(to, amount));
		if (complete) {
			onComplete();
			return false;
		}
		return true;
	}
}
