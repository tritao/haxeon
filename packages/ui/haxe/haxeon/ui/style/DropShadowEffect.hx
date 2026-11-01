package haxeon.ui.style;

import haxeon.ui.Color;

/** Subtree alpha shadow; distinct from the lightweight ShadowDecoration. */
class DropShadowEffect extends VisualEffect {
	public final offsetX:Float;
	public final offsetY:Float;
	public final sigma:Float;
	public final color:Color;

	public function new(offsetX:Float, offsetY:Float, sigma:Float, color:Color) {
		super(EffectKind.DropShadow);
		this.offsetX = VisualEffect.requireFinite(offsetX, "Drop-shadow X offset must be finite");
		this.offsetY = VisualEffect.requireFinite(offsetY, "Drop-shadow Y offset must be finite");
		this.sigma = VisualEffect.requireNonNegative(sigma,
			"Drop-shadow sigma must be finite and non-negative");
		this.color = VisualEffect.copyColor(color);
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.DropShadow)
			return false;
		var value:DropShadowEffect = cast other;
		return value != null && offsetX == value.offsetX && offsetY == value.offsetY &&
			sigma == value.sigma && VisualEffect.equalColor(color, value.color);
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.DropShadow)
			return VisualEffect.discrete(this, other, amount);
		var value:DropShadowEffect = cast other;
		return new DropShadowEffect(VisualEffect.interpolateFloat(offsetX, value.offsetX, amount),
			VisualEffect.interpolateFloat(offsetY, value.offsetY, amount),
			VisualEffect.interpolateFloat(sigma, value.sigma, amount),
			VisualEffect.interpolateColor(color, value.color, amount));
	}

	override public function copy():VisualEffect
		return new DropShadowEffect(offsetX, offsetY, sigma, color);

	override public function inkOverflow():InkOverflow {
		var spread = sigma * 3.0;
		return new InkOverflow(Math.max(0.0, spread - offsetX),
			Math.max(0.0, spread - offsetY), Math.max(0.0, spread + offsetX),
			Math.max(0.0, spread + offsetY));
	}

	override public function describe():String
		return 'drop-shadow($offsetX,$offsetY,$sigma,' + color.red + ',' + color.green + ',' +
			color.blue + ',' + color.alpha + ')';
}
