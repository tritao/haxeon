package haxeon.ui.style;

import haxeon.ui.Color;

/**
 * Rendering-independent description of one post-layout visual effect.
 *
 * Concrete effects own typed parameters and value behavior. They do not know
 * how those parameters become render passes, shaders, or intermediate targets.
 */
class VisualEffect {
	public final kind:EffectKind;

	function new(kind:EffectKind) {
		this.kind = kind;
	}

	public function isEqual(other:VisualEffect):Bool
		return other != null && kind == other.kind;

	/** Interpolates compatible effects and uses a discrete midpoint otherwise. */
	public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || kind != other.kind)
			return discrete(this, other, amount);
		return amount < 0.5 ? copy() : other.copy();
	}

	public static function discrete(left:VisualEffect, right:VisualEffect, amount:Float):VisualEffect
		return amount < 0.5 ? left.copy() : right == null ? left.copy() : right.copy();

	public function copy():VisualEffect
		return new VisualEffect(kind);

	public function inkOverflow():InkOverflow
		return InkOverflow.zero();

	public function describe():String
		return switch kind {
			case EffectKind.Blur: "blur";
			case EffectKind.Brightness: "brightness";
			case EffectKind.Contrast: "contrast";
			case EffectKind.Saturate: "saturate";
			case EffectKind.HueRotate: "hue-rotate";
			case EffectKind.ColorMatrix: "color-matrix";
			case EffectKind.DropShadow: "drop-shadow";
			case EffectKind.Custom: "custom";
		};

	public function toString():String
		return describe();

	public static function requireFinite(value:Float, message:String):Float {
		if (!Math.isFinite(value))
			throw message;
		return value;
	}

	public static function requireNonNegative(value:Float, message:String):Float {
		if (!Math.isFinite(value) || value < 0.0)
			throw message;
		return value;
	}

	public static function interpolateFloat(left:Float, right:Float, amount:Float):Float
		return left + (right - left) * amount;

	public static function copyColor(value:Color):Color
		return value;

	public static function equalColor(left:Null<Color>, right:Null<Color>):Bool
		return haxeon.Equality.equals(left, right);

	public static function interpolateColor(left:Color, right:Color, amount:Float):Color
		return Color.rgba(interpolateFloat(left.red, right.red, amount),
			interpolateFloat(left.green, right.green, amount),
			interpolateFloat(left.blue, right.blue, amount),
			interpolateFloat(left.alpha, right.alpha, amount));
}
