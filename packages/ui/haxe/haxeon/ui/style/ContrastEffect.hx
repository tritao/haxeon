package haxeon.ui.style;

/** Multiplicative RGB contrast adjustment. */
class ContrastEffect extends VisualEffect {
	public final factor:Float;

	public function new(factor:Float) {
		super(EffectKind.Contrast);
		this.factor = VisualEffect.requireNonNegative(factor,
			"Contrast factor must be finite and non-negative");
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.Contrast)
			return false;
		var value:ContrastEffect = cast other;
		return value != null && factor == value.factor;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.Contrast)
			return VisualEffect.discrete(this, other, amount);
		var value:ContrastEffect = cast other;
		return new ContrastEffect(VisualEffect.interpolateFloat(factor, value.factor, amount));
	}

	override public function copy():VisualEffect
		return new ContrastEffect(factor);

	override public function describe():String
		return 'contrast($factor)';
}
