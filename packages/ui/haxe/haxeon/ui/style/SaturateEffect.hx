package haxeon.ui.style;

/** Multiplicative color saturation adjustment. */
class SaturateEffect extends VisualEffect {
	public final factor:Float;

	public function new(factor:Float) {
		super(EffectKind.Saturate);
		this.factor = VisualEffect.requireNonNegative(factor,
			"Saturation factor must be finite and non-negative");
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.Saturate)
			return false;
		var value:SaturateEffect = cast other;
		return value != null && factor == value.factor;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.Saturate)
			return VisualEffect.discrete(this, other, amount);
		var value:SaturateEffect = cast other;
		return new SaturateEffect(VisualEffect.interpolateFloat(factor, value.factor, amount));
	}

	override public function copy():VisualEffect
		return new SaturateEffect(factor);

	override public function describe():String
		return 'saturate($factor)';
}
