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

/** Typed effect families understood by the native compositor. */
enum EffectKind implements Equatable {
	/** `BlurEffect`. */
	Blur;
	/** `BrightnessEffect`. */
	Brightness;
	/** `ContrastEffect`. */
	Contrast;
	/** `SaturateEffect`. */
	Saturate;
	/** `HueRotateEffect`. */
	HueRotate;
	/** `ColorMatrixEffect`. */
	ColorMatrix;
	/** `DropShadowEffect`. */
	DropShadow;
	/** A renderer-owned shader/effect registration. */
	Custom;
}

/** Gaussian blur described by its standard deviation in logical pixels. */
class BlurEffect extends VisualEffect {
	/** The blur's standard deviation, in logical pixels. */
	public final sigma:Float;

	/** A blur of `sigma`. Throws when it is negative or not finite. */
	public function new(sigma:Float) {
		super(EffectKind.Blur);
		this.sigma = VisualEffect.requireNonNegative(sigma,
			"Blur sigma must be finite and non-negative");
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.Blur)
			return false;
		var value:BlurEffect = cast other;
		return value != null && kind == value.kind && sigma == value.sigma;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.Blur)
			return VisualEffect.discrete(this, other, amount);
		var value:BlurEffect = cast other;
		return new BlurEffect(VisualEffect.interpolateFloat(sigma, value.sigma, amount));
	}

	override public function copy():VisualEffect
		return new BlurEffect(sigma);

	override public function inkOverflow():InkOverflow
		return new InkOverflow(sigma * 3.0, sigma * 3.0, sigma * 3.0, sigma * 3.0);

	override public function describe():String
		return 'blur($sigma)';
}

/** Multiplicative color adjustment by one factor: brightness, contrast or saturation. */
class ColorFactorEffect extends VisualEffect {
	/** The multiplier: 1 leaves the content as it is, 0 makes it black, grey or flat. */
	public final factor:Float;

	function new(kind:EffectKind, factor:Float) {
		super(kind);
		this.factor = VisualEffect.requireNonNegative(factor, switch kind {
			case EffectKind.Brightness: "Brightness factor must be finite and non-negative";
			case EffectKind.Contrast: "Contrast factor must be finite and non-negative";
			case EffectKind.Saturate: "Saturation factor must be finite and non-negative";
			default: throw "A color factor effect is brightness, contrast or saturation";
		});
	}

	/** Scales brightness by `factor`. Throws when it is negative or not finite. */
	public static function brightness(factor:Float):ColorFactorEffect
		return new ColorFactorEffect(EffectKind.Brightness, factor);

	/** Scales contrast by `factor`. Throws when it is negative or not finite. */
	public static function contrast(factor:Float):ColorFactorEffect
		return new ColorFactorEffect(EffectKind.Contrast, factor);

	/** Scales saturation by `factor`: 0 is grey. Throws when it is negative or not finite. */
	public static function saturate(factor:Float):ColorFactorEffect
		return new ColorFactorEffect(EffectKind.Saturate, factor);

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != kind)
			return false;
		var value:ColorFactorEffect = cast other;
		return value != null && factor == value.factor;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != kind)
			return VisualEffect.discrete(this, other, amount);
		var value:ColorFactorEffect = cast other;
		return new ColorFactorEffect(kind, VisualEffect.interpolateFloat(factor, value.factor, amount));
	}

	override public function copy():VisualEffect
		return new ColorFactorEffect(kind, factor);

	override public function describe():String
		return switch kind {
			case EffectKind.Brightness: 'brightness($factor)';
			case EffectKind.Contrast: 'contrast($factor)';
			default: 'saturate($factor)';
		};
}

/** Hue rotation in degrees. */
class HueRotateEffect extends VisualEffect {
	/** How far hues are turned around the color wheel. */
	public final degrees:Float;

	/** Turns hues by `degrees`. Throws when it is not finite. */
	public function new(degrees:Float) {
		super(EffectKind.HueRotate);
		this.degrees = VisualEffect.requireFinite(degrees,
			"Hue rotation must be finite");
	}

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

/** Four-channel color matrix in row-major 4x5 form. */
class ColorMatrixEffect extends VisualEffect {
	/** How many numbers a matrix has: four rows of five, the fifth an offset. */
	public static inline var ComponentCount:Int = 20;
	/** The 4×5 matrix, row by row, mapping RGBA to RGBA. */
	public final matrix:Array<Float>;

	/** Transforms colors by `matrix`. Throws unless it has `ComponentCount` finite numbers. */
	public function new(matrix:Array<Float>) {
		super(EffectKind.ColorMatrix);
		if (matrix == null || matrix.length != ComponentCount)
			throw "Color matrices require 20 components";
		this.matrix = [];
		for (value in matrix)
			this.matrix.push(VisualEffect.requireFinite(value,
				"Color matrix components must be finite"));
	}

	/** The matrix that leaves colors as they are. */
	public static function identity():ColorMatrixEffect {
		var matrix:Array<Float> = [];
		for (row in 0...4)
			for (column in 0...5)
				matrix.push(row == column ? 1.0 : 0.0);
		return new ColorMatrixEffect(matrix);
	}

	override public function isEqual(other:VisualEffect):Bool {
		if (other == null || other.kind != EffectKind.ColorMatrix)
			return false;
		var value:ColorMatrixEffect = cast other;
		if (value == null || matrix.length != value.matrix.length)
			return false;
		for (index in 0...matrix.length)
			if (matrix[index] != value.matrix[index])
				return false;
		return true;
	}

	override public function interpolate(other:VisualEffect, amount:Float):VisualEffect {
		if (other == null || other.kind != EffectKind.ColorMatrix)
			return VisualEffect.discrete(this, other, amount);
		var value:ColorMatrixEffect = cast other;
		var result:Array<Float> = [];
		for (index in 0...matrix.length)
			result.push(VisualEffect.interpolateFloat(matrix[index], value.matrix[index], amount));
		return new ColorMatrixEffect(result);
	}

	override public function copy():VisualEffect
		return new ColorMatrixEffect(matrix);

	override public function describe():String {
		var values:Array<String> = [];
		for (value in matrix)
			values.push(Std.string(value));
		return 'color-matrix(' + values.join(",") + ')';
	}
}

/** Subtree alpha shadow; distinct from the lightweight ShadowDecoration. */
class DropShadowEffect extends VisualEffect {
	/** How far the shadow is moved right. */
	public final offsetX:Float;
	/** How far it is moved down. */
	public final offsetY:Float;
	/** Its blur's standard deviation. */
	public final sigma:Float;
	/** Its color. */
	public final color:Color;

	/** A shadow of the content's own shape, unlike the box-shaped `ShadowDecoration`. */
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
		return value != null && offsetX == value.offsetX && offsetY == value.offsetY && sigma == value.sigma
			&& VisualEffect.equalColor(color, value.color);
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
		return 'drop-shadow($offsetX,$offsetY,$sigma,' + color.red + ',' + color.green + ',' + color.blue + ','
			+ color.alpha + ')';
}
