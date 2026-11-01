package haxeon.ui.style;

import haxeon.ui.animation.Easing;
import haxeon.ui.style.StyleProperty.StylePropertyBase;

/** One property transition requested by a stylesheet. */
class StyleTransition {
	public final property:StylePropertyBase;
	public final duration:Float;
	public final easing:Int;

	public function new(property:StylePropertyBase, duration:Float, easing:Int = Easing.EaseOut) {
		if (property == null || duration < 0.0 || easing < Easing.Linear || easing > Easing.EaseInOut)
			throw "Style transitions require a property, duration, and valid easing";
		this.property = property;
		this.duration = duration;
		this.easing = easing;
	}
}
