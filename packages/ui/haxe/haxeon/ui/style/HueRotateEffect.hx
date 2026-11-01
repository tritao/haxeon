package haxeon.ui.style;

/** Hue rotation in degrees. */
class HueRotateEffect extends VisualEffect {
	public final degrees:Float;

	public function new(degrees:Float) {
		super(EffectKind.HueRotate);
		this.degrees = VisualEffect.requireFinite(degrees,
			"Hue rotation must be finite");
	}

	public static function withDegrees(value:Float):HueRotateEffect
		return new HueRotateEffect(value);

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.HueRotate)
			return false;
		var value:HueRotateEffect = cast other;
		return value != null && degrees == value.degrees;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.HueRotate)
			return VisualEffect.discrete(this, other, amount);
		var value:HueRotateEffect = cast other;
		return new HueRotateEffect(VisualEffect.interpolateFloat(degrees, value.degrees, amount));
	}

	override public function copy():VisualEffect
		return new HueRotateEffect(degrees);

	override public function describe():String
		return 'hue-rotate($degrees)';
}
