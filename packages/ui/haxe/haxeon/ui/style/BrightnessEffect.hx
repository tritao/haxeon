package haxeon.ui.style;

/** Multiplicative RGB brightness adjustment. */
class BrightnessEffect extends VisualEffect {
	public final factor:Float;

	public function new(factor:Float) {
		super(EffectKind.Brightness);
		this.factor = VisualEffect.requireNonNegative(factor,
			"Brightness factor must be finite and non-negative");
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.Brightness)
			return false;
		var value:BrightnessEffect = cast other;
		return value != null && factor == value.factor;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.Brightness)
			return VisualEffect.discrete(this, other, amount);
		var value:BrightnessEffect = cast other;
		return new BrightnessEffect(VisualEffect.interpolateFloat(factor, value.factor, amount));
	}

	override public function copy():VisualEffect
		return new BrightnessEffect(factor);

	override public function describe():String
		return 'brightness($factor)';
}
