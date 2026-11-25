package haxeon.ui.style;

import haxeon.ui.Color;

/**
 * Rendering-independent description of one post-layout visual effect.
 *
 * Concrete effects own typed parameters and value behavior. They do not know
 * how those parameters become render passes, shaders, or intermediate targets.
 */
class VisualEffect {
	/** Which effect this is, which decides the parameters a concrete effect has. */
	public final kind:EffectKind;

	function new(kind:EffectKind) {
		this.kind = kind;
	}

	/** Whether `other` is the same effect with the same parameters. */
	public function isEqual(other:VisualEffect):Bool
		return other != null && kind == other.kind;

	/** Interpolates compatible effects and uses a discrete midpoint otherwise. */
	public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || kind != other.kind)
			return discrete(this, other, amount);
		return amount < 0.5 ? copy() : other.copy();
	}

	/** `left` before the midpoint of `amount` and `right` from it on (`left` when there is no `right`), each as a copy. */
	public static function discrete(left:VisualEffect, right:VisualEffect, amount:Float):VisualEffect
		return amount < 0.5 ? left.copy() : right == null ? left.copy() : right.copy();

	/** An independent effect with the same kind and parameters. */
	public function copy():VisualEffect
		return new VisualEffect(kind);

	/** How far the effect paints outside the bounds of the node it applies to. */
	public function inkOverflow():InkOverflow
		return InkOverflow.zero();

	/** The effect as a short readable text, such as `blur`, which the inspector and style dumps show. */
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

	/** The same text as `describe`. */
	public function toString():String
		return describe();

	/** `value` when it is finite; otherwise throws `message`. Concrete effects check their parameters with it. */
	public static function requireFinite(value:Float, message:String):Float {
		if (!Math.isFinite(value))
			throw message;
		return value;
	}

	/** `value` when it is finite and not negative; otherwise throws `message`. */
	public static function requireNonNegative(value:Float, message:String):Float {
		if (!Math.isFinite(value) || value < 0.0)
			throw message;
		return value;
	}

	/** The value `amount` of the way from `left` to `right`. */
	public static function interpolateFloat(left:Float, right:Float, amount:Float):Float
		return left + (right - left) * amount;

	/** A copy of `value`, for an effect's color parameter. */
	public static function copyColor(value:Color):Color
		return value;

	/** Whether two optional colors are equal, both absent included. */
	public static function equalColor(left:Null<Color>, right:Null<Color>):Bool
		return haxeon.Equality.equals(left, right);

	/** The color `amount` of the way from `left` to `right`, each channel interpolated linearly. */
	public static function interpolateColor(left:Color, right:Color, amount:Float):Color
		return Color.rgba(interpolateFloat(left.red, right.red, amount),
			interpolateFloat(left.green, right.green, amount),
			interpolateFloat(left.blue, right.blue, amount),
			interpolateFloat(left.alpha, right.alpha, amount));
}
